use serde_json::{json, Value};
use swarm_core::*;

fn profile() -> Value {
    let pin = |byte: &str| json!({"address": format!("0x{}", byte.repeat(20)), "codeHash": keccak256_hex(&[0x60, 0])});
    json!({
        "deployment": {"chainId": "10200", "moderation": pin("12"), "stakes": pin("13"), "index": pin("14"), "token": pin("15"),
            "guidelines": {"version": "1", "hash": format!("0x{}", "34".repeat(32))}},
        "rpcUrl": "http://127.0.0.1:51282", "gatewayUrl": "http://localhost:51281/",
        "timing": {"clockErrorSeconds": 0, "maxEvidenceAgeSeconds": 30, "maxHeadLagSeconds": 30, "inclusionBudgetSeconds": 120},
        "display": {"decimals": 18, "symbol": "TEST"}
    })
}
fn parsed() -> ModeratorProfile {
    parse_profile(&profile().to_string()).unwrap()
}

#[test]
fn current_local_profile_is_compatible() {
    // Public deployment configuration only: no account keys or recovery information.
    let profile = parse_profile(include_str!("fixtures/local-moderator-profile.json")).unwrap();
    assert_eq!(profile.deployment.chain_id, 10200);
    assert_eq!(profile.deployment.guidelines.version, 1);
    assert_eq!(profile.content_path, "bytes");
    assert_eq!(profile.timing.inclusion_budget_seconds, 120);
    assert_eq!(profile.display.as_ref().unwrap().decimals, 0);
}

#[test]
fn existing_profile_defaults_and_numeric_forms() {
    let p = parsed();
    assert_eq!(p.deployment.chain_id, 10200);
    assert_eq!(p.rpc_url, "http://127.0.0.1:51282/");
    assert_eq!(p.metadata_path, "bytes");
    assert_eq!(p.content_path, "bzz");
    assert_eq!(p.guidelines_url, "./MODERATION_GUIDELINES.md");
    let mut p = profile();
    p["deployment"]["chainId"] = json!(100);
    assert!(parse_profile(&p.to_string()).is_ok());
}

#[test]
fn explicit_null_paths_use_the_same_defaults_as_missing_paths() {
    let mut value = profile();
    value["metadataPath"] = Value::Null;
    value["contentPath"] = Value::Null;
    value["guidelinesUrl"] = Value::Null;
    let actual = parse_profile(&value.to_string()).unwrap();
    let expected = parsed();
    assert_eq!(actual.metadata_path, expected.metadata_path);
    assert_eq!(actual.content_path, expected.content_path);
    assert_eq!(actual.guidelines_url, expected.guidelines_url);
}

#[test]
fn every_pin_and_guidelines_reject_zero_or_malformed_hashes() {
    for name in ["moderation", "stakes", "index", "token"] {
        for value in [
            format!("0x{}", "00".repeat(32)),
            "0x12".into(),
            format!("0x{}", "zz".repeat(32)),
        ] {
            let mut p = profile();
            p["deployment"][name]["codeHash"] = json!(value);
            assert_eq!(
                parse_profile(&p.to_string()).unwrap_err().0,
                "INVALID_DEPLOYMENT"
            );
        }
    }
    for value in [format!("0x{}", "00".repeat(32)), "0x12".into()] {
        let mut p = profile();
        p["deployment"]["guidelines"]["hash"] = json!(value);
        assert_eq!(
            parse_profile(&p.to_string()).unwrap_err().0,
            "INVALID_DEPLOYMENT"
        );
    }
}

#[test]
fn rejects_untrusted_access_without_exposing_input() {
    for input in [
        "http://remote.example/",
        "https://user:secret@example.com/",
        "https://example.com/#secret",
        "file:///tmp/a",
        "./relative",
    ] {
        assert_eq!(
            access_url(input).unwrap_err().to_string(),
            "INVALID_ACCESS_URL"
        );
    }
    for input in [
        "https://example.com/path?key=secret",
        "http://[::1]:8080",
        "http://localhost:8080",
    ] {
        assert!(access_url(input).is_ok());
    }
}

