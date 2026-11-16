use super::*;
use std::{cell::Cell, collections::BTreeMap};

#[derive(Default)]
pub(super) struct Journal {
    entries: RefCell<BTreeMap<String, Entry>>,
    write_lock: Cell<bool>,
    pending: RefCell<Option<PendingIntent>>,
}

#[derive(Default)]
struct Entry {
    base: Vec<Value>,
    cached: Option<Vec<Value>>,
    fault: bool,
}

#[derive(Clone)]
pub(super) struct PendingIntent {
    pub record: Value,
    pub context_changed: bool,
    pub display: Option<swarm_core::Display>,
}

pub(super) struct WalletRequest {
    journal: Rc<Journal>,
    profile: ModeratorProfile,
    account: String,
    records: Vec<Value>,
}

impl WalletRequest {
    pub fn record(&self) -> &Value {
        self.records.last().unwrap()
    }

    fn save(&self) -> bool {
        let saved = self
            .journal
            .save(&self.profile, &self.account, &self.records)
            .is_ok();
        // Retain the wallet result even when its durable save fails.
        if let Some(pending) = self.journal.pending.borrow_mut().as_mut() {
            pending.record = self.record().clone();
        }
        saved
    }

    pub fn failed(&mut self, error: &str) {
        self.records.last_mut().unwrap()["state"] = json!(if error == "WALLET_REJECTED" {
            "rejected"
        } else {
            "unknown"
        });
        self.save();
    }

    pub fn broadcast(&mut self, hash: &str) -> bool {
        let record = self.records.last_mut().unwrap();
        record["state"] = json!("unchecked");
        record["hash"] = json!(hash);
        self.save()
    }

    pub fn observed_nonce(&mut self, nonce: String) -> bool {
        self.records.last_mut().unwrap()["nonce"] = json!(nonce);
        self.save()
    }
}

pub(super) fn resolved(record: &Value) -> bool {
    ["confirmed", "failed", "cancelled", "rejected"]
        .contains(&record["state"].as_str().unwrap_or(""))
}

pub(super) fn uncertain_without_hash(record: &Value) -> bool {
    record["hash"].is_null()
        && ["requesting", "unknown"].contains(&record["state"].as_str().unwrap_or(""))
}

pub(super) fn recovery_hash(record: &Value) -> Option<&str> {
    record["resolution"]["hash"]
        .as_str()
        .or(record["candidateHash"].as_str())
        .or(record["hash"].as_str())
}

impl Journal {
    fn entry(&self, key: &str) -> std::cell::RefMut<'_, Entry> {
        std::cell::RefMut::map(self.entries.borrow_mut(), |entries| {
            entries.entry(key.into()).or_default()
        })
    }

    pub fn has_faults(&self) -> bool {
        self.entries.borrow().values().any(|entry| entry.fault)
    }

    pub fn has_fault(&self, p: &ModeratorProfile, who: &str) -> bool {
        self.entries
            .borrow()
            .get(&key(p, who))
            .is_some_and(|entry| entry.fault)
    }

    pub fn pending(&self) -> Option<PendingIntent> {
        self.pending.borrow().clone()
    }

    pub fn context_changed(&self) {
        if let Some(pending) = self.pending.borrow_mut().as_mut() {
            if pending.record["state"] == "requesting" {
                pending.context_changed = true;
            }
        }
    }

    pub fn begin_wallet(&self, record: &Value, display: Option<swarm_core::Display>) {
        *self.pending.borrow_mut() = Some(PendingIntent {
            record: record.clone(),
            context_changed: false,
            display,
        });
    }

    pub fn update_pending(&self, record: &Value) {
        if let Some(pending) = self.pending.borrow_mut().as_mut() {
            if recovery::identity(&pending.record) == recovery::identity(record) {
                pending.record = record.clone();
            }
        }
    }

    pub fn reserve(
        self: &Rc<Self>,
        p: &ModeratorProfile,
        who: &str,
        mut records: Vec<Value>,
        reservation: Value,
    ) -> Result<WalletRequest> {
        self.ensure_room(p, who, &reservation)?;
        records.push(reservation);
        if let Err(error) = self.save(p, who, &records) {
            let reserved = records.pop().ok_or("INVALID_HISTORY")?;
            self.cancel_unsent(p, who, &reserved);
            return Err(error);
        }
        Ok(WalletRequest {
            journal: self.clone(),
            profile: p.clone(),
            account: who.into(),
            records,
        })
    }
}

