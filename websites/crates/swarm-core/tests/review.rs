use swarm_core::{keccak256_hex, review::*};
#[test]
fn raw_swarm_roots_match_independent_vectors() {
    for (size, expected) in [
        (
            0,
            "0xb34ca8c22b9e982354f9c7f50b470d66db428d880c8a904d5fe4ec9713171526",
        ),
        (
            4096,
            "0x2ab453aa1c7e3ac0f4b037a89e06f2391125802dacc115fb85ba2190fd4c47f2",
        ),
        (
            4097,
            "0x4e47ece0ea2d437c688fe407f8240bed436b15eb780ec3d85607ab8c22b9f3f8",
        ),
        (
            262144,
            "0xa9ae84fa621fec60ddc4bf64b9d4521424ab2b640e0a65e38d4f9e16153f0b6b",
        ),
    ] {
        let bytes: Vec<u8> = (0..size)
            .map(|i| ((i * 37 + (i >> 8) * 17 + (i >> 16) * 11 + 17) % 256) as u8)
            .collect();
        assert_eq!(swarm_reference(&bytes).unwrap(), expected);
        let mut changed = bytes.clone();
        if !changed.is_empty() {
            changed[0] ^= 1;
            assert!(verify_reference(&changed, expected).is_err());
        }
    }
    assert!(swarm_reference(&vec![0; MAX_REVIEW_BYTES + 1]).is_err());
}
fn parse(text: &str) -> bool {
    let hash = swarm_reference(text.as_bytes()).unwrap();
    parse_metadata(
        text.as_bytes(),
        &hash,
        &[keccak256_hex("biology".as_bytes())],
    )
    .is_ok()
}
#[test]
fn metadata_is_authenticated_and_matches_ordered_topics() {
    let text = r#"{"schemaVersion":1,"type":"article","title":"Example","topics":["biology"],"contentType":"text/plain"}"#;
    assert!(parse(text));
    assert!(parse_metadata(
        text.as_bytes(),
        &swarm_reference(text.as_bytes()).unwrap(),
        &[keccak256_hex(b"other")]
    )
    .is_err());
    assert!(parse_metadata(
        text.as_bytes(),
        &keccak256_hex(text.as_bytes()),
        &[keccak256_hex(b"biology")]
    )
    .is_err());
    for invalid in [
        text.replace("biology", "Biology"),
        text.replace("biology", " biology"),
        text.replace("text/plain", "text/plain\n"),
        text.replace(
            "\"schemaVersion\":1",
            "\"schemaVersion\":1,\"schemaVersion\":1",
        ),
        text.replace("\"title\":", "\"source\":null,\"title\":"),
        text.replace("\"title\":", "\"extra\":true,\"title\":"),
    ] {
        assert!(!parse(&invalid));
    }
}
#[test]
fn guidelines_pin_exact_bytes() {
    let bytes = b"Guidelines\n";
    let hash = keccak256_hex(bytes);
    assert_eq!(
        verify_guideline_bytes(bytes, &hash).unwrap(),
        "Guidelines\n"
    );
    assert!(verify_guideline_bytes(b"Guidelines", &hash).is_err());
}

#[test]
fn metadata_unicode_and_duplicate_keys_follow_v1_rules() {
    let check = |topic: &str| {
        let text=serde_json::json!({"schemaVersion":1,"type":"article","title":"Test","topics":[topic],"contentType":"text/plain"}).to_string();
        parse_metadata(
            text.as_bytes(),
            &swarm_reference(text.as_bytes()).unwrap(),
            &[keccak256_hex(topic.as_bytes())],
        )
        .is_ok()
    };
    assert!(check("café"));
    assert!(!check("cafe\u{301}"));
    assert!(!check("a\u{feff}b"));
    // U+0085 is not ECMAScript whitespace; preserve the existing v1 rule.
    assert!(check("a\u{0085}b"));
    let valid = r#"{"schemaVersion":1,"type":"article","title":"Test","topics":["biology"],"contentType":"text/plain"}"#;
    assert!(parse(
        &valid.replace("schemaVersion\":1", "schemaVersion\":1.0")
    ));
    assert!(!parse(&valid.replace(
        "\"title\":",
        "\"tit\\u006ce\":\"Duplicate\",\"title\":"
    )));
}

#[test]
fn content_is_separate_and_gateway_query_is_rejected() {
    let hash = format!("0x{}", "ab".repeat(32));
    assert_eq!(
        resource_url("http://127.0.0.1:51281/base", "bytes", &hash).unwrap(),
        format!("http://127.0.0.1:51281/base/bytes/{}", &hash[2..])
    );
    assert!(resource_url("https://example.org/?token=x", "bytes", &hash).is_err());
    assert!(separate_content_url(
        "http://127.0.0.1:51280/",
        "bzz",
        &hash,
        "http://127.0.0.1:51280"
    )
    .is_err());
    assert!(separate_content_url(
        "http://127.0.0.1:51281/",
        "bzz",
        &hash,
        "http://127.0.0.1:51280"
    )
    .is_ok());
}

#[test]
fn initial_utf8_bom_is_authenticated_then_removed_for_decoding() {
    let plain = br#"{"schemaVersion":1,"type":"article","title":"Test","topics":["biology"],"contentType":"text/plain"}"#;
    let mut bytes = vec![0xef, 0xbb, 0xbf];
    bytes.extend_from_slice(plain);
    let original_reference = swarm_reference(&bytes).unwrap();
    let keys = [keccak256_hex(b"biology")];
    assert!(parse_metadata(&bytes, &original_reference, &keys).is_ok());
    assert!(parse_metadata(&bytes, &swarm_reference(plain).unwrap(), &keys).is_err());
    // A second BOM is document content, not another encoding marker.
    let doubled = [&[0xef, 0xbb, 0xbf][..], &bytes].concat();
    assert!(parse_metadata(&doubled, &swarm_reference(&doubled).unwrap(), &keys).is_err());
    let guidelines = b"\xef\xbb\xbfPinned guidelines\n";
    assert_eq!(
        verify_guideline_bytes(guidelines, &keccak256_hex(guidelines)).unwrap(),
        "Pinned guidelines\n"
    );
    assert!(verify_guideline_bytes(guidelines, &keccak256_hex(&guidelines[3..])).is_err());
}