#[test]
fn malformed_profiles_never_panic() {
    for input in ["null", "[]", "{}", "not json", "{\"deployment\":null}"] {
        assert!(parse_profile(input).is_err());
    }
    assert_eq!(
        parse_profile(&" ".repeat(65537)).unwrap_err().0,
        "CONFIG_TOO_LARGE"
    );
    for (path, value) in [("chainId", json!(1)), ("chainId", json!("0x64"))] {
        let mut p = profile();
        p["deployment"][path] = value;
        assert!(parse_profile(&p.to_string()).is_err());
    }
    let mut p = profile();
    p["deployment"]["moderation"]["address"] = json!(format!("0x{}", "00".repeat(20)));
    assert_eq!(
        parse_profile(&p.to_string()).unwrap_err().0,
        "INVALID_DEPLOYMENT"
    );
    let mut p = profile();
    p["timing"]["maxHeadLagSeconds"] = json!(0);
    assert_eq!(
        parse_profile(&p.to_string()).unwrap_err().0,
        "TIMING_PROFILE_REQUIRED"
    );
    let mut p = profile();
    p["timing"]["maxHeadLagSeconds"] = json!(9007199254740992u64);
    assert!(parse_profile(&p.to_string()).is_err());
    let mut p = profile();
    p["display"]["symbol"] = json!("<script>");
    assert_eq!(
        parse_profile(&p.to_string()).unwrap_err().0,
        "INVALID_TOKEN_DISPLAY"
    );
}

#[test]
fn keccak_and_selector_match_ethereum_vectors() {
    assert_eq!(
        keccak256_hex(b""),
        "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    );
    assert_eq!(selector("transfer(address,uint256)"), "0xa9059cbb");
}

#[test]
fn abi_results_require_canonical_words() {
    let address = format!("0x{}{}", "00".repeat(12), "12".repeat(20));
    assert_eq!(
        decode_address(&address).unwrap(),
        parsed().deployment.moderation.address
    );
    assert_eq!(decode_uint(&format!("0x{:064x}", 10200)).unwrap(), 10200);
    assert!(decode_address(&format!("0x{}", "11".repeat(32))).is_err());
    assert!(decode_uint(&format!("0x{}", "ff".repeat(32))).is_err());
    assert!(decode_uint("0x01").is_err());
    assert!(decode_address(&(address + &"00".repeat(32))).is_err());
}

#[test]
fn runtime_links_and_guidelines_reject_another_deployment() {
    let d = parsed().deployment;
    assert!(verify_runtime(&d.moderation, "0x6000").is_ok());
    assert!(verify_runtime(&d.moderation, "0x6001").is_err());
    assert!(verify_runtime(&d.moderation, "0x").is_err());
    let links = link_checks(&d);
    assert_eq!(links.len(), 6);
    assert_eq!(
        links.iter().map(|l| l.signature).collect::<Vec<_>>(),
        vec![
            "stakes()",
            "token()",
            "index()",
            "moderation()",
            "token()",
            "moderation()"
        ]
    );
    assert_eq!(links[0].contract_address, d.moderation.address);
    assert_eq!(links[0].expected_address, d.stakes.address);
    assert_eq!(links[1].expected_address, d.token.address);
    assert_eq!(links[2].expected_address, d.index.address);
    assert_eq!(links[3].contract_address, d.stakes.address);
    assert_eq!(links[3].expected_address, d.moderation.address);
    assert_eq!(links[4].expected_address, d.token.address);
    assert_eq!(links[5].contract_address, d.index.address);
    assert_eq!(links[5].expected_address, d.moderation.address);
    for link in &links {
        assert!(verify_link(
            link,
            &format!("0x{}{}", "00".repeat(12), &link.expected_address[2..])
        )
        .is_ok());
        assert_eq!(
            verify_link(link, &format!("0x{}", "00".repeat(32)))
                .unwrap_err()
                .0,
            "DEPLOYMENT_MISMATCH_LINK"
        );
    }
    assert!(verify_guidelines(&d, &format!("0x{:064x}", 1), &d.guidelines.hash).is_ok());
    assert_eq!(
        verify_guidelines(&d, &format!("0x{:064x}", 2), &d.guidelines.hash)
            .unwrap_err()
            .0,
        "DEPLOYMENT_MISMATCH_GUIDELINES"
    );
}
