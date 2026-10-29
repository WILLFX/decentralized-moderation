use super::*;

#[test]
fn a_known_replacement_still_checks_when_other_unknown_requests_are_ambiguous() {
    let mut known = saved();
    known["nonce"] = json!("0x9");
    known["state"] = json!("confirmed");
    known["resolution"] = json!({"hash":tx("77")["hash"]});
    let mut unknown = saved();
    unknown["hash"] = Value::Null;
    unknown["state"] = json!("unknown");
    unknown["requestId"] = json!("unknown-1");
    let mut other = unknown.clone();
    other["requestId"] = json!("unknown-2");
    let candidate = tx("77");
    assert_eq!(
        target(
            &[known, unknown, other],
            None,
            candidate["hash"].as_str().unwrap(),
            &candidate["to"],
            &candidate["input"]
        )
        .unwrap(),
        0
    );
}

#[test]
fn choosing_a_card_cannot_override_ambiguous_unknown_requests() {
    let mut first = saved();
    first["hash"] = Value::Null;
    first["state"] = json!("unknown");
    let mut second = first.clone();
    second["requestId"] = json!("other-unknown");
    let candidate = tx("77");
    let records = vec![first, second];
    for selected in [None, Some(0), Some(1)] {
        assert_eq!(
            target(
                &records,
                selected,
                candidate["hash"].as_str().unwrap(),
                &candidate["to"],
                &candidate["input"]
            )
            .unwrap_err(),
            "HISTORY_AMBIGUOUS_TRANSACTION"
        );
    }
}
#[test]
fn a_known_receipt_cannot_clear_another_selected_request() {
    let mut second = saved();
    second["hash"] = Value::Null;
    second["state"] = json!("unknown");
    second["requestId"] = json!("other-unknown");
    let candidate = tx("66");
    assert_eq!(
        target(
            &[saved(), second],
            Some(1),
            candidate["hash"].as_str().unwrap(),
            &candidate["to"],
            &candidate["input"]
        )
        .unwrap_err(),
        "RECEIPT_BELONGS_TO_ANOTHER_REQUEST"
    );
}

#[test]
fn history_import_does_not_discard_a_later_uncertain_request_with_equal_calldata() {
    let mut existing = saved();
    existing["state"] = json!("confirmed");
    let mut later = saved();
    later["hash"] = Value::Null;
    later["state"] = json!("unknown");
    later["requestId"] = json!("later-uncertain");
    later["nonce"] = json!("0x9");
    let merged = transfers::merge_import(&[existing.clone()], vec![later.clone()]).unwrap();
    assert_eq!(merged.len(), 2);
    assert_eq!(merged[0], existing);
    assert!(merged[1]["nonce"].is_null() && merged[1]["anchor"].is_null());
    assert_eq!(
        transfers::merge_import(&merged, vec![later]).unwrap().len(),
        2
    );
    assert!(history::guard(&merged, "approve", &Value::Null, "").is_err());
}

