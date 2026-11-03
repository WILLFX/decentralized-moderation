use serde_json::{json, Value};
use swarm_core::{moderator::*, versioning::*, *};
fn hash(n: u64) -> String {
    format!("0x{}", Uint256::from_u64(n).abi())
}
fn address(n: u64) -> String {
    format!("0x{n:040x}")
}
fn profile() -> Value {
    let pin = |n| json!({"address":address(n),"codeHash":hash(n)});
    let version = |n| {
        json!({"moderation":pin(n),"guidelines":{"version":n,"hash":hash(n+10)},
        "rulesHash":hash(n+20),"guidelinesUrl":format!("https://guidelines.example/{n}.md")})
    };
    json!({"deployment":{"chainId":10200,"moderation":pin(1),"stakes":pin(3),"index":pin(4),"token":pin(5),
        "guidelines":{"version":1,"hash":hash(11)},
        "persistent":{"authority":pin(6),"versions":[version(1),version(2)]}},
        "guidelinesUrl":"https://guidelines.example/1.md","rpcUrl":"https://rpc.example/","gatewayUrl":"https://bee.example/",
        "timing":{"clockErrorSeconds":5,"maxEvidenceAgeSeconds":30,"maxHeadLagSeconds":30,"inclusionBudgetSeconds":120}})
}
#[test]
fn versions_are_explicit_and_switch_all_origin_pins_together() {
    let p = parse_profile(&profile().to_string()).unwrap();
    let other = select(&p, &address(2)).unwrap();
    assert_eq!(other.deployment.moderation.address, address(2));
    assert_eq!(other.deployment.guidelines.version, 2);
    assert_eq!(other.guidelines_url, "https://guidelines.example/2.md");
    assert_eq!(other.deployment.stakes.address, p.deployment.stakes.address);
    assert!(select(&p, &address(99)).is_err());
    assert_eq!(runtime_pins(&p.deployment).len(), 5);
    assert!(link_checks(&p.deployment)
        .iter()
        .all(|c| c.signature != "moderation()"));
    for c in word_checks(&other.deployment).unwrap() {
        verify_word(&c, &c.expected).unwrap();
        assert!(verify_word(&c, &hash(0)).is_err());
        assert!(verify_word(&c, &format!("{}00", c.expected)).is_err());
    }
}
#[test]
fn ambiguous_missing_and_unbounded_versions_are_refused() {
    for mutation in 0..6 {
        let mut p = profile();
        match mutation {
            0 => {
                p["deployment"]["persistent"]["versions"][1] =
                    p["deployment"]["persistent"]["versions"][0].clone()
            }
            1 => p["deployment"]["moderation"]["codeHash"] = json!(hash(99)),
            2 => p["deployment"]["guidelines"]["version"] = json!(3),
            3 => p["guidelinesUrl"] = json!("https://other.example/"),
            4 => p["deployment"]["persistent"]["versions"] = json!([]),
            _ => {
                p["deployment"]["persistent"]["versions"] =
                    json!(vec![
                        p["deployment"]["persistent"]["versions"][0].clone();
                        17
                    ])
            }
        }
        assert!(
            parse_profile(&p.to_string()).is_err(),
            "mutation {mutation}"
        );
    }
}
#[test]
fn old_profiles_keep_their_serialized_identity_and_six_links() {
    let p = parse_profile(include_str!("fixtures/local-moderator-profile.json")).unwrap();
    assert!(p.deployment.persistent.is_none());
    assert!(serde_json::to_value(&p.deployment)
        .unwrap()
        .get("persistent")
        .is_none());
    assert_eq!(link_checks(&p.deployment).len(), 6);
    assert_eq!(runtime_pins(&p.deployment).len(), 4);
    assert!(word_checks(&p.deployment).unwrap().is_empty());
}
fn case(phase: u64, action: u64, target: u64) -> CaseInfo {
    let mut values = [0; 25];
    values[4] = 1;
    values[5] = action;
    values[6] = target;
    values[7] = phase;
    decode_case(&format!(
        "0x{}",
        values
            .iter()
            .map(|v| Uint256::from_u64(*v).abi())
            .collect::<String>()
    ))
    .unwrap()
}
fn registration(exists: u64, terminal: u64, target: u64, id: u64) -> String {
    format!(
        "0x{}{}{}{}",
        Uint256::from_u64(exists).abi(),
        Uint256::from_u64(terminal).abi(),
        address_word(&address(target)).unwrap_or_else(|_| "00".repeat(32)),
        Uint256::from_u64(id).abi()
    )
}
#[test]
fn registration_does_not_confuse_equal_case_ids_or_terminal_state() {
    let p = parse_profile(&profile().to_string()).unwrap();
    assert_eq!(
        registration_args(&address(1), Uint256::from_u64(12))
            .unwrap()
            .len(),
        128
    );
    assert_ne!(
        registration_args(&address(1), Uint256::from_u64(12)).unwrap(),
        registration_args(&address(2), Uint256::from_u64(12)).unwrap()
    );
    assert!(
        verify_registration(&p.deployment, &case(1, 0, 0), &registration(1, 0, 0, 0))
            .unwrap()
            .is_none()
    );
    assert!(verify_registration(&p.deployment, &case(5, 0, 0), &registration(1, 0, 0, 0)).is_err());
    assert!(verify_registration(&p.deployment, &case(1, 0, 0), &registration(0, 0, 0, 0)).is_err());
    assert_eq!(
        verify_registration(&p.deployment, &case(5, 1, 12), &registration(1, 1, 2, 12)).unwrap(),
        Some(address(2))
    );
    assert!(
        verify_registration(&p.deployment, &case(5, 1, 12), &registration(1, 1, 99, 12)).is_err()
    );
    assert!(
        verify_registration(&p.deployment, &case(5, 1, 12), &registration(1, 1, 2, 13)).is_err()
    );
}
#[test]
fn index_origin_binds_case_contract_full_width_id_and_original_guidelines() {
    let p = parse_profile(&profile().to_string()).unwrap();
    let id = Uint256::decimal("18446744073709551616").unwrap();
    let origin = |n| {
        format!(
            "0x{}{}{}{}",
            address_word(&address(n)).unwrap(),
            id.abi(),
            Uint256::from_u64(n).abi(),
            &hash(n + 10)[2..]
        )
    };
    let a = decode_origin(&p.deployment, &origin(1)).unwrap();
    let b = decode_origin(&p.deployment, &origin(2)).unwrap();
    assert_eq!(a.case_id, b.case_id);
    assert_ne!(a, b);
    assert_eq!(a.case_id, id);
    let wrong = format!(
        "0x{}{}{}{}",
        address_word(&address(1)).unwrap(),
        id.abi(),
        Uint256::from_u64(2).abi(),
        &hash(12)[2..]
    );
    assert!(decode_origin(&p.deployment, &wrong).is_err());
    assert!(decode_origin(&p.deployment, &format!("{}00", origin(1))).is_err());
}

