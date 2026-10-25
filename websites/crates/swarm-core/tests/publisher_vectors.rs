use serde_json::Value;
use swarm_core::publisher::create_draft;

#[test]
fn publisher_bytes_and_references_match_v1_vectors() {
    let vectors: Value =
        serde_json::from_str(include_str!("../../../test/publisher-vectors.json")).unwrap();
    for vector in vectors.as_array().unwrap() {
        let draft = create_draft(
            vector["contentReference"].as_str().unwrap(),
            &vector["metadata"],
        )
        .unwrap();
        assert_eq!(
            String::from_utf8(draft.bytes).unwrap(),
            vector["expectedBytes"].as_str().unwrap()
        );
        assert_eq!(draft.meta_hash, vector["metaHash"].as_str().unwrap());
        let topics: Vec<String> = vector["topicKeys"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_str().unwrap().to_owned())
            .collect();
        assert_eq!(draft.topic_keys, topics);
    }
}
