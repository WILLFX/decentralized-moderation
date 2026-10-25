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
    if raw.len() > 256 * 1024 {
        return Err("HISTORY_SIZE_LIMIT");
    }
    let records: Vec<Value> = serde_json::from_str(raw).map_err(|_| "INVALID_HISTORY")?;
    if records.len() > 100 {
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
    }
    Ok(records)
}
/// Merge record identity without deleting uncertain broadcasts or promoting imported status.
/// The later slice contains explicit local receipt updates and therefore wins for the same request.
pub(super) fn merge(base: &[Value], updates: &[Value]) -> Result<Vec<Value>> {
    let mut result = Vec::<Value>::new();
    for update in base.iter().chain(updates.iter()) {
        let index = result.iter().position(|old| {
            (!update["requestId"].is_null() && old["requestId"] == update["requestId"])
                || (!update["hash"].is_null() && old["hash"] == update["hash"])
        });
        if let Some(index) = index {
            let old = &result[index];
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
            if next["hash"].is_null() && !old["hash"].is_null() {
                next["hash"] = old["hash"].clone();
                next["state"] = old["state"].clone();
            }
            result[index] = next;
        } else {
            result.push(update.clone());
        }
    }
    if result.len() > 100
        || serde_json::to_vec(&result)
            .map_err(|_| "INVALID_HISTORY")?
            .len()
            > 256 * 1024
    {
        return Err("HISTORY_SIZE_LIMIT");
    }
    Ok(result)
}
fn disk(p: &ModeratorProfile, who: &str) -> Result<Vec<Value>> {
    let raw = storage()?
        .get_item(&key(p, who))
        .map_err(|_| "HISTORY_UNAVAILABLE")?
        .unwrap_or_else(|| "[]".into());
    validate(&raw, p, who)
}
pub(super) fn has_fault(a: &Rc<RefCell<App>>, p: &ModeratorProfile, who: &str) -> bool {
    a.borrow().history_faults.contains(&key(p, who))
}
pub(super) fn load_current(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
) -> Result<Vec<Value>> {
    let k = key(p, who);
    let cached = a.borrow().history_cache.get(&k).cloned();
    match disk(p, who) {
        Ok(saved) => merge(&saved, cached.as_deref().unwrap_or(&[])),
        Err(error) => {
            a.borrow_mut().history_faults.insert(k);
            cached.ok_or(error)
        }
    }
}
pub(super) fn save(
    a: &Rc<RefCell<App>>,
    p: &ModeratorProfile,
    who: &str,
    records: &[Value],
) -> Result<()> {
    let k = key(p, who);
    let cached = a
        .borrow()
        .history_cache
        .get(&k)
        .cloned()
        .unwrap_or_default();
    let incoming = merge(&cached, records)?; // Retain uncertain hashes before every fallible storage operation.
    a.borrow_mut()
        .history_cache
        .insert(k.clone(), incoming.clone());
    a.borrow_mut().history_faults.insert(k.clone());
    let saved = disk(p, who)?;
    let full = merge(&saved, &incoming)?;
    let raw = serde_json::to_string(&full).map_err(|_| "INVALID_HISTORY")?;
    validate(&raw, p, who)?;
    a.borrow_mut().history_cache.insert(k.clone(), full.clone());
    storage()?
        .set_item(&k, &raw)
        .map_err(|_| "HISTORY_SAVE_FAILED")?;
    a.borrow_mut().history_faults.remove(&k);
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
pub(super) fn guard(records: &[Value], action: &str, intent: &Value, caseid: &str) -> Result<()> {
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
            && !["confirmed", "failed", "rejected"].contains(&r["state"].as_str().unwrap_or(""))
        {
            return Err("CHECK_PRIOR_TRANSACTION_BEFORE_RESENDING");
        }
        if matching&&r["state"]=="confirmed"&&r["action"]=="submit"&&action=="submit"&&!web_sys::window().unwrap().confirm_with_message("This exact publication already has a confirmed submission. Submit it again deliberately?").map_err(|_|"CONFIRMATION_FAILED")?{return Err("RESUBMISSION_CANCELLED");}
    }
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