pub(super) fn key(p: &ModeratorProfile, who: &str) -> String {
    format!(
        "swarm-publisher-last-{}-{}-{}-history",
        p.deployment.chain_id,
        p.deployment.moderation.address.to_ascii_lowercase(),
        who.to_ascii_lowercase()
    )
}
fn storage() -> Result<web_sys::Storage> {
    web_sys::window()
        .unwrap()
        .local_storage()
        .map_err(|_| "HISTORY_UNAVAILABLE")?
        .ok_or("HISTORY_UNAVAILABLE")
}
pub(super) fn validate(raw: &str, p: &ModeratorProfile, who: &str) -> Result<Vec<Value>> {
    validate_retained(raw, p, who, ledger::ACTIVE_COUNT, ledger::ACTIVE_BYTES)
}
pub(super) fn validate_retained(
    raw: &str,
    p: &ModeratorProfile,
    who: &str,
    max_count: usize,
    max_bytes: usize,
) -> Result<Vec<Value>> {
    if raw.len() > max_bytes {
        return Err("HISTORY_SIZE_LIMIT");
    }
    let records: Vec<Value> = serde_json::from_str(raw).map_err(|_| "INVALID_HISTORY")?;
    if records.len() > max_count {
        return Err("HISTORY_SIZE_LIMIT");
    }
    for r in &records {
        let object = r.as_object().ok_or("INVALID_HISTORY")?;
        if object.keys().any(|k| {
            ![
                "chainId",
                "contract",
                "publisher",
                "action",
                "to",
                "data",
                "intent",
                "caseId",
                "state",
                "hash",
                "requestId",
                "nonce",
                "anchor",
                "resolution",
                "candidateHash",
                "caseEvidence",
                "caseHint",
            ]
            .contains(&k.as_str())
        }) {
            return Err("INVALID_HISTORY");
        }
        if r["chainId"] != p.deployment.chain_id
            || r["contract"] != p.deployment.moderation.address
            || r["publisher"] != who
            || !["approve", "submit", "refund"].contains(&r["action"].as_str().unwrap_or(""))
            || ![
                "requesting",
                "unknown",
                "unchecked",
                "confirmed",
                "failed",
                "rejected",
                "cancelled",
            ]
            .contains(&r["state"].as_str().unwrap_or(""))
        {
            return Err("INVALID_HISTORY_CONTEXT");
        }
        if r["hash"].is_null()
            && (r.get("requestId").is_none()
                || ["confirmed", "failed", "unchecked"]
                    .contains(&r["state"].as_str().unwrap_or("")))
        {
            return Err("INVALID_HISTORY");
        }
        if !r["hash"].is_null() {
            let h = Uint256::hex(r["hash"].as_str().ok_or("INVALID_HISTORY")?)
                .map_err(|_| "INVALID_HISTORY")?;
            if h == Uint256::ZERO {
                return Err("INVALID_HISTORY");
            }
        }
        if r["action"] == "submit" {
            let intent = r["intent"].as_object().ok_or("INVALID_HISTORY")?;
            if intent
                .keys()
                .any(|k| !["contentHash", "metaHash", "topics", "fee"].contains(&k.as_str()))
            {
                return Err("INVALID_HISTORY");
            }
            for field in ["contentHash", "metaHash"] {
                if Uint256::hex(r["intent"][field].as_str().ok_or("INVALID_HISTORY")?)
                    .map_err(|_| "INVALID_HISTORY")?
                    == Uint256::ZERO
                {
                    return Err("INVALID_HISTORY");
                }
            }
            let topics = r["intent"]["topics"].as_array().ok_or("INVALID_HISTORY")?;
            if !(1..=5).contains(&topics.len()) {
                return Err("INVALID_HISTORY");
            }
            for topic in topics {
                Uint256::hex(topic.as_str().ok_or("INVALID_HISTORY")?)
                    .map_err(|_| "INVALID_HISTORY")?;
            }
            fee(r["intent"]["fee"].as_str().ok_or("INVALID_HISTORY")?)
                .map_err(|_| "INVALID_HISTORY")?;
        } else if !r["intent"].is_null() {
            return Err("INVALID_HISTORY");
        }
        let data = r["data"].as_str().ok_or("INVALID_HISTORY")?;
        if data.len() < 10
            || data.len() > 4096
            || data.len() % 2 != 0
            || !data.starts_with("0x")
            || !data[2..].bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("INVALID_HISTORY");
        }
        if let Some(id) = r.get("requestId") {
            let id = id.as_str().ok_or("INVALID_HISTORY")?;
            if id.is_empty()
                || id.len() > 128
                || !id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-.:".contains(&b))
            {
                return Err("INVALID_HISTORY");
            }
        }
        let expected = match r["action"].as_str().ok_or("INVALID_HISTORY")? {
            "approve" => {
                if data.len() != 138 {
                    return Err("INVALID_HISTORY");
                }
                let amount = Uint256::hex(&format!("0x{}", &data[74..138]))
                    .map_err(|_| "INVALID_HISTORY")?;
                encode_approve(&p.deployment.moderation.address, amount)
                    .map_err(|_| "INVALID_HISTORY")?
            }
            "submit" => {
                let intent = &r["intent"];
                let topics = intent["topics"]
                    .as_array()
                    .ok_or("INVALID_HISTORY")?
                    .iter()
                    .map(|v| v.as_str().map(str::to_owned).ok_or("INVALID_HISTORY"))
                    .collect::<Result<Vec<_>>>()?;
                swarm_core::publisher::encode_submission_parts(
                    intent["contentHash"].as_str().ok_or("INVALID_HISTORY")?,
                    intent["metaHash"].as_str().ok_or("INVALID_HISTORY")?,
                    &topics,
                    fee(intent["fee"].as_str().ok_or("INVALID_HISTORY")?)
                        .map_err(|_| "INVALID_HISTORY")?,
                )
                .map_err(|_| "INVALID_HISTORY")?
            }
            "refund" => {
                let id = positive(r["caseId"].as_str().ok_or("INVALID_HISTORY")?)?;
                format!(
                    "{}{}",
                    swarm_core::selector("withdrawRefund(uint256)"),
                    id.abi()
                )
            }
            _ => return Err("INVALID_HISTORY"),
        };
        if !data.eq_ignore_ascii_case(&expected) {
            return Err("HISTORY_ACTION_MISMATCH");
        }
        let target = if r["action"] == "approve" {
            &p.deployment.token.address
        } else {
            &p.deployment.moderation.address
        };
        if !same_hex_bytes(&r["to"], &json!(target), Some(20)) {
            return Err("INVALID_HISTORY");
        }
        recovery::validate_fields(r)?;
        publications::validate(r)?;
    }
    Ok(records)
}
/// Merge record identity without deleting uncertain broadcasts or promoting imported status.
/// The later slice contains explicit local receipt updates and therefore wins for the same request.
pub(super) fn merge(base: &[Value], updates: &[Value]) -> Result<Vec<Value>> {
    let result = merge_retaining(base, updates)?;
    if result.len() > ledger::TOTAL_COUNT
        || serde_json::to_vec(&result)
            .map_err(|_| "INVALID_HISTORY")?
            .len()
            > ledger::TOTAL_BYTES
    {
        return Err("HISTORY_STORAGE_CAPACITY");
    }
    Ok(result)
}
// Capacity failure must never erase a hash already returned by the wallet.
fn merge_retaining(base: &[Value], updates: &[Value]) -> Result<Vec<Value>> {
    let mut result = Vec::<Value>::new();
    for update in base.iter().chain(updates.iter()) {
        let index = result.iter().position(|old| {
            (!update["requestId"].is_null() && old["requestId"] == update["requestId"])
                || (!update["hash"].is_null() && old["hash"] == update["hash"])
        });
        if let Some(index) = index {
            let old = &result[index];
            if !old["requestId"].is_null()
                && !update["requestId"].is_null()
                && old["requestId"] != update["requestId"]
            {
                return Err("HISTORY_CONFLICT");
            }
            if [
                "chainId",
                "contract",
                "publisher",
                "action",
                "to",
                "data",
                "intent",
                "caseId",
            ]
            .iter()
            .any(|k| old[k] != update[k])
                || (!old["hash"].is_null()
                    && !update["hash"].is_null()
                    && old["hash"] != update["hash"])
            {
                return Err("HISTORY_CONFLICT");
            }
            let mut next = update.clone();
            for field in ["nonce", "anchor"] {
                if !old[field].is_null() && !next[field].is_null() && old[field] != next[field] {
                    return Err("HISTORY_CONFLICT");
                }
                if next[field].is_null() && !old[field].is_null() {
                    next[field] = old[field].clone();
                }
            }
            if next["resolution"].is_null() && !old["resolution"].is_null() {
                next["resolution"] = old["resolution"].clone();
                next["state"] = old["state"].clone();
            }
            if next["caseEvidence"].is_null()
                && !old["caseEvidence"].is_null()
                && !["failed", "cancelled", "rejected"]
                    .contains(&next["state"].as_str().unwrap_or(""))
            {
                next["caseEvidence"] = old["caseEvidence"].clone();
            }
            if next["hash"].is_null() && !old["hash"].is_null() {
                next["hash"] = old["hash"].clone();
                next["state"] = old["state"].clone();
            }
            result[index] = next;
        } else {
            result.push(update.clone());
        }
    }
    Ok(result)
}
fn disk(p: &ModeratorProfile, who: &str) -> Result<ledger::Ledger> {
    let raw = storage()?
        .get_item(&key(p, who))
        .map_err(|_| "HISTORY_UNAVAILABLE")?
        .unwrap_or_else(|| "[]".into());
    ledger::Ledger::parse(&raw, p, who)
}
impl Journal {
    pub fn load_store(&self, p: &ModeratorProfile, who: &str) -> Result<ledger::Ledger> {
        let mut store = disk(p, who)?;
        // Clean tab caches are snapshots, never instructions to overwrite newer disk state.
        let k = key(p, who);
        let entries = self.entries.borrow();
        if let Some(entry) = entries.get(&k).filter(|entry| entry.fault) {
            if let Some(cached) = &entry.cached {
                store.records = merge_cache(&store.records, &entry.base, cached)?;
                store.reconcile();
            }
        }
        Ok(store)
    }
    pub fn load_current(&self, p: &ModeratorProfile, who: &str) -> Result<Vec<Value>> {
        self.current_from(p, who, &self.load_store(p, who))
    }
    fn current_from(
        &self,
        p: &ModeratorProfile,
        who: &str,
        result: &Result<ledger::Ledger>,
    ) -> Result<Vec<Value>> {
        let mut entry = self.entry(&key(p, who));
        match result {
            Ok(store) => {
                if !entry.fault {
                    entry.base = store.records.clone();
                }
                Ok(store.records.clone())
            }
            Err(error) => {
                entry.fault = true;
                entry.cached.clone().ok_or(*error)
            }
        }
    }
}
// Three-way merge: unchanged cached rows cannot overwrite a newer tab's work.
fn merge_cache(disk: &[Value], base: &[Value], cached: &[Value]) -> Result<Vec<Value>> {
    let mut updates = Vec::new();
    for r in cached {
        let id = recovery::identity(r);
        let original = base.iter().find(|old| recovery::identity(old) == id);
        if original == Some(r) && disk.iter().any(|old| recovery::identity(old) == id) {
            continue;
        }
        if let Some(current) = disk.iter().find(|old| recovery::identity(old) == id) {
            if original != Some(current) && current != r {
                if resolved(current)
                    && !resolved(r)
                    && same_hex_bytes(&current["hash"], &r["hash"], Some(32))
                {
                    continue;
                }
                if resolved(current) && resolved(r) && current["state"] != r["state"] {
                    return Err("HISTORY_CONCURRENT_CHANGE");
                }
                if !current["resolution"].is_null()
                    && !r["resolution"].is_null()
                    && current["resolution"] != r["resolution"]
                {
                    return Err("HISTORY_CONCURRENT_CHANGE");
                }
                if !current["caseEvidence"].is_null()
                    && !r["caseEvidence"].is_null()
                    && current["caseEvidence"] != r["caseEvidence"]
                {
                    return Err("HISTORY_CONCURRENT_CHANGE");
                }
            }
        }
        updates.push(r.clone());
    }
    merge_retaining(disk, &updates)
}
impl Journal {
    fn stage(&self, k: &str, records: Vec<Value>) {
        let mut entry = self.entry(k);
        entry.cached = Some(records);
        entry.fault = true;
    }
    fn persist_with(
        &self,
        p: &ModeratorProfile,
        who: &str,
        mut store: ledger::Ledger,
        write: impl FnOnce(&str) -> Result<()>,
    ) -> Result<()> {
        let k = key(p, who);
        self.stage(&k, store.records.clone());
        store.reconcile();
        store.revision = store
            .revision
            .checked_add(1)
            .ok_or("HISTORY_REVISION_LIMIT")?;
        let raw = store.encode(p, who)?;
        write(&raw)?;
        let mut entry = self.entry(&k);
        entry.base = store.records;
        entry.fault = false;
        Ok(())
    }
    pub fn persist(&self, p: &ModeratorProfile, who: &str, store: ledger::Ledger) -> Result<()> {
        if !self.write_lock.get() {
            return Err("HISTORY_COORDINATION_UNAVAILABLE");
        }
        let k = key(p, who);
        self.persist_with(p, who, store, |raw| {
            storage()?
                .set_item(&k, raw)
                .map_err(|_| "HISTORY_SAVE_FAILED")
        })
    }
    pub fn save(&self, p: &ModeratorProfile, who: &str, records: &[Value]) -> Result<()> {
        let k = key(p, who);
        let cached = self
            .entries
            .borrow()
            .get(&k)
            .filter(|entry| entry.fault)
            .and_then(|entry| entry.cached.clone())
            .unwrap_or_default();
        let incoming = merge_retaining(&cached, records)?;
        // Stage before bounds, parsing, quota or disk failures. Export sees all known hashes.
        self.stage(&k, incoming.clone());
        let mut store = disk(p, who)?;
        let base = self.entry(&k).base.clone();
        store.records = merge_cache(&store.records, &base, &incoming)?;
        self.persist(p, who, store)
    }
}
fn rebase_checked(base: &mut Vec<Value>, disk: &[Value], id: &str) {
    base.retain(|r| recovery::identity(r) != id);
    if let Some(r) = disk.iter().find(|r| recovery::identity(r) == id) {
        base.push(r.clone());
    }
}
// Only the canonical receipt checker calls this after its final context checks.
// Rebase that one checked identity; unrelated dirty rows still undergo conflict checks.
impl Journal {
    pub fn save_checked(
        &self,
        p: &ModeratorProfile,
        who: &str,
        records: &[Value],
        checked: &Value,
    ) -> Result<()> {
        if !self.write_lock.get() {
            return Err("HISTORY_COORDINATION_UNAVAILABLE");
        }
        let k = key(p, who);
        let cached = self.entry(&k).cached.clone().unwrap_or_default();
        self.stage(&k, merge_retaining(&cached, records)?);
        let current = disk(p, who)?;
        rebase_checked(
            &mut self.entry(&k).base,
            &current.records,
            &recovery::identity(checked),
        );
        self.save(p, who, records)
    }
    pub fn ensure_room(&self, p: &ModeratorProfile, who: &str, reservation: &Value) -> Result<()> {
        self.load_store(p, who)?.room(reservation)
    }
    pub fn import_room(&self, p: &ModeratorProfile, who: &str, records: &[Value]) -> Result<()> {
        let mut store = self.load_store(p, who)?;
        let previous = store.active();
        let before_count = previous.len();
        let before_bytes = serde_json::to_vec(&previous)
            .map_err(|_| "INVALID_HISTORY")?
            .len();
        store.records = records.to_vec();
        store.reconcile();
        let active = store.active();
        let after_bytes = serde_json::to_vec(&active)
            .map_err(|_| "INVALID_HISTORY")?
            .len();
        if (active.len() > ledger::ACTIVE_COUNT && active.len() > before_count)
            || (after_bytes > ledger::ACTIVE_BYTES && after_bytes > before_bytes)
        {
            return Err("HISTORY_IMPORT_CAPACITY");
        }
        Ok(())
    }
    /// Called only when persistence failed before opening a wallet prompt.
    pub fn cancel_unsent(&self, p: &ModeratorProfile, who: &str, reservation: &Value) {
        if let Some(records) = self.entry(&key(p, who)).cached.as_mut() {
            records.retain(|r| r["requestId"] != reservation["requestId"] || !r["hash"].is_null());
        }
    }
}
fn guard_state(records: &[Value], action: &str, intent: &Value, caseid: &str) -> Result<bool> {
    let mut repeated = false;
    for r in records {
        let matching = match action {
            "approve" => r["action"] == "approve",
            "submit" => {
                r["action"] == "approve"
                    || (r["action"] == "submit"
                        && r["intent"]["contentHash"] == intent["contentHash"]
                        && r["intent"]["metaHash"] == intent["metaHash"]
                        && r["intent"]["topics"] == intent["topics"])
            }
            "refund" => r["action"] == "refund" && r["caseId"] == caseid,
            _ => false,
        };
        if matching && !resolved(r) {
            return Err("CHECK_PRIOR_TRANSACTION_BEFORE_RESENDING");
        }
        repeated |=
            matching && r["state"] == "confirmed" && r["action"] == "submit" && action == "submit";
    }
    Ok(repeated)
}
fn related_submissions(records: &[Value], action: &str) -> Vec<Value> {
    if action != "submit" {
        return vec![];
    }
    records
        .iter()
        .filter(|r| r["action"] == "submit")
        .cloned()
        .collect()
}
pub(super) fn guard_family(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    records: &[Value],
    action: &str,
    intent: &Value,
    caseid: &str,
) -> Result<()> {
    if action != "submit" {
        return guard(records, action, intent, caseid);
    }
    let mut all = records.to_vec();
    if let Some(family) = &p.deployment.persistent {
        for version in &family.versions {
            if version
                .moderation
                .address
                .eq_ignore_ascii_case(&p.deployment.moderation.address)
            {
                continue;
            }
            let origin =
                swarm_core::versioning::select(p, &version.moderation.address).map_err(|e| e.0)?;
            let related = related_submissions(&journal(a).load_current(&origin, who)?, action);
            guard_state(&related, action, intent, caseid)
                .map_err(|_| "OTHER_VERSION_REQUEST_UNRESOLVED")?;
            all.extend(related);
        }
    }
    guard(&all, action, intent, caseid)
}
pub(super) fn guard(records: &[Value], action: &str, intent: &Value, caseid: &str) -> Result<()> {
    if guard_state(records,action,intent,caseid)? && !web_sys::window().unwrap().confirm_with_message("This exact publication already has a confirmed submission. Submit it again deliberately?").map_err(|_|"CONFIRMATION_FAILED")? {return Err("RESUBMISSION_CANCELLED");}
    Ok(())
}
pub(super) fn record(
    p: &ModeratorProfile,
    who: &str,
    action: &str,
    to: &str,
    data: &str,
    intent: Value,
    caseid: String,
) -> Value {
    json!({"chainId":p.deployment.chain_id,"contract":p.deployment.moderation.address,"publisher":who,"action":action,"to":to,"data":data,"intent":intent,"caseId":caseid,"state":"requesting","hash":null,"requestId":format!("{}-{}",js_sys::Date::now(),js_sys::Math::random())})
}

