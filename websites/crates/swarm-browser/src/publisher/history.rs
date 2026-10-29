use super::*;
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
pub(super) fn has_fault(a: &Rc<RefCell<App>>, p: &ModeratorProfile, who: &str) -> bool {
    a.borrow().history_faults.contains(&key(p, who))
}
pub(super) fn load_store(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
) -> Result<ledger::Ledger> {
    let mut store = disk(p, who)?;
    // Clean tab caches are snapshots, never instructions to overwrite newer disk state.
    let k = key(p, who);
    if has_fault(a, p, who) {
        let cached = a.borrow().history_cache.get(&k).cloned();
        if let Some(cached) = cached {
            let base = a
                .borrow()
                .history_bases
                .get(&k)
                .cloned()
                .unwrap_or_default();
            store.records = merge_cache(&store.records, &base, &cached)?;
            store.reconcile();
        }
    }
    Ok(store)
}
pub(super) fn load_current(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
) -> Result<Vec<Value>> {
    match load_store(a, p, who) {
        Ok(store) => {
            if !has_fault(a, p, who) {
                a.borrow_mut()
                    .history_bases
                    .insert(key(p, who), store.records.clone());
            }
            Ok(store.records)
        }
        Err(error) => {
            let k = key(p, who);
            a.borrow_mut().history_faults.insert(k.clone());
            a.borrow().history_cache.get(&k).cloned().ok_or(error)
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
                if ledger::resolved(current)
                    && !ledger::resolved(r)
                    && same_hex_bytes(&current["hash"], &r["hash"], Some(32))
                {
                    continue;
                }
                if ledger::resolved(current)
                    && ledger::resolved(r)
                    && current["state"] != r["state"]
                {
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
fn stage(a: &Rc<RefCell<App>>, k: &str, records: Vec<Value>) {
    let mut state = a.borrow_mut();
    state.history_cache.insert(k.into(), records);
    state.history_faults.insert(k.into());
}
fn persist_with(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    mut store: ledger::Ledger,
    write: impl FnOnce(&str) -> Result<()>,
) -> Result<()> {
    let k = key(p, who);
    stage(a, &k, store.records.clone());
    store.reconcile();
    store.revision = store
        .revision
        .checked_add(1)
        .ok_or("HISTORY_REVISION_LIMIT")?;
    let raw = store.encode(p, who)?;
    write(&raw)?;
    a.borrow_mut()
        .history_bases
        .insert(k.clone(), store.records.clone());
    a.borrow_mut().history_faults.remove(&k);
    Ok(())
}
pub(super) fn persist(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    store: ledger::Ledger,
) -> Result<()> {
    if !a.borrow().history_write_lock {
        return Err("HISTORY_COORDINATION_UNAVAILABLE");
    }
    let k = key(p, who);
    persist_with(a, p, who, store, |raw| {
        storage()?
            .set_item(&k, raw)
            .map_err(|_| "HISTORY_SAVE_FAILED")
    })
}
pub(super) fn save(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    records: &[Value],
) -> Result<()> {
    let k = key(p, who);
    let cached = if has_fault(a, p, who) {
        a.borrow()
            .history_cache
            .get(&k)
            .cloned()
            .unwrap_or_default()
    } else {
        vec![]
    };
    let incoming = merge_retaining(&cached, records)?;
    // Stage before bounds, parsing, quota or disk failures. Export sees all known hashes.
    stage(a, &k, incoming.clone());
    let mut store = disk(p, who)?;
    let base = a
        .borrow()
        .history_bases
        .get(&k)
        .cloned()
        .unwrap_or_default();
    store.records = merge_cache(&store.records, &base, &incoming)?;
    persist(a, p, who, store)
}
fn rebase_checked(base: &mut Vec<Value>, disk: &[Value], id: &str) {
    base.retain(|r| recovery::identity(r) != id);
    if let Some(r) = disk.iter().find(|r| recovery::identity(r) == id) {
        base.push(r.clone());
    }
}
// Only the canonical receipt checker calls this after its final context checks.
// Rebase that one checked identity; unrelated dirty rows still undergo conflict checks.
pub(super) fn save_checked(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    records: &[Value],
    checked: &Value,
) -> Result<()> {
    if !a.borrow().history_write_lock {
        return Err("HISTORY_COORDINATION_UNAVAILABLE");
    }
    let k = key(p, who);
    let cached = a
        .borrow()
        .history_cache
        .get(&k)
        .cloned()
        .unwrap_or_default();
    stage(a, &k, merge_retaining(&cached, records)?);
    let current = disk(p, who)?;
    rebase_checked(
        a.borrow_mut().history_bases.entry(k).or_default(),
        &current.records,
        &recovery::identity(checked),
    );
    save(a, p, who, records)
}
pub(super) fn ensure_room(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    reservation: &Value,
) -> Result<()> {
    load_store(a, p, who)?.room(reservation)
}
pub(super) fn import_room(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    records: &[Value],
) -> Result<()> {
    let mut store = load_store(a, p, who)?;
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
pub(super) fn cancel_unsent(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    reservation: &Value,
) {
    if let Some(records) = a.borrow_mut().history_cache.get_mut(&key(p, who)) {
        records.retain(|r| r["requestId"] != reservation["requestId"] || !r["hash"].is_null());
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
        if matching
            && !["confirmed", "failed", "rejected", "cancelled"]
                .contains(&r["state"].as_str().unwrap_or(""))
        {
            return Err("CHECK_PRIOR_TRANSACTION_BEFORE_RESENDING");
        }
        repeated |=
            matching && r["state"] == "confirmed" && r["action"] == "submit" && action == "submit";
    }
    Ok(repeated)
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
        a.borrow_mut()
            .history_cache
            .insert(key(&p, &who), vec![sent.clone()]);
        a.borrow_mut()
            .history_cache
            .insert(key(&p, &other), vec![reservation.clone()]);
        cancel_unsent(&a, &p, &other, &reservation);
        assert_eq!(a.borrow().history_cache[&key(&p, &who)], vec![sent]);
        assert!(a.borrow().history_cache[&key(&p, &other)].is_empty());
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
            persist_with(&a, &p, who, store, |_| Err("HISTORY_SAVE_FAILED")).unwrap_err(),
            "HISTORY_SAVE_FAILED"
        );
        assert!(has_fault(&a, &p, who));
        assert_eq!(
            a.borrow().history_cache[&key(&p, who)][0]["hash"],
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
                r["hash"].is_null()
                    && same_hex_bytes(&r["to"], to, Some(20))
                    && same_hex_bytes(&r["data"], data, None)
                    && ["requesting", "unknown"].contains(&r["state"].as_str().unwrap_or(""))
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

// Serialize all journal writers across tabs. A busy lock refuses instead of queuing a send.
pub(super) async fn coordinated(a: &Rc<RefCell<App>>, action: &'static str) -> Result<()> {
    if ![
        "approve",
        "submit",
        "refund",
        "receipt",
        "approvalreceipt",
        "submissionreceipt",
        "publication",
        "importhistory",
        "savehistory",
        "commitarchive",
    ]
    .contains(&action)
    {
        return run(a, action).await;
    }
    let epoch = a.borrow().epoch;
    let navigator = js_sys::Reflect::get(web_sys::window().unwrap().as_ref(), &"navigator".into())
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?;
    let locks = js_sys::Reflect::get(&navigator, &"locks".into())
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?;
    let request = js_sys::Reflect::get(&locks, &"request".into())
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?;
    let result = Rc::new(RefCell::new(None));
    let output = result.clone();
    let state = a.clone();
    let callback = Closure::<dyn FnMut(JsValue) -> js_sys::Promise>::new(move |lock: JsValue| {
        let output = output.clone();
        let state = state.clone();
        wasm_bindgen_futures::future_to_promise(async move {
            let r = if lock.is_null() {
                Err("HISTORY_BUSY_IN_ANOTHER_TAB")
            } else if let Err(e) = active(&state, epoch) {
                Err(e)
            } else {
                state.borrow_mut().history_write_lock = true;
                let result = run(&state, action).await;
                state.borrow_mut().history_write_lock = false;
                result
            };
            *output.borrow_mut() = Some(r);
            Ok(JsValue::UNDEFINED)
        })
    });
    let options = js_sys::Object::new();
    js_sys::Reflect::set(&options, &"ifAvailable".into(), &JsValue::TRUE)
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?;
    let promise = request
        .call3(
            &locks,
            &"swarm-publisher-history-v2".into(),
            &options,
            callback.as_ref(),
        )
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?
        .dyn_into::<js_sys::Promise>()
        .map_err(|_| "HISTORY_COORDINATION_UNAVAILABLE")?;
    JsFuture::from(promise)
        .await
        .map_err(|_| "HISTORY_COORDINATION_FAILED")?;
    let r = result
        .borrow_mut()
        .take()
        .ok_or("HISTORY_COORDINATION_FAILED")?;
    r
}