fn saved() -> Value {
    let p = history::fixture_profile();
    json!({"chainId":100,"contract":p.deployment.moderation.address,"publisher":format!("0x{}","55".repeat(20)),"action":"approve","to":p.deployment.token.address,"data":encode_approve(&p.deployment.moderation.address,fee("1200").unwrap()).unwrap(),"intent":null,"caseId":"","state":"unchecked","hash":format!("0x{}","66".repeat(32)),"requestId":"r1","anchor":{"number":"0x10","hash":format!("0x{}","aa".repeat(32))}})
}
#[test]
fn nonce_identity_uses_the_integer_not_hex_letter_case() {
    let mut r = saved();
    r["nonce"] = json!("0xab");
    let mut candidate = tx("77");
    candidate["nonce"] = json!("0xAB");
    assert_eq!(
        classify(&r, &candidate, None).unwrap(),
        Outcome::Replacement
    );
}
fn tx(hash_byte: &str) -> Value {
    let r = saved();
    json!({"hash":format!("0x{}",hash_byte.repeat(32)),"chainId":"0x64","from":r["publisher"],"to":r["to"],"input":r["data"],"value":"0x0","nonce":"0x9","blockNumber":"0x12","blockHash":format!("0x{}","bb".repeat(32))})
}
#[test]
fn original_and_exact_speedup_use_verified_transaction_identity() {
    let r = saved();
    assert_eq!(classify(&r, &tx("66"), None).unwrap(), Outcome::Original);
    let mut original = tx("66");
    original["blockNumber"] = Value::Null;
    original["blockHash"] = Value::Null;
    assert_eq!(
        classify(&r, &tx("77"), Some(&original)).unwrap(),
        Outcome::Replacement
    );
    let mut wrong = original.clone();
    wrong["nonce"] = json!("0xa");
    assert_eq!(
        classify(&r, &tx("77"), Some(&wrong)).unwrap_err(),
        "REPLACEMENT_NONCE_MISMATCH"
    );
    wrong = original.clone();
    wrong["from"] = json!(format!("0x{}", "88".repeat(20)));
    assert!(classify(&r, &tx("77"), Some(&wrong)).is_err());
    wrong = original;
    wrong["chainId"] = json!("0x65");
    assert_eq!(
        classify(&r, &tx("77"), Some(&wrong)).unwrap_err(),
        "CHAIN_MISMATCH"
    );
}
#[test]
fn dropped_original_needs_previously_observed_nonce_and_matching_intent() {
    let mut r = saved();
    assert_eq!(
        classify(&r, &tx("77"), None).unwrap_err(),
        "ORIGINAL_NONCE_UNAVAILABLE"
    );
    r["nonce"] = json!("0x9");
    assert_eq!(classify(&r, &tx("77"), None).unwrap(), Outcome::Replacement);
    let mut changed = tx("77");
    changed["input"] = json!(encode_approve(
        &history::fixture_profile().deployment.moderation.address,
        fee("1201").unwrap()
    )
    .unwrap());
    assert_eq!(
        classify(&r, &changed, None).unwrap_err(),
        "REPLACEMENT_INTENT_MISMATCH"
    );
    changed = tx("77");
    changed["value"] = json!("0x1");
    assert!(classify(&r, &changed, None).is_err());
}
#[test]
fn cancellation_is_only_a_same_nonce_zero_value_empty_self_transfer() {
    let mut r = saved();
    r["nonce"] = json!("0x9");
    let mut cancel = tx("77");
    cancel["to"] = r["publisher"].clone();
    cancel["input"] = json!("0x");
    assert_eq!(classify(&r, &cancel, None).unwrap(), Outcome::Cancellation);
    cancel["nonce"] = json!("0xa");
    assert!(classify(&r, &cancel, None).is_err());
    cancel["nonce"] = json!("0x9");
    cancel["to"] = json!(format!("0x{}", "88".repeat(20)));
    assert_eq!(
        classify(&r, &cancel, None).unwrap_err(),
        "REPLACEMENT_INTENT_MISMATCH"
    );
}
#[test]
fn no_hash_recovery_cannot_use_an_old_receipt_or_unbounded_import() {
    let mut r = saved();
    r["hash"] = Value::Null;
    r["state"] = json!("unknown");
    assert_eq!(classify(&r, &tx("77"), None).unwrap(), Outcome::Original);
    let mut old = tx("77");
    old["blockNumber"] = json!("0x10");
    assert_eq!(
        classify(&r, &old, None).unwrap_err(),
        "TRANSACTION_PREDATES_REQUEST"
    );
    r.as_object_mut().unwrap().remove("anchor");
    assert_eq!(
        classify(&r, &tx("77"), None).unwrap_err(),
        "REQUEST_BOUNDARY_UNAVAILABLE"
    );
}
#[test]
fn replacement_keeps_original_hash_and_cancelled_request_no_longer_blocks() {
    let original = saved();
    let mut update = original.clone();
    update["nonce"] = json!("0x9");
    update["resolution"] = json!({"kind":"cancellation","hash":tx("77")["hash"],"nonce":"0x9","blockNumber":"0x12","blockHash":tx("77")["blockHash"]});
    update["state"] = json!("cancelled");
    let merged = history::merge(&[original.clone()], &[update]).unwrap();
    assert_eq!(merged[0]["hash"], original["hash"]);
    history::validate(
        &json!(merged).to_string(),
        &history::fixture_profile(),
        original["publisher"].as_str().unwrap(),
    )
    .unwrap();
    assert!(history::guard(&merged, "approve", &Value::Null, "").is_ok());
    let retained = history::merge(&merged, &[original]).unwrap();
    assert_eq!(retained[0]["state"], "cancelled");
}
#[test]
fn import_retains_replacement_hint_but_not_trusted_proof_or_terminal_status() {
    let mut r = saved();
    r["nonce"] = json!("0x9");
    r["state"] = json!("cancelled");
    r["resolution"] = json!({"hash":tx("77")["hash"]});
    reset_import(&mut r);
    assert_eq!(r["candidateHash"], tx("77")["hash"]);
    assert_eq!(r["state"], "unchecked");
    assert!(r["nonce"].is_null() && r["anchor"].is_null() && r["resolution"].is_null());
    assert_eq!(
        classify(&r, &tx("77"), None).unwrap_err(),
        "ORIGINAL_NONCE_UNAVAILABLE"
    );
    assert!(history::guard(&[r], "approve", &Value::Null, "").is_err());
}
