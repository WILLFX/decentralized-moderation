//! Exact metadata authoring and unsigned LIST publication for unchanged contracts.
use crate::moderator::Uint256;
use crate::review::{parse_metadata, swarm_reference};
use crate::{keccak256_hex, selector, CoreError};
use serde_json::Value;
use unicode_normalization::UnicodeNormalization;
type Result<T> = std::result::Result<T, CoreError>;
#[derive(Clone, Debug)]
pub struct Draft {
    pub content_hash: String,
    pub meta_hash: String,
    pub topic_keys: Vec<String>,
    pub bytes: Vec<u8>,
    pub changes: Vec<String>,
}
pub fn normalize_reference(value: &str) -> Result<String> {
    let s = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .unwrap_or(value);
    if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()) || s.bytes().all(|b| b == b'0') {
        return Err(CoreError("INVALID_REFERENCE"));
    }
    Ok(format!("0x{}", s.to_ascii_lowercase()))
}
fn hash(value: &str) -> Result<String> {
    normalize_reference(value)
}
fn whitespace(c: char) -> bool {
    matches!(c,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}')
}
fn normalize_topic(value: &str) -> String {
    value
        .nfc()
        .collect::<String>()
        .to_lowercase()
        .nfc()
        .collect::<String>()
        .split(whitespace)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}
