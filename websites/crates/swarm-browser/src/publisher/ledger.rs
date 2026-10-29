//! One atomic local snapshot: active requests and retained, file-backed history.
use super::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
pub(super) const ACTIVE_COUNT: usize = 100;
pub(super) const ACTIVE_BYTES: usize = 256 * 1024;
pub(super) const TOTAL_COUNT: usize = 2000;
pub(super) const TOTAL_BYTES: usize = 4 * 1024 * 1024;
pub(super) const FILE_BYTES: usize = 1024 * 1024;
pub(super) const PAGE: usize = 10;
const UPDATE_RESERVE: usize = 2048;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Ledger {
    pub version: u8,
    pub revision: u64,
    pub records: Vec<Value>,
    pub archived: BTreeMap<String, String>,
}
impl Default for Ledger {
    fn default() -> Self {
        Self {
            version: 2,
            revision: 0,
            records: vec![],
            archived: BTreeMap::new(),
        }
    }
}
pub(super) fn resolved(r: &Value) -> bool {
    ["confirmed", "failed", "cancelled", "rejected"].contains(&r["state"].as_str().unwrap_or(""))
}
pub(super) fn fingerprint(r: &Value) -> String {
    swarm_core::keccak256_hex(serde_json::to_string(r).unwrap().as_bytes())
}
impl Ledger {
    pub fn parse(raw: &str, p: &ModeratorProfile, who: &str) -> Result<Self> {
        if raw.trim_start().starts_with('[') {
            return Ok(Self {
                records: history::validate(raw, p, who)?,
                ..Self::default()
            });
        }
        if raw.len() > TOTAL_BYTES {
            return Err("HISTORY_STORAGE_CAPACITY");
        }
        let store: Self = serde_json::from_str(raw).map_err(|_| "INVALID_HISTORY")?;
        store.validate(p, who)?;
        Ok(store)
    }
    pub fn validate(&self, p: &ModeratorProfile, who: &str) -> Result<()> {
        if self.version != 2
            || self.records.len() > TOTAL_COUNT
            || self.archived.len() > TOTAL_COUNT
        {
            return Err("INVALID_HISTORY");
        }
        history::validate_retained(
            &serde_json::to_string(&self.records).map_err(|_| "INVALID_HISTORY")?,
            p,
            who,
            TOTAL_COUNT,
            TOTAL_BYTES,
        )?;
        if history::merge(&[], &self.records)?.len() != self.records.len() {
            return Err("HISTORY_CONFLICT");
        }
        for (id, hash) in &self.archived {
            let r = self
                .records
                .iter()
                .find(|r| recovery::identity(r) == *id)
                .ok_or("INVALID_HISTORY_ARCHIVE")?;
            if !resolved(r) || fingerprint(r) != *hash {
                return Err("INVALID_HISTORY_ARCHIVE");
            }
        }
        Ok(())
    }
    pub fn encode(&self, p: &ModeratorProfile, who: &str) -> Result<String> {
        self.validate(p, who)?;
        let raw = serde_json::to_string(self).map_err(|_| "INVALID_HISTORY")?;
        if raw.len() > TOTAL_BYTES {
            return Err("HISTORY_STORAGE_CAPACITY");
        }
        Ok(raw)
    }
    pub fn is_archived(&self, r: &Value) -> bool {
        self.archived.contains_key(&recovery::identity(r))
    }
    pub fn active(&self) -> Vec<Value> {
        self.records
            .iter()
            .filter(|r| !self.is_archived(r))
            .cloned()
            .collect()
    }
    pub fn eligible(&self) -> Vec<Value> {
        self.records
            .iter()
            .filter(|r| resolved(r) && !self.is_archived(r))
            .cloned()
            .collect()
    }
    // A fresh receipt that changes an archived record requires a new verified backup.
    pub fn reconcile(&mut self) {
        self.archived.retain(|id, hash| {
            self.records
                .iter()
                .any(|r| recovery::identity(r) == *id && resolved(r) && fingerprint(r) == *hash)
        });
    }
    pub fn room(&self, extra: &Value) -> Result<()> {
        let active = self.active();
        let unsettled = active.iter().filter(|r| !resolved(r)).count();
        let growth = (unsettled + 1) * UPDATE_RESERVE;
        let extra = serde_json::to_vec(extra)
            .map_err(|_| "INVALID_HISTORY")?
            .len()
            + 1;
        let active_bytes = serde_json::to_vec(&active)
            .map_err(|_| "INVALID_HISTORY")?
            .len();
        if active.len() >= ACTIVE_COUNT || active_bytes + extra + growth > ACTIVE_BYTES {
            return Err("HISTORY_ACTIVE_CAPACITY");
        }
        let total = serde_json::to_vec(self)
            .map_err(|_| "INVALID_HISTORY")?
            .len();
        if self.records.len() >= TOTAL_COUNT || total + extra + growth > TOTAL_BYTES {
            return Err("HISTORY_STORAGE_CAPACITY");
        }
        Ok(())
    }
    pub fn archive(&mut self, expected: &[Value]) -> Result<()> {
        if expected.is_empty() {
            return Err("NOTHING_TO_ARCHIVE");
        }
        // Validate the whole snapshot before changing any archive marker.
        for old in expected {
            let id = recovery::identity(old);
            let current = self
                .records
                .iter()
                .find(|r| recovery::identity(r) == id)
                .ok_or("ARCHIVE_SNAPSHOT_CHANGED")?;
            if current != old || !resolved(current) || self.is_archived(current) {
                return Err("ARCHIVE_SNAPSHOT_CHANGED");
            }
        }
        for r in expected {
            self.archived.insert(recovery::identity(r), fingerprint(r));
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn record(i: usize, state: &str) -> Value {
        let p = history::fixture_profile();
        json!({"chainId":100,"contract":p.deployment.moderation.address,"publisher":format!("0x{}","55".repeat(20)),"action":"approve","to":p.deployment.token.address,"data":encode_approve(&p.deployment.moderation.address,fee("1200").unwrap()).unwrap(),"intent":null,"caseId":"","state":state,"hash":format!("0x{:064x}",i+1),"requestId":format!("r{i}")})
    }
    #[test]
    fn full_resolved_journal_archives_without_losing_guards_or_records() {
        let mut s = Ledger {
            records: (0..100).map(|i| record(i, "confirmed")).collect(),
            ..Ledger::default()
        };
        assert_eq!(
            s.room(&record(101, "requesting")).unwrap_err(),
            "HISTORY_ACTIVE_CAPACITY"
        );
        s.archive(&s.eligible()).unwrap();
        assert_eq!(s.records.len(), 100);
        assert!(s.active().is_empty());
        s.room(&record(101, "requesting")).unwrap();
        let p = history::fixture_profile();
        let raw = s
            .encode(&p, s.records[0]["publisher"].as_str().unwrap())
            .unwrap();
        let restored =
            Ledger::parse(&raw, &p, s.records[0]["publisher"].as_str().unwrap()).unwrap();
        assert_eq!(restored.archived.len(), 100);
    }
    #[test]
    fn uncertain_requests_and_changed_snapshots_cannot_be_archived() {
        let mut s = Ledger {
            records: vec![record(0, "confirmed"), record(1, "unknown")],
            ..Ledger::default()
        };
        let chosen = s.eligible();
        s.records[0]["state"] = json!("unchecked");
        assert!(s.archive(&chosen).is_err());
        assert!(s.archived.is_empty());
        assert!(s.archive(&[record(1, "unknown")]).is_err());
        s.records[0]["state"] = json!("confirmed");
        s.archive(&chosen).unwrap();
        assert_eq!(s.active(), vec![record(1, "unknown")]);
        assert!(history::guard(&s.records, "approve", &Value::Null, "").is_err());
    }
    #[test]
    fn stale_cache_is_not_an_instruction_to_reactivate_archived_history() {
        let mut s = Ledger {
            records: vec![record(0, "confirmed")],
            ..Ledger::default()
        };
        let stale = s.records.clone();
        s.archive(&s.eligible()).unwrap();
        s.records = history::merge(&s.records, &stale).unwrap();
        s.reconcile();
        assert!(s.active().is_empty());
        s.records[0]["state"] = json!("failed");
        s.reconcile();
        assert_eq!(s.active().len(), 1);
    }
    #[test]
    fn capacity_reserves_space_for_returned_hashes_and_receipts() {
        let mut s = Ledger {
            records: vec![record(0, "confirmed")],
            ..Ledger::default()
        };
        let base = serde_json::to_vec(&s.active()).unwrap().len();
        let extra = serde_json::to_vec(&record(1, "requesting")).unwrap().len() + 1;
        s.records[0]["caseId"] = json!("x".repeat(ACTIVE_BYTES - base - extra - 1000));
        assert!(s.room(&record(1, "requesting")).is_err());
    }
    #[test]
    fn legacy_history_migrates_without_changing_identity_or_status() {
        let p = history::fixture_profile();
        let r = record(0, "confirmed");
        let raw = json!([r.clone()]).to_string();
        let s = Ledger::parse(&raw, &p, r["publisher"].as_str().unwrap()).unwrap();
        assert_eq!(s.records, vec![r]);
        assert!(s.archived.is_empty());
    }
}
