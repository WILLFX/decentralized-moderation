//! Explicit file verification and atomic archive markers; never clears uncertainty.
use super::*;
pub(super) struct Prepared {
    pub raw: String,
    pub verified: bool,
}
fn envelope(records: &[Value], p: &ModeratorProfile, who: &str, format: &str) -> Value {
    json!({"format":format,"version":1,"chainId":p.deployment.chain_id,"contract":p.deployment.moderation.address,"publisher":who,"records":records})
}
pub(super) fn file(
    records: &[Value],
    p: &ModeratorProfile,
    who: &str,
    format: &str,
) -> Result<String> {
    let raw = envelope(records, p, who, format).to_string();
    if records.len() > ledger::ACTIVE_COUNT || raw.len() > ledger::FILE_BYTES {
        return Err("ARCHIVE_FILE_LIMIT");
    }
    Ok(raw)
}
pub(super) fn page(records: &[Value], requested: usize) -> (Vec<Value>, usize) {
    let mut pages = vec![Vec::new()];
    let mut size = 0;
    for record in records.iter().rev() {
        let bytes = record.to_string().len();
        if !pages.last().unwrap().is_empty()
            && (pages.last().unwrap().len() >= ledger::PAGE
                || size + bytes > ledger::FILE_BYTES - 8192)
        {
            pages.push(Vec::new());
            size = 0;
        }
        size += bytes;
        pages.last_mut().unwrap().push(record.clone());
    }
    let count = pages.len();
    (pages.swap_remove(requested.min(count - 1)), count)
}
fn batch(records: &[Value]) -> Vec<Value> {
    let mut selected = Vec::new();
    let mut size = 0;
    for r in records {
        let bytes = r.to_string().len() + 1;
        if selected.len() >= ledger::ACTIVE_COUNT || size + bytes > ledger::FILE_BYTES - 8192 {
            break;
        }
        selected.push(r.clone());
        size += bytes;
    }
    selected
}
pub(super) fn prepare(a: &Rc<RefCell<App>>) -> Result<()> {
    a.borrow_mut().archive_candidate = None;
    let (p, who, _) = context(a)?;
    let s = history::load_store(a, &p, &who)?;
    let all = s.eligible();
    let records = batch(&all);
    if records.is_empty() {
        return Err("NOTHING_TO_ARCHIVE");
    }
    let raw = file(&records, &p, &who, "swarm-publisher-archive")?;
    transfers::download("swarm-publisher-archive.json", &raw)?;
    let hash = swarm_core::keccak256_hex(raw.as_bytes());
    a.borrow_mut().archive_candidate = Some(Prepared {
        raw,
        verified: false,
    });
    text("archive-feedback",&format!("Backup download requested for {} resolved records (one bounded batch). No records have moved. Select the saved file below and verify it. Expected exact-byte fingerprint: {hash}.",records.len()));
    Ok(())
}
pub(super) async fn verify(a: &Rc<RefCell<App>>) -> Result<()> {
    let (_, _, epoch) = context(a)?;
    let raw = {
        let mut s = a.borrow_mut();
        let c = s
            .archive_candidate
            .as_mut()
            .ok_or("ARCHIVE_PREPARE_REQUIRED")?;
        c.verified = false;
        c.raw.clone()
    };
    let f = input("archivefile")
        .files()
        .and_then(|f| f.get(0))
        .ok_or("ARCHIVE_FILE_REQUIRED")?;
    if f.size() > ledger::FILE_BYTES as f64 {
        return Err("ARCHIVE_FILE_LIMIT");
    }
    let bytes = setup::file_bytes(&f, ledger::FILE_BYTES).await?;
    active(a, epoch)?;
    if bytes != raw.as_bytes() {
        return Err("ARCHIVE_FILE_MISMATCH");
    }
    a.borrow_mut()
        .archive_candidate
        .as_mut()
        .ok_or("ARCHIVE_PREPARE_REQUIRED")?
        .verified = true;
    text("archive-feedback","The selected saved file exactly matches the prepared backup. No records have moved. Archive explicitly; uncertain requests and saved publication links will remain.");
    Ok(())
}
pub(super) async fn commit(a: &Rc<RefCell<App>>) -> Result<()> {
    if !a
        .borrow()
        .archive_candidate
        .as_ref()
        .is_some_and(|c| c.verified)
    {
        return Err("ARCHIVE_VERIFY_REQUIRED");
    }
    let (p, who, epoch) = context(a)?;
    // Check the selected file again; changing a picker cannot reuse old verification.
    verify(a).await?;
    active(a, epoch)?;
    let raw = a.borrow().archive_candidate.as_ref().unwrap().raw.clone();
    let value: Value = serde_json::from_str(&raw).map_err(|_| "INVALID_HISTORY")?;
    let records = value["records"].as_array().ok_or("INVALID_HISTORY")?;
    let mut store = history::load_store(a, &p, &who)?;
    store.archive(records)?;
    history::persist(a, &p, &who, store)?;
    a.borrow_mut().archive_candidate = None;
    text("archive-feedback",&format!("Archived {} resolved transaction records locally after verifying their backup. Their full records remain in history and My publications. Active uncertain requests were retained. No transaction was sent.",records.len()));
    Ok(())
}
pub(super) fn room(a: &Rc<RefCell<App>>) -> bool {
    context(a)
        .and_then(|(p, who, _)| history::load_store(a, &p, &who))
        .is_ok_and(|s| s.room(&json!("x".repeat(4096))).is_ok())
}
fn enable(id: &str, yes: bool) {
    if yes {
        el(id).remove_attribute("disabled").unwrap();
    } else {
        el(id).set_attribute("disabled", "").unwrap();
    }
}
pub(super) fn render(a: &Rc<RefCell<App>>) {
    let s = a.borrow();
    let busy = s.busy;
    let candidate = s.archive_candidate.is_some();
    let verified = s.archive_candidate.as_ref().is_some_and(|c| c.verified);
    drop(s);
    let store = context(a).and_then(|(p, who, _)| history::load_store(a, &p, &who));
    let eligible = store.as_ref().is_ok_and(|s| !s.eligible().is_empty());
    if let Ok(store) = store {
        let active = store.active();
        let bytes = serde_json::to_vec(&active).map(|v| v.len()).unwrap_or(0);
        let total = serde_json::to_vec(&store).map(|v| v.len()).unwrap_or(0);
        let uncertain = active.iter().filter(|r| !ledger::resolved(r)).count();
        let note = if room(a) {
            "Space is reserved for returned hashes and receipt updates."
        } else if eligible {
            "Archive resolved records after verifying their saved backup before another send."
        } else {
            "No records can safely be archived. Keep uncertain requests and reconcile their receipts; do not clear browser storage."
        };
        text("history-capacity",&format!("Active: {} / {} records; {bytes} / {} bytes. Unresolved: {uncertain}. Eligible for archive: {}. Archived locally: {}. Total retained: {} / {} records; {total} / {} bytes. {note} Browser storage may refuse a write earlier; a failed save retains evidence in this tab for export and retry.",active.len(),ledger::ACTIVE_COUNT,ledger::ACTIVE_BYTES,store.eligible().len(),store.archived.len(),store.records.len(),ledger::TOTAL_COUNT,ledger::TOTAL_BYTES));
    } else {
        text("history-capacity","Connect the intended account and load its history to see active and archive capacity. A history error must be resolved before sending.");
    }
    enable("preparearchive", !busy && eligible);
    enable(
        "verifyarchive",
        !busy && candidate && input("archivefile").files().is_some_and(|f| f.length() > 0),
    );
    enable("commitarchive", !busy && verified);
    for id in [
        "historyprev",
        "historynext",
        "publicationprev",
        "publicationnext",
    ] {
        if busy || context(a).is_err() {
            enable(id, false);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn archive_batches_recover_when_refreshed_old_records_exceed_active_limit() {
        let mut store = ledger::Ledger::default();
        for i in 0..200 {
            store
                .records
                .push(json!({"requestId":format!("r{i}"),"state":"confirmed","nonce":"0x1"}));
        }
        let first = store.records[..100].to_vec();
        store.archive(&first).unwrap();
        store.records[0]["nonce"] = json!("0x2");
        store.reconcile();
        assert_eq!(store.eligible().len(), 101);
        let chosen = batch(&store.eligible());
        assert_eq!(chosen.len(), 100);
        store.archive(&chosen).unwrap();
        let last = batch(&store.eligible());
        assert_eq!(last.len(), 1);
        store.archive(&last).unwrap();
        assert!(store.active().is_empty());
    }
    #[test]
    fn saved_file_binds_context_and_exact_records() {
        let p = history::fixture_profile();
        let raw = file(&[], &p, "account", "swarm-publisher-archive").unwrap();
        assert!(raw.contains("swarm-publisher-archive"));
        assert!(raw.contains("account"));
    }
    #[test]
    fn history_pages_bound_visible_records_and_export_size() {
        let rows = (0..31).map(|i| json!({"number":i})).collect::<Vec<_>>();
        let (page, count) = self::page(&rows, 0);
        assert_eq!(count, 4);
        assert_eq!(page.len(), 10);
        assert_eq!(page[0]["number"], 30);
        assert_eq!(self::page(&rows, 99).0.len(), 1);
    }
}