pub fn create_draft(content: &str, metadata: &Value) -> Result<Draft> {
    let content_hash = hash(content)?;
    let object = metadata.as_object().ok_or(CoreError("INVALID_METADATA"))?;
    let order = [
        "schemaVersion",
        "type",
        "title",
        "description",
        "topics",
        "language",
        "contentType",
        "source",
    ];
    if object.keys().any(|k| !order.contains(&k.as_str())) {
        return Err(CoreError("INVALID_METADATA"));
    }
    let input = object
        .get("topics")
        .and_then(Value::as_array)
        .ok_or(CoreError("INVALID_TOPICS"))?;
    if !(1..=5).contains(&input.len()) {
        return Err(CoreError("INVALID_TOPICS"));
    }
    let mut changes = vec![];
    let mut topics = vec![];
    for item in input {
        let original = item.as_str().ok_or(CoreError("INVALID_TOPICS"))?;
        let normalized = normalize_topic(original);
        if topics.contains(&normalized) {
            return Err(CoreError("DUPLICATE_TOPICS"));
        }
        if normalized != original {
            changes.push(format!("{} → {}", original, normalized));
        }
        topics.push(normalized);
    }
    let topic_keys = topics
        .iter()
        .map(|t| keccak256_hex(t.as_bytes()))
        .collect::<Vec<_>>();
    let mut fields = vec![];
    for key in order {
        let value = match key {
            "schemaVersion" => {
                if object.get(key).is_some_and(|v| v.as_f64() != Some(1.0)) {
                    return Err(CoreError("INVALID_METADATA_SCHEMA"));
                }
                Some(Value::from(1))
            }
            "topics" => Some(serde_json::json!(topics)),
            _ => object.get(key).cloned(),
        };
        if let Some(v) = value {
            fields.push(format!(
                "{}:{}",
                serde_json::to_string(key).unwrap(),
                serde_json::to_string(&v).map_err(|_| CoreError("INVALID_METADATA"))?
            ));
        }
    }
    let bytes = format!("{{{}}}", fields.join(",")).into_bytes();
    let meta_hash = swarm_reference(&bytes)?;
    parse_metadata(&bytes, &meta_hash, &topic_keys)?;
    Ok(Draft {
        content_hash,
        meta_hash,
        topic_keys,
        bytes,
        changes,
    })
}
pub fn fee(value: &str) -> Result<Uint256> {
    let n = Uint256::decimal(value)?;
    if n.0[..16].iter().any(|b| *b != 0) {
        return Err(CoreError("FEE_OVERFLOW"));
    }
    Ok(n)
}
pub fn encode_approve(moderation: &str, amount: Uint256) -> Result<String> {
    let s = moderation
        .strip_prefix("0x")
        .ok_or(CoreError("INVALID_ADDRESS"))?;
    if s.len() != 40 || !s.bytes().all(|b| b.is_ascii_hexdigit()) || s.bytes().all(|b| b == b'0') {
        return Err(CoreError("INVALID_ADDRESS"));
    }
    fee(&amount.to_decimal())?;
    Ok(format!(
        "{}{:0>64}{}",
        selector("approve(address,uint256)"),
        s,
        amount.abi()
    ))
}
pub fn encode_submit(draft: &Draft, amount: Uint256) -> Result<String> {
    fee(&amount.to_decimal())?;
    parse_metadata(&draft.bytes, &draft.meta_hash, &draft.topic_keys)?;
    encode_submission_parts(
        &draft.content_hash,
        &draft.meta_hash,
        &draft.topic_keys,
        amount,
    )
}
/// Encode an already authenticated public intent, including imported transaction records.
pub fn encode_submission_parts(
    content: &str,
    metadata: &str,
    topics: &[String],
    amount: Uint256,
) -> Result<String> {
    fee(&amount.to_decimal())?;
    if !(1..=5).contains(&topics.len()) {
        return Err(CoreError("INVALID_TOPICS"));
    }
    let mut data = format!(
        "{}{}{}{}{}{}",
        selector("submit(bytes32,bytes32,bytes32[],uint256)"),
        &hash(content)?[2..],
        &hash(metadata)?[2..],
        Uint256::from_u64(128).abi(),
        amount.abi(),
        Uint256::from_u64(topics.len() as u64).abi()
    );
    for (i, key) in topics.iter().enumerate() {
        let key = hash(key)?;
        if topics[..i].iter().any(|k| k.eq_ignore_ascii_case(&key)) {
            return Err(CoreError("DUPLICATE_TOPICS"));
        }
        data.push_str(&key[2..]);
    }
    Ok(data)
}
pub fn claim_key(draft: &Draft) -> Result<String> {
    let mut raw = hex::decode(&hash(&draft.content_hash)?[2..])
        .map_err(|_| CoreError("INVALID_REFERENCE"))?;
    raw.extend(
        hex::decode(&hash(&draft.meta_hash)?[2..]).map_err(|_| CoreError("INVALID_REFERENCE"))?,
    );
    Ok(keccak256_hex(&raw))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn input() -> Value {
        serde_json::json!({"type":"article","title":"Cells","topics":[" Biology  "],"contentType":"text/plain"})
    }
    #[test]
    fn author_order_and_topics() {
        let d = create_draft(&"a".repeat(64), &input()).unwrap();
        assert_eq!(String::from_utf8(d.bytes).unwrap(),"{\"schemaVersion\":1,\"type\":\"article\",\"title\":\"Cells\",\"topics\":[\"biology\"],\"contentType\":\"text/plain\"}");
        assert_eq!(d.changes.len(), 1);
    }
    #[test]
    fn reject_colliding_topics() {
        let mut v = input();
        v["topics"] = serde_json::json!(["biology", " Biology"]);
        assert!(create_draft(&"a".repeat(64), &v).is_err());
    }
    #[test]
    fn exact_fee_width() {
        assert!(fee("340282366920938463463374607431768211456").is_err());
        assert!(fee("340282366920938463463374607431768211455").is_ok());
        assert!(fee("01").is_err());
    }
    #[test]
    fn dynamic_submission_layout() {
        let d = create_draft(&"a".repeat(64), &input()).unwrap();
        let raw = encode_submit(&d, fee("1200").unwrap()).unwrap();
        assert_eq!(&raw[138..202], Uint256::from_u64(128).abi());
        assert_eq!(raw.len(), 10 + 6 * 64);
        assert!(encode_approve(
            "0x0000000000000000000000000000000000000000",
            fee("1").unwrap()
        )
        .is_err());
    }
}
/// Human authoring fields. Empty optional fields are omitted, as in the original publisher form.
#[derive(Clone, Debug, Default)]
pub struct AuthorFields {
    pub entry_type: String,
    pub title: String,
    pub description: String,
    pub topics: Vec<String>,
    pub language: String,
    pub content_type: String,
    pub source: String,
}
impl AuthorFields {
    pub fn field_issues(&self) -> Vec<crate::review::FieldIssue> {
        let topics = self
            .topics
            .iter()
            .map(|s| normalize_topic(s))
            .collect::<Vec<_>>();
        let optional = |s: &String| if s.is_empty() { None } else { Some(s.clone()) };
        let m = crate::review::Metadata {
            schema_version: 1,
            entry_type: self.entry_type.clone(),
            title: self.title.clone(),
            topics: topics.clone(),
            content_type: self.content_type.clone(),
            description: optional(&self.description),
            language: optional(&self.language),
            source: optional(&self.source),
        };
        let mut issues = crate::review::metadata_field_issues(&m);
        if topics
            .iter()
            .any(|t| !(1..=64).contains(&t.chars().count()))
        {
            issues.push(crate::review::FieldIssue {
                field: "topics",
                code: "TOPIC_LENGTH",
            });
        }
        if topics
            .iter()
            .enumerate()
            .any(|(i, t)| topics[..i].contains(t))
        {
            issues.push(crate::review::FieldIssue {
                field: "topics",
                code: "DUPLICATE_TOPICS",
            });
        }
        if self.metadata().is_err() {
            issues.push(crate::review::FieldIssue {
                field: "title",
                code: "METADATA_SIZE",
            });
        }
        issues
    }
    pub fn metadata(&self) -> Result<Value> {
        let total = self.entry_type.len()
            + self.title.len()
            + self.description.len()
            + self.topics.iter().map(String::len).sum::<usize>()
            + self.language.len()
            + self.content_type.len()
            + self.source.len();
        if total > crate::review::MAX_REVIEW_BYTES {
            return Err(CoreError("METADATA_TOO_LARGE"));
        }
        let mut value = serde_json::json!({"schemaVersion":1,"type":self.entry_type,"title":self.title,"topics":self.topics,"contentType":self.content_type});
        for (key, text) in [
            ("description", &self.description),
            ("language", &self.language),
            ("source", &self.source),
        ] {
            if !text.is_empty() {
                value[key] = Value::String(text.clone());
            }
        }
        Ok(value)
    }
}
#[cfg(test)]
mod field_tests {
    use super::*;
    #[test]
    fn authoring_reports_multiple_fields_without_changing_values() {
        let fields = AuthorFields {
            entry_type: "unknown".into(),
            title: "".into(),
            topics: vec![" Biology ".into(), "BIOLOGY".into()],
            language: "English".into(),
            content_type: "Text/Plain".into(),
            ..AuthorFields::default()
        };
        let errors = fields.field_issues();
        for field in ["entrytype", "title", "topics", "language", "contenttype"] {
            assert!(errors.iter().any(|e| e.field == field), "{field}");
        }
        assert_eq!(fields.topics[0], " Biology ");
        assert_eq!(fields.content_type, "Text/Plain");
    }
    #[test]
    fn author_feedback_and_metadata_parser_agree_at_unicode_boundaries() {
        let mut fields = AuthorFields {
            entry_type: "article".into(),
            title: "🧬".repeat(200),
            topics: vec!["biology".into()],
            content_type: "text/plain".into(),
            ..AuthorFields::default()
        };
        assert!(fields.field_issues().is_empty());
        create_draft(&"11".repeat(32), &fields.metadata().unwrap()).unwrap();
        fields.title.push('x');
        assert!(fields.field_issues().iter().any(|e| e.field == "title"));
        assert!(create_draft(&"11".repeat(32), &fields.metadata().unwrap()).is_err());
        fields.title = "Cells".into();
        fields.topics = vec!["é".into(), "e\u{301}".into()];
        assert!(fields
            .field_issues()
            .iter()
            .any(|e| e.code == "DUPLICATE_TOPICS"));
    }
    #[test]
    fn authoring_form_preserves_text_and_omits_empty_optional_fields() {
        let fields = AuthorFields {
            entry_type: "article".into(),
            title: " Cells and DNA ".into(),
            topics: vec![" Biology ".into()],
            content_type: "text/plain".into(),
            description: "Line one\nLine two".into(),
            ..AuthorFields::default()
        };
        let v = fields.metadata().unwrap();
        assert_eq!(v["title"], " Cells and DNA ");
        assert_eq!(v["description"], "Line one\nLine two");
        assert!(v.get("language").is_none());
        assert!(v.get("source").is_none());
        let draft = create_draft(&"aa".repeat(32), &v).unwrap();
        assert_eq!(draft.topic_keys, vec![crate::keccak256_hex(b"biology")]);
        assert!(String::from_utf8(draft.bytes)
            .unwrap()
            .contains("Line one\\nLine two"));
    }
}
