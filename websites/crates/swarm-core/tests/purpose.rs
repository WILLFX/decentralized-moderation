use serde_json::{json, Value};
use swarm_core::{parse_profile, ProfilePurpose};

fn original() -> Value {
    serde_json::from_str(include_str!("fixtures/local-moderator-profile.json")).unwrap()
}

#[test]
fn omitted_purpose_preserves_standard_profile_serialization() {
    let p = parse_profile(&original().to_string()).unwrap();
    assert_eq!(p.purpose, ProfilePurpose::Standard);
    assert!(serde_json::to_value(&p).unwrap().get("purpose").is_none());
    assert!(p.purpose.check_publication("approve").is_ok());
    assert!(p.purpose.check_publication("submit").is_ok());
    assert!(p.purpose.check_staking("approveStake").is_ok());
    assert!(p.purpose.check_staking("stake").is_ok());
}

#[test]
fn existing_work_blocks_only_new_payments_and_fresh_staking() {
    let mut raw = original();
    raw["purpose"] = json!("existingWork");
    let p = parse_profile(&raw.to_string()).unwrap();
    for action in ["approve", "submit"] {
        assert_eq!(
            p.purpose.check_publication(action).unwrap_err().0,
            "EXISTING_WORK_ONLY"
        );
    }
    for action in ["approveStake", "stake"] {
        assert_eq!(
            p.purpose.check_staking(action).unwrap_err().0,
            "EXISTING_WORK_ONLY"
        );
    }
    for action in ["refund", "receipt", "case", "history"] {
        p.purpose.check_publication(action).unwrap();
    }
    p.purpose.check_staking("withdraw").unwrap();
    let roundtrip = parse_profile(&serde_json::to_string(&p).unwrap()).unwrap();
    assert_eq!(roundtrip.purpose, ProfilePurpose::ExistingWork);
    assert_eq!(
        roundtrip.deployment.moderation.address,
        p.deployment.moderation.address
    );
}

#[test]
fn malformed_purpose_never_silently_enables_new_work() {
    for value in [
        json!(null),
        json!(true),
        json!("existing-work"),
        json!(""),
        json!({}),
    ] {
        let mut raw = original();
        raw["purpose"] = value;
        assert!(parse_profile(&raw.to_string()).is_err());
    }
}

#[test]
fn reader_accepts_existing_work_without_changing_index_or_paging() {
    let p = parse_profile(&original().to_string()).unwrap();
    let raw = json!({"purpose":"existingWork","deployment":p.deployment,
        "rpcUrl":p.rpc_url,"gatewayUrl":p.gateway_url,"contentGatewayUrl":"http://localhost:1633",
        "pageSize":4,"scanSize":10});
    let reader = swarm_core::search::parse_profile(&raw.to_string()).unwrap();
    assert_eq!(reader.access.purpose, ProfilePurpose::ExistingWork);
    assert_eq!(reader.page_size, 4);
    assert_eq!(reader.scan_size, 10);
}

#[test]
fn public_existing_work_sources_keep_their_original_registries() {
    for (moderator, reader) in [
        (
            include_str!(
                "../../../../deployments/chiado/existing-work/earlier-workflow/moderator.json"
            ),
            include_str!(
                "../../../../deployments/chiado/existing-work/earlier-workflow/reader.json"
            ),
        ),
        (
            include_str!(
                "../../../../deployments/chiado/existing-work/released-mvp/moderator.json"
            ),
            include_str!("../../../../deployments/chiado/existing-work/released-mvp/reader.json"),
        ),
    ] {
        let m = parse_profile(moderator).unwrap();
        let r = swarm_core::search::parse_profile(reader).unwrap();
        assert_eq!(m.purpose, ProfilePurpose::ExistingWork);
        assert_eq!(r.access.purpose, ProfilePurpose::ExistingWork);
        assert_eq!(
            serde_json::to_value(&m.deployment).unwrap(),
            serde_json::to_value(&r.access.deployment).unwrap()
        );
        assert!(m.deployment.persistent.is_none());
    }
}

#[test]
fn current_public_profiles_keep_shared_identity_and_access_modes() {
    for (moderator, reader, path) in [
        (
            include_str!("../../../../deployments/chiado/profiles/raw/moderator.json"),
            include_str!("../../../../deployments/chiado/profiles/raw/reader.json"),
            "bytes",
        ),
        (
            include_str!("../../../../deployments/chiado/profiles/collections/moderator.json"),
            include_str!("../../../../deployments/chiado/profiles/collections/reader.json"),
            "bzz",
        ),
    ] {
        let m = parse_profile(moderator).unwrap();
        let r = swarm_core::search::parse_profile(reader).unwrap();
        assert_eq!(m.purpose, ProfilePurpose::Standard);
        assert_eq!(r.access.purpose, ProfilePurpose::Standard);
        assert_eq!(
            serde_json::to_value(&m.deployment).unwrap(),
            serde_json::to_value(&r.access.deployment).unwrap()
        );
        assert!(m.deployment.persistent.is_some());
        assert_eq!(m.rpc_url, r.access.rpc_url);
        assert_eq!(m.metadata_path, "bytes");
        assert_eq!(r.access.metadata_path, "bytes");
        assert_eq!(m.content_path, path);
        assert_eq!(r.access.content_path, path);
    }
}