/// Ethereum hex is an encoding of bytes: letter case is not part of identity.
/// Require well-formed, equally sized fields before accepting a case variant.
pub(super) fn same_hex_bytes(left: &Value, right: &Value, size: Option<usize>) -> bool {
    let (Some(left), Some(right)) = (left.as_str(), right.as_str()) else {
        return false;
    };
    let (Some(a), Some(b)) = (left.strip_prefix("0x"), right.strip_prefix("0x")) else {
        return false;
    };
    if a.len() != b.len() || a.len() % 2 != 0 || left.len() > 4096 {
        return false;
    }
    if match size {
        Some(bytes) => a.len() != bytes * 2,
        None => a.len() < 8,
    } {
        return false;
    }
    a.bytes().all(|v| v.is_ascii_hexdigit())
        && b.bytes().all(|v| v.is_ascii_hexdigit())
        && a.eq_ignore_ascii_case(b)
}
/// Resolve only one journal request. An already known hash never clears a different unknown request.
pub(super) fn receipt_record_index(
    records: &[Value],
    hash: &str,
    to: &Value,
    data: &Value,
) -> Result<Option<usize>> {
    let hash_value = json!(hash);
    let known = records
        .iter()
        .enumerate()
        .filter(|(_, r)| same_hex_bytes(&r["hash"], &hash_value, Some(32)))
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    let candidates = if known.is_empty() {
        records
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                uncertain_without_hash(r)
                    && same_hex_bytes(&r["to"], to, Some(20))
                    && same_hex_bytes(&r["data"], data, None)
            })
            .map(|(i, _)| i)
            .collect::<Vec<_>>()
    } else {
        known
    };
    if candidates.len() > 1 {
        return Err("HISTORY_AMBIGUOUS_TRANSACTION");
    }
    if let Some(&i) = candidates.first() {
        if !same_hex_bytes(&records[i]["to"], to, Some(20))
            || !same_hex_bytes(&records[i]["data"], data, None)
        {
            return Err("HISTORY_TRANSACTION_MISMATCH");
        }
        Ok(Some(i))
    } else {
        Ok(None)
    }
}

