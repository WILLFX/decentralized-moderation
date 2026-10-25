use swarm_core::recovery::*;
fn record() -> VoteRecord {
    VoteRecord {
        chain_id: "10200".into(),
        contract: format!("0x{}", "11".repeat(20)),
        voter: format!("0x{}", "22".repeat(20)),
        case_id: "2".into(),
        round: 0,
        committee: 1,
        commitment: format!("0x{}", "33".repeat(32)),
        vote: 1,
        salt: format!("0x{}", "00".repeat(32)),
    }
}
#[test]
fn canonical_record_bytes_have_the_v1_field_order() {
    let v = record();
    let json = String::from_utf8(v.json_bytes()).unwrap();
    let expected = format!(
        r#"{{"chainId":"10200","contract":"0x{}","voter":"0x{}","caseId":"2","round":0,"committee":1,"commitment":"0x{}","vote":1,"salt":"0x{}"}}"#,
        "11".repeat(20),
        "22".repeat(20),
        "33".repeat(32),
        "00".repeat(32)
    );
    assert_eq!(json, expected);
    assert!(json.ends_with(&format!("\"salt\":\"0x{}\"}}", "00".repeat(32))));
    assert_eq!(
        serde_json::from_str::<VoteRecord>(&json)
            .unwrap()
            .normalized()
            .unwrap()
            .json_bytes(),
        v.json_bytes()
    );
}
#[test]
fn decimal_uint256_boundary_and_hex_normalization() {
    let mut v = record();
    v.chain_id =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935".into();
    assert!(v.clone().normalized().is_ok());
    v.chain_id =
        "115792089237316195423570985008687907853269984665640564039457584007913129639936".into();
    assert!(v.normalized().is_err());
    let mut v = record();
    v.contract = format!("0X{}", "AB".repeat(20));
    assert_eq!(
        v.normalized().unwrap().contract,
        format!("0x{}", "ab".repeat(20))
    );
}
#[test]
fn rejects_duplicate_context_and_bad_coverage() {
    let v = record();
    let p = Payload {
        version: 1,
        votes: vec![v.clone(), v],
        backed_up: vec![],
    };
    assert!(Payload::parse(&serde_json::to_vec(&p).unwrap()).is_err());
    let p = Payload {
        version: 1,
        votes: vec![],
        backed_up: vec!["A".repeat(64)],
    };
    assert!(Payload::parse(&serde_json::to_vec(&p).unwrap()).is_err());
}
#[test]
fn immutable_context_merge_and_new_committee() {
    let v = record();
    let mut conflicting = v.clone();
    conflicting.vote = 2;
    assert_eq!(
        merge(&[v.clone()], &[conflicting]).err().unwrap().0,
        "VOTE_CONFLICT"
    );
    let mut next = v.clone();
    next.committee = 2;
    assert_eq!(merge(&[v.clone()], &[v, next]).unwrap().len(), 2);
}
#[test]
fn strict_envelope_and_size_bound() {
    let e = Envelope {
        format: FORMAT.into(),
        version: 1,
        kdf: Kdf {
            name: "PBKDF2".into(),
            hash: "SHA-256".into(),
            iterations: ITERATIONS,
            salt: "ab".repeat(16),
        },
        cipher: Cipher {
            name: "AES-GCM".into(),
            iv: "cd".repeat(12),
            data: "ef".repeat(16),
        },
    };
    let json = serde_json::to_string(&e).unwrap();
    assert!(Envelope::parse(&json).is_ok());
    assert!(Envelope::parse(&json.replace("310000", "1")).is_err());
    assert!(Envelope::parse(&json.replace("\"format\":", "\"extra\":1,\"format\":")).is_err());
    assert!(Envelope::parse(&" ".repeat(MAX_FILE_BYTES + 1)).is_err());
}
#[test]
fn rejects_unknown_record_fields_and_invalid_shapes() {
    let v = record();
    let mut raw = serde_json::to_value(v).unwrap();
    raw["unknown"] = true.into();
    assert!(serde_json::from_value::<VoteRecord>(raw).is_err());
    let mut v = record();
    v.case_id = "02".into();
    assert!(v.normalized().is_err());
    let mut v = record();
    v.round = 3;
    assert!(v.normalized().is_err());
}