#[test]
fn normalized_guideline_urls_survive_profile_round_trips_and_selection() {
    let mut raw = profile();
    raw["guidelinesUrl"] = json!("https://GUIDELINES.example:443/1.md");
    raw["deployment"]["persistent"]["versions"][0]["guidelinesUrl"] = raw["guidelinesUrl"].clone();
    let p = parse_profile(&raw.to_string()).unwrap();
    assert_eq!(p.guidelines_url, "https://guidelines.example/1.md");
    parse_profile(&serde_json::to_string(&p).unwrap()).unwrap();
    let selected = select(&p, &address(2)).unwrap();
    parse_profile(&serde_json::to_string(&selected).unwrap()).unwrap();
}

#[test]
fn identity_display_excludes_private_access_settings_without_losing_pins() {
    let mut raw = profile();
    raw["deployment"]["persistent"]["versions"][1]["guidelinesUrl"] =
        json!("https://guidelines.example/private-path?token=do-not-display");
    let p = parse_profile(&raw.to_string()).unwrap();
    let shown = identity(&p.deployment).unwrap().to_string();
    assert!(!shown.contains("do-not-display"));
    assert!(!shown.contains("private-path"));
    assert!(shown.contains("rulesHash"));
    assert!(shown.contains("codeHash"));
    assert!(version(&p.deployment, &address(2))
        .unwrap()
        .guidelines_url
        .contains("do-not-display"));
}