// Serialize all journal writers across tabs. A busy lock refuses instead of queuing a send.
pub(super) async fn coordinated(a: &Rc<RefCell<App>>, action: Action) -> ActionResult {
    if !action.writes_history() {
        return run(a, action).await;
    }
    let epoch = a.borrow().epoch;
    let state = a.clone();
    crate::coordination::run_if_available(
        "swarm-publisher-history-v2",
        crate::coordination::Errors {
            unavailable: "HISTORY_COORDINATION_UNAVAILABLE",
            busy: "HISTORY_BUSY_IN_ANOTHER_TAB",
            failed: "HISTORY_COORDINATION_FAILED",
        },
        move || {
            let state = state.clone();
            async move {
                active(&state, epoch)?;
                journal(&state).write_lock.set(true);
                let result = run(&state, action).await;
                journal(&state).write_lock.set(false);
                result
            }
        },
    )
    .await?
}

#[cfg(test)]
mod tests {
    use super::*;
    fn intent(fee: &str) -> Value {
        json!({"contentHash":"content","metaHash":"meta","topics":["biology"],"fee":fee})
    }
    #[test]
    fn archived_duplicates_need_one_confirmation_but_later_unknown_still_blocks() {
        let done = json!({"action":"submit","state":"confirmed","intent":intent("1200")});
        assert!(guard_state(&[done.clone(), done.clone()], "submit", &intent("1400"), "").unwrap());
        let later = json!({"action":"submit","state":"unknown","intent":intent("1300")});
        assert_eq!(
            guard_state(&[done, later], "submit", &intent("1400"), "").unwrap_err(),
            "CHECK_PRIOR_TRANSACTION_BEFORE_RESENDING"
        );
    }
    #[test]
    fn pending_submission_cannot_be_bypassed_by_fee_change() {
        let records = vec![json!({"action":"submit","state":"unchecked","intent":intent("1200")})];
        assert_eq!(
            guard(&records, "submit", &intent("1300"), "").unwrap_err(),
            "CHECK_PRIOR_TRANSACTION_BEFORE_RESENDING"
        );
    }
    #[test]
    fn pending_approval_blocks_submit_and_approval() {
        let records = vec![json!({"action":"approve","state":"unknown"})];
        assert!(guard(&records, "submit", &intent("1200"), "").is_err());
        assert!(guard(&records, "approve", &Value::Null, "").is_err());
    }
    #[test]
    fn refund_guard_binds_case() {
        let records = vec![json!({"action":"refund","state":"requesting","caseId":"3"})];
        assert!(guard(&records, "refund", &Value::Null, "3").is_err());
        assert!(guard(&records, "refund", &Value::Null, "4").is_ok());
    }
}

#[cfg(test)]
pub(super) fn fixture_profile() -> ModeratorProfile {
    serde_json::from_value(json!({"deployment":{"chainId":100,"moderation":{"address":format!("0x{}","11".repeat(20)),"codeHash":format!("0x{}","a1".repeat(32))},"stakes":{"address":format!("0x{}","22".repeat(20)),"codeHash":format!("0x{}","a2".repeat(32))},"index":{"address":format!("0x{}","33".repeat(20)),"codeHash":format!("0x{}","a3".repeat(32))},"token":{"address":format!("0x{}","44".repeat(20)),"codeHash":format!("0x{}","a4".repeat(32))},"guidelines":{"version":1,"hash":format!("0x{}","b1".repeat(32))}},"rpcUrl":"https://example.org/rpc","gatewayUrl":"https://example.org/","timing":{"clockErrorSeconds":5,"maxEvidenceAgeSeconds":30,"maxHeadLagSeconds":30,"inclusionBudgetSeconds":120},"display":null})).unwrap()
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    fn record(id: &str, hash: Value, state: &str) -> Value {
        let p = fixture_profile();
        json!({"chainId":100,"contract":p.deployment.moderation.address,"publisher":format!("0x{}","55".repeat(20)),"action":"approve","to":p.deployment.token.address,"data":encode_approve(&p.deployment.moderation.address,fee("1200").unwrap()).unwrap(),"intent":null,"caseId":"","state":state,"hash":hash,"requestId":id})
    }
    #[test]
    fn volatile_hash_survives_stale_disk_and_import_merge() {
        let pending = record("r1", Value::Null, "requesting");
        let sent = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        let merged = merge(&[pending.clone()], &[sent.clone()]).unwrap();
        assert_eq!(merged, vec![sent.clone()]);
        assert_eq!(merge(&merged, &[pending]).unwrap(), vec![sent]);
    }
    #[test]
    fn receipt_update_retains_other_uncertain_records() {
        let sent = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        let other = record("r2", json!(format!("0x{}", "77".repeat(32))), "unknown");
        let mut confirmed = sent.clone();
        confirmed["state"] = json!("confirmed");
        let merged = merge(&[sent, other.clone()], &[confirmed.clone()]).unwrap();
        assert_eq!(merged, vec![confirmed, other]);
    }
    #[test]
    fn context_switch_and_unsent_rollback_do_not_drop_prior_hash() {
        let p = fixture_profile();
        let who = format!("0x{}", "55".repeat(20));
        let other = format!("0x{}", "88".repeat(20));
        let a = Rc::new(RefCell::new(App::default()));
        let sent = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        let reservation = record("r2", Value::Null, "requesting");
        journal(&a).entry(&key(&p, &who)).cached = Some(vec![sent.clone()]);
        journal(&a).entry(&key(&p, &other)).cached = Some(vec![reservation.clone()]);
        journal(&a).cancel_unsent(&p, &other, &reservation);
        assert_eq!(
            journal(&a).entry(&key(&p, &who)).cached.as_ref().unwrap(),
            &vec![sent]
        );
        assert!(journal(&a)
            .entry(&key(&p, &other))
            .cached
            .as_ref()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn imported_action_cannot_disguise_submit_calldata_as_approval() {
        let p = fixture_profile();
        let who = format!("0x{}", "55".repeat(20));
        let mut value = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        value["data"] = json!(format!(
            "{}{}",
            swarm_core::selector("withdrawRefund(uint256)"),
            Uint256::from_u64(3).abi()
        ));
        assert!(validate(&json!([value]).to_string(), &p, &who).is_err());
    }
    #[test]
    fn conflicting_hashes_for_one_request_fail_closed() {
        let a = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        let b = record("r1", json!(format!("0x{}", "77".repeat(32))), "unchecked");
        assert_eq!(merge(&[a], &[b]).unwrap_err(), "HISTORY_CONFLICT");
    }
    #[test]
    fn dirty_snapshot_preserves_other_tabs_newer_confirmation_and_archive() {
        let old = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        let other = record("r2", Value::Null, "requesting");
        let mut returned = other.clone();
        returned["hash"] = json!(format!("0x{}", "77".repeat(32)));
        returned["state"] = json!("unchecked");
        let mut checked = old.clone();
        checked["state"] = json!("confirmed");
        let mut disk = ledger::Ledger {
            records: vec![checked.clone(), other.clone()],
            ..ledger::Ledger::default()
        };
        disk.archive(&[checked]).unwrap();
        disk.records = merge_cache(
            &disk.records,
            &[old.clone(), other],
            &[old, returned.clone()],
        )
        .unwrap();
        disk.reconcile();
        assert_eq!(disk.records[0]["state"], "confirmed");
        assert_eq!(disk.archived.len(), 1);
        assert_eq!(disk.active(), vec![returned]);
    }
    #[test]
    fn newer_confirmation_of_a_dirty_broadcast_wins_but_conflicting_receipts_refuse() {
        let mut base = record("r1", Value::Null, "requesting");
        let mut cache = base.clone();
        cache["hash"] = json!(format!("0x{}", "66".repeat(32)));
        cache["state"] = json!("unchecked");
        let mut disk = cache.clone();
        disk["state"] = json!("confirmed");
        assert_eq!(
            merge_cache(&[disk.clone()], &[base.clone()], &[cache.clone()]).unwrap()[0]["state"],
            "confirmed"
        );
        base["hash"] = cache["hash"].clone();
        base["state"] = json!("unchecked");
        cache["state"] = json!("failed");
        assert_eq!(
            merge_cache(&[disk], &[base], &[cache]).unwrap_err(),
            "HISTORY_CONCURRENT_CHANGE"
        );
    }
    #[test]
    fn concurrent_resolution_proofs_require_a_fresh_check_of_only_that_identity() {
        let base = record("r1", json!(format!("0x{}", "66".repeat(32))), "unchecked");
        let mut left = base.clone();
        left["state"] = json!("confirmed");
        left["resolution"] = json!({"hash":"one"});
        let mut right = left.clone();
        right["resolution"] = json!({"hash":"two"});
        assert_eq!(
            merge_cache(&[left.clone()], &[base.clone()], &[right.clone()]).unwrap_err(),
            "HISTORY_CONCURRENT_CHANGE"
        );
        let unrelated = record("r2", Value::Null, "unknown");
        let mut baseline = vec![base, unrelated.clone()];
        rebase_checked(&mut baseline, &[left.clone()], &recovery::identity(&right));
        let resolved =
            merge_cache(&[left], &baseline, &[right.clone(), unrelated.clone()]).unwrap();
        assert_eq!(resolved[0], right);
        assert!(baseline.contains(&unrelated));
        assert!(resolved.contains(&unrelated));
    }
    #[test]
    fn failed_disk_write_keeps_returned_hash_in_exportable_cache_and_blocks_sends() {
        let p = fixture_profile();
        let a = Rc::new(RefCell::new(App::default()));
        let sent = record(
            "returned",
            json!(format!("0x{}", "66".repeat(32))),
            "unchecked",
        );
        let who = sent["publisher"].as_str().unwrap();
        let store = ledger::Ledger {
            records: vec![sent.clone()],
            ..ledger::Ledger::default()
        };
        assert_eq!(
            journal(&a)
                .persist_with(&p, who, store, |_| Err("HISTORY_SAVE_FAILED"))
                .unwrap_err(),
            "HISTORY_SAVE_FAILED"
        );
        assert!(journal(&a).has_fault(&p, who));
        assert_eq!(
            journal(&a).entry(&key(&p, who)).cached.as_ref().unwrap()[0]["hash"],
            sent["hash"]
        );
    }
    #[test]
    fn broadcast_growth_must_remain_exportable_past_active_byte_limit() {
        let mut before = record("large-legacy", Value::Null, "requesting");
        let base = serde_json::to_vec(&vec![before.clone()]).unwrap().len();
        // This field was accepted in old public history. Exercise the exact byte edge.
        before["caseId"] = json!("x".repeat(256 * 1024 - 20 - base));
        let raw = serde_json::to_string(&vec![before.clone()]).unwrap();
        validate(
            &raw,
            &fixture_profile(),
            before["publisher"].as_str().unwrap(),
        )
        .unwrap();
        let mut broadcast = before.clone();
        broadcast["hash"] = json!(format!("0x{}", "66".repeat(32)));
        broadcast["state"] = json!("unchecked");
        let retained =
            merge(&[before], &[broadcast.clone()]).expect("a returned hash must remain exportable");
        assert_eq!(retained[0]["hash"], broadcast["hash"]);
    }
}

#[cfg(test)]
mod receipt_resolution_tests {
    use super::*;
    fn hash() -> String {
        format!("0x{}", "66".repeat(32))
    }
    fn target() -> Value {
        json!("0x5FbDB2315678afecb367f032d93F642f64180aa3")
    }
    fn payload() -> Value {
        json!(encode_approve(
            "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
            fee("1200").unwrap()
        )
        .unwrap())
    }
    fn entry(hash: Value, state: &str) -> Value {
        json!({"hash":hash,"to":target(),"data":payload(),"state":state})
    }
    #[test]
    fn known_hash_does_not_clear_a_distinct_unknown_request() {
        let records = vec![
            entry(json!(hash()), "unchecked"),
            entry(Value::Null, "unknown"),
        ];
        assert_eq!(
            receipt_record_index(&records, &hash(), &target(), &payload()).unwrap(),
            Some(0)
        );
    }
    #[test]
    fn ambiguous_unknown_requests_fail_closed() {
        let records = vec![
            entry(Value::Null, "unknown"),
            entry(Value::Null, "requesting"),
        ];
        assert_eq!(
            receipt_record_index(&records, &hash(), &target(), &payload()).unwrap_err(),
            "HISTORY_AMBIGUOUS_TRANSACTION"
        );
    }
    #[test]
    fn checksummed_saved_approval_matches_lowercase_rpc_recipient() {
        let records = vec![entry(json!(hash()), "unchecked")];
        let rpc_target = json!(target().as_str().unwrap().to_ascii_lowercase());
        assert_eq!(
            receipt_record_index(&records, &hash(), &rpc_target, &payload()).unwrap(),
            Some(0)
        );
    }
    #[test]
    fn unknown_request_can_match_identical_bytes_with_different_hex_case() {
        let records = vec![entry(Value::Null, "unknown")];
        let rpc_target = json!(target().as_str().unwrap().to_ascii_lowercase());
        let input = payload();
        let rpc_input = json!(format!(
            "0x{}",
            input.as_str().unwrap()[2..].to_ascii_uppercase()
        ));
        assert_eq!(
            receipt_record_index(&records, &hash(), &rpc_target, &rpc_input).unwrap(),
            Some(0)
        );
    }
    #[test]
    fn malformed_or_short_fields_do_not_match_even_if_the_text_case_matches() {
        assert!(!same_hex_bytes(
            &json!("0xgggggggg"),
            &json!("0xGGGGGGGG"),
            None
        ));
        assert!(!same_hex_bytes(
            &json!("0x1234"),
            &json!("0x1234"),
            Some(20)
        ));
        assert!(!same_hex_bytes(&Value::Null, &Value::Null, Some(32)));
        let records = vec![entry(json!(hash()), "unchecked")];
        assert_eq!(
            receipt_record_index(&records, &hash(), &target(), &Value::Null).unwrap_err(),
            "HISTORY_TRANSACTION_MISMATCH"
        );
    }
    #[test]
    fn different_recipient_or_approval_amount_still_fails() {
        let records = vec![entry(json!(hash()), "unchecked")];
        let other = json!("0x5fbdb2315678afecb367f032d93f642f64180aa4");
        assert_eq!(
            receipt_record_index(&records, &hash(), &other, &payload()).unwrap_err(),
            "HISTORY_TRANSACTION_MISMATCH"
        );
        let data = json!(encode_approve(
            "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
            fee("1201").unwrap()
        )
        .unwrap());
        assert_eq!(
            receipt_record_index(&records, &hash(), &target(), &data).unwrap_err(),
            "HISTORY_TRANSACTION_MISMATCH"
        );
    }
    #[test]
    fn case_variants_do_not_make_two_unknown_requests_unambiguous() {
        let mut a = entry(Value::Null, "unknown");
        a["to"] = json!(target().as_str().unwrap().to_ascii_lowercase());
        let records = vec![a, entry(Value::Null, "unknown")];
        assert_eq!(
            receipt_record_index(&records, &hash(), &target(), &payload()).unwrap_err(),
            "HISTORY_AMBIGUOUS_TRANSACTION"
        );
    }
}

#[cfg(test)]
mod version_guard_tests {
    use super::*;
    #[test]
    fn refunds_and_distinct_spender_approvals_never_read_other_version_storage() {
        let mut p = fixture_profile();
        let mut other = p.deployment.moderation.clone();
        other.address = format!("0x{}", "77".repeat(20));
        p.deployment.persistent = Some(swarm_core::versioning::PersistentDeployment {
            authority: swarm_core::ContractPin {
                address: format!("0x{}", "90".repeat(20)),
                code_hash: p.deployment.index.code_hash.clone(),
            },
            versions: vec![p.deployment.moderation.clone(), other]
                .into_iter()
                .map(|moderation| swarm_core::versioning::VersionPin {
                    moderation,
                    guidelines: p.deployment.guidelines.clone(),
                    rules_hash: format!("0x{}", "99".repeat(32)),
                    guidelines_url: p.guidelines_url.clone(),
                })
                .collect(),
        });
        let p = swarm_core::parse_profile(&serde_json::to_string(&p).unwrap()).unwrap();
        let a = Rc::new(RefCell::new(App::default()));
        // Native tests have no browser storage: touching the other journal would panic.
        guard_family(
            &a,
            &p,
            &format!("0x{}", "50".repeat(20)),
            &[],
            "refund",
            &Value::Null,
            "12",
        )
        .unwrap();
        guard_family(
            &a,
            &p,
            &format!("0x{}", "50".repeat(20)),
            &[],
            "approve",
            &Value::Null,
            "",
        )
        .unwrap();
    }
    #[test]
    fn old_unknown_submission_blocks_matching_republication_but_not_equal_id_refunds() {
        let intent = json!({"contentHash":"c","metaHash":"m","topics":["t"]});
        let old = vec![
            json!({"action":"submit","intent":intent,"state":"unknown","contract":"old","caseId":"12"}),
            json!({"action":"approve","state":"unknown"}),
        ];
        let related = related_submissions(&old, "submit");
        assert_eq!(related.len(), 1);
        assert!(guard_state(&related, "submit", &intent, "").is_err());
        assert!(related_submissions(&old, "refund").is_empty());
        assert!(related_submissions(&old, "approve").is_empty());
        let other = json!({"contentHash":"different","metaHash":"m","topics":["t"]});
        assert!(!guard_state(&related, "submit", &other, "").unwrap());
    }
}

#[cfg(test)]
mod journal_owner_tests {
    use super::*;

    const WHO: &str = "0x5555555555555555555555555555555555555555";
    // Existing compact Value encoding, with an independently calculated Keccak hash.
    const LEGACY_RECORD: &str = r#"{"action":"approve","caseId":"","chainId":100,"contract":"0x1111111111111111111111111111111111111111","data":"0x095ea7b3000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000004b0","hash":"0x6666666666666666666666666666666666666666666666666666666666666666","intent":null,"publisher":"0x5555555555555555555555555555555555555555","state":"confirmed","to":"0x4444444444444444444444444444444444444444"}"#;
    const RECORD_HASH: &str = "0xa0ad9775a8f19e8a3f05bbea09bed37b6e9432e4ab377fbb8b6e94cb336eae45";

    fn saved(id: &str, state: &str) -> Value {
        let mut row: Value = serde_json::from_str(LEGACY_RECORD).unwrap();
        row["requestId"] = json!(id);
        row["state"] = json!(state);
        if ["requesting", "unknown"].contains(&state) {
            row["hash"] = Value::Null;
        }
        row
    }

    #[test]
    fn clean_read_records_base_without_inventing_a_cache_fallback() {
        let journal = Journal::default();
        let p = fixture_profile();
        let rows = vec![saved("read", "confirmed")];
        let disk = Ok(ledger::Ledger {
            records: rows.clone(),
            ..Default::default()
        });
        assert_eq!(journal.current_from(&p, WHO, &disk).unwrap(), rows);
        assert!(!journal.has_fault(&p, WHO));
        assert_eq!(journal.entry(&key(&p, WHO)).base, rows);
        assert!(journal.entry(&key(&p, WHO)).cached.is_none());
        assert_eq!(
            journal
                .current_from(&p, WHO, &Err("HISTORY_UNAVAILABLE"))
                .unwrap_err(),
            "HISTORY_UNAVAILABLE"
        );
        assert!(journal.has_fault(&p, WHO));
        assert_eq!(journal.entry(&key(&p, WHO)).base, rows);
    }

    #[test]
    fn absent_empty_and_populated_cache_have_distinct_failure_results() {
        let p = fixture_profile();
        for cached in [
            None,
            Some(vec![]),
            Some(vec![saved("returned", "unchecked")]),
        ] {
            let journal = Journal::default();
            journal.entry(&key(&p, WHO)).cached = cached.clone();
            let store = Err("HISTORY_CONCURRENT_CHANGE");
            let records = journal.current_from(&p, WHO, &store);
            assert_eq!(records, cached.ok_or("HISTORY_CONCURRENT_CHANGE"));
            assert!(journal.has_fault(&p, WHO));
            // Visible fallback rows do not provide a ledger for archive or capacity.
            assert!(store.is_err());
        }
    }

    #[test]
    fn successful_dirty_read_keeps_reconciliation_base_and_send_fault() {
        let journal = Journal::default();
        let p = fixture_profile();
        let original = saved("returned", "requesting");
        let sent = saved("returned", "unchecked");
        journal.entry(&key(&p, WHO)).base = vec![original.clone()];
        journal.stage(&key(&p, WHO), vec![sent.clone()]);
        let mut store = ledger::Ledger {
            records: vec![saved("returned", "confirmed")],
            ..Default::default()
        };
        store.archive(&store.records.clone()).unwrap();
        let disk = Ok(store);
        let rows = journal.current_from(&p, WHO, &disk).unwrap();
        assert_eq!(rows[0]["state"], "confirmed");
        assert_eq!(journal.entry(&key(&p, WHO)).base, vec![original]);
        assert_eq!(journal.entry(&key(&p, WHO)).cached, Some(vec![sent]));
        assert!(journal.has_fault(&p, WHO));
        // A valid ledger may have room even though the separate send guard is held.
        assert!(disk
            .as_ref()
            .unwrap()
            .room(&json!("x".repeat(4096)))
            .is_ok());
    }

    #[test]
    fn successful_persist_retains_export_cache_and_replaces_base_after_write() {
        let journal = Journal::default();
        let p = fixture_profile();
        let rows = vec![saved("returned", "unchecked")];
        journal.stage(&key(&p, WHO), vec![saved("returned", "requesting")]);
        let mut written = String::new();
        journal
            .persist_with(
                &p,
                WHO,
                ledger::Ledger {
                    revision: 7,
                    records: rows.clone(),
                    ..Default::default()
                },
                |raw| {
                    written = raw.into();
                    Ok(())
                },
            )
            .unwrap();
        assert_eq!(
            ledger::Ledger::parse(&written, &p, WHO).unwrap().revision,
            8
        );
        assert!(!journal.has_fault(&p, WHO));
        assert_eq!(journal.entry(&key(&p, WHO)).base, rows);
        assert_eq!(
            journal
                .current_from(&p, WHO, &Err("HISTORY_UNAVAILABLE"))
                .unwrap(),
            rows
        );
        assert!(journal.has_fault(&p, WHO));
    }

    #[test]
    fn receipt_save_without_coordination_cannot_stage_or_rebase() {
        let journal = Journal::default();
        let p = fixture_profile();
        let pending = saved("pending", "requesting");
        journal.begin_wallet(&pending, None);
        let checked = saved("pending", "confirmed");
        assert_eq!(
            journal
                .save_checked(&p, WHO, &[checked.clone()], &checked)
                .unwrap_err(),
            "HISTORY_COORDINATION_UNAVAILABLE"
        );
        assert!(journal.entries.borrow().is_empty());
        assert_eq!(journal.pending().unwrap().record, pending);
        assert!(!journal.write_lock.get());
    }

    #[test]
    fn pending_capture_survives_context_change_and_only_matching_recovery_updates_it() {
        let journal = Journal::default();
        let mut original = saved("open-wallet", "requesting");
        let captured = original.clone();
        journal.begin_wallet(
            &original,
            Some(swarm_core::Display {
                decimals: 16,
                symbol: "TEST".into(),
            }),
        );
        original["data"] = json!("changed editor data");
        journal.context_changed();
        journal.update_pending(&saved("different-request", "confirmed"));
        assert_eq!(journal.pending().unwrap().record, captured);
        let checked = saved("open-wallet", "confirmed");
        journal.update_pending(&checked);
        let pending = journal.pending().unwrap();
        assert_eq!(pending.record, checked);
        assert!(pending.context_changed);
        assert_eq!(pending.display.unwrap().symbol, "TEST");
        for state in [
            "unknown",
            "unchecked",
            "confirmed",
            "failed",
            "cancelled",
            "rejected",
        ] {
            journal.begin_wallet(&saved("later", state), None);
            journal.context_changed();
            assert!(
                !journal.pending().unwrap().context_changed,
                "state: {state}"
            );
        }
    }

    #[test]
    fn legacy_encoding_archive_bytes_and_optional_null_fingerprints_stay_exact() {
        let p = fixture_profile();
        let store = ledger::Ledger::parse(&format!(" \n[ {LEGACY_RECORD} ]"), &p, WHO).unwrap();
        assert_eq!(
            serde_json::to_string(&store.records[0]).unwrap(),
            LEGACY_RECORD
        );
        assert_eq!(ledger::fingerprint(&store.records[0]), RECORD_HASH);
        assert_eq!(
            store.encode(&p, WHO).unwrap(),
            format!(r#"{{"version":2,"revision":0,"records":[{LEGACY_RECORD}],"archived":{{}}}}"#)
        );
        let archive = archive::file(&store.records, &p, WHO, "swarm-publisher-archive").unwrap();
        assert_eq!(
            archive,
            format!(
                r#"{{"chainId":100,"contract":"0x1111111111111111111111111111111111111111","format":"swarm-publisher-archive","publisher":"{WHO}","records":[{LEGACY_RECORD}],"version":1}}"#
            )
        );
        let mut explicit_null = store.records[0].clone();
        explicit_null["nonce"] = Value::Null;
        let parsed = validate(&json!([explicit_null.clone()]).to_string(), &p, WHO).unwrap();
        assert_eq!(parsed, vec![explicit_null.clone()]);
        assert_eq!(
            ledger::fingerprint(&explicit_null),
            "0x595534de6e1ccf3995cafd01d048a1db5a8079cfce32134829540b8ec5a19188"
        );
        explicit_null["requestId"] = Value::Null;
        assert_eq!(
            validate(&json!([explicit_null]).to_string(), &p, WHO).unwrap_err(),
            "INVALID_HISTORY"
        );
    }
}
