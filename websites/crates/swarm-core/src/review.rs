//! Authentication and structural checks for moderator review documents.
//! A successful result authenticates bytes and topic keys, not content safety.
use crate::{keccak256_hex, CoreError};
use serde::{Deserialize, Deserializer};
use sha3::{Digest, Keccak256};
use unicode_normalization::UnicodeNormalization;

pub const MAX_REVIEW_BYTES: usize = 256 * 1024;
type Result<T> = std::result::Result<T, CoreError>;

fn optional_string<'de, D: Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<String>, D::Error> {
    String::deserialize(d).map(Some)
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Metadata {
    #[serde(deserialize_with = "schema_version")]
    pub schema_version: u8,
    #[serde(rename = "type")]
    pub entry_type: String,
    pub title: String,
    pub topics: Vec<String>,
    pub content_type: String,
    #[serde(default, deserialize_with = "optional_string")]
    pub description: Option<String>,
    #[serde(default, deserialize_with = "optional_string")]
    pub language: Option<String>,
    #[serde(default, deserialize_with = "optional_string")]
    pub source: Option<String>,
}

/// Raw unencrypted Swarm BMT reference. At this size one parent level suffices.
pub fn swarm_reference(bytes: &[u8]) -> Result<String> {
    if bytes.len() > MAX_REVIEW_BYTES {
        return Err(CoreError("SWARM_SIZE_LIMIT"));
    }
    fn chunk(payload: &[u8], span: usize) -> [u8; 32] {
        let mut level = vec![0u8; 4096];
        level[..payload.len()].copy_from_slice(payload);
        while level.len() > 32 {
            level = level
                .chunks_exact(64)
                .flat_map(|pair| Keccak256::digest(pair).to_vec())
                .collect();
        }
        let mut addressed = (span as u64).to_le_bytes().to_vec();
        addressed.extend_from_slice(&level);
        Keccak256::digest(addressed).into()
    }
    let digest = if bytes.len() <= 4096 {
        chunk(bytes, bytes.len())
    } else {
        let children: Vec<u8> = bytes
            .chunks(4096)
            .flat_map(|part| chunk(part, part.len()))
            .collect();
        chunk(&children, bytes.len())
    };
    Ok(format!("0x{}", hex::encode(digest)))
}

pub fn verify_reference(bytes: &[u8], expected: &str) -> Result<()> {
    if !crate::fixed_hex(expected, 32, false)
        || !swarm_reference(bytes)?.eq_ignore_ascii_case(expected)
    {
        return Err(CoreError("SWARM_REFERENCE_MISMATCH"));
    }
    Ok(())
}

pub fn verify_guideline_bytes(bytes: &[u8], expected: &str) -> Result<String> {
    if bytes.len() > MAX_REVIEW_BYTES {
        return Err(CoreError("GUIDELINES_TOO_LARGE"));
    }
    if !crate::fixed_hex(expected, 32, false)
        || !keccak256_hex(bytes).eq_ignore_ascii_case(expected)
    {
        return Err(CoreError("GUIDELINES_HASH_MISMATCH"));
    }
    String::from_utf8(without_initial_bom(bytes).to_vec())
        .map_err(|_| CoreError("INVALID_GUIDELINES_UTF8"))
}

// Match TextDecoder("utf-8", { fatal: true }): authenticate original bytes,
// then omit only the initial UTF-8 BOM from the decoded text.
fn without_initial_bom(bytes: &[u8]) -> &[u8] {
    bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes)
}

fn schema_version<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<u8, D::Error> {
    let n = serde_json::Value::deserialize(d)?;
    if n.as_f64() == Some(1.0) {
        Ok(1)
    } else {
        Err(serde::de::Error::custom("schema version must be 1"))
    }
}
fn js_whitespace(c: char) -> bool {
    matches!(c,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}')
}
fn bounded(s: &str, low: usize, high: usize) -> bool {
    (low..=high).contains(&s.chars().count())
}
fn language(s: &str) -> bool {
    let mut pieces = s.split('-');
    let first = pieces.next().unwrap_or("");
    (2..=3).contains(&first.len())
        && first.bytes().all(|b| b.is_ascii_alphabetic())
        && pieces
            .all(|p| (2..=8).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_alphanumeric()))
}
fn mime(s: &str) -> bool {
    let mut parts = s.split(';');
    let mut essence = parts.next().unwrap_or("").split('/');
    // The first character may also be a digit; remaining characters use the v1 allowlist.
    let valid = |part: &str| {
        !part.is_empty()
            && part.len() <= 127
            && (part.as_bytes()[0].is_ascii_lowercase() || part.as_bytes()[0].is_ascii_digit())
            && part
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"!#$&^_.+-".contains(&b))
    };
    if !valid(essence.next().unwrap_or(""))
        || !valid(essence.next().unwrap_or(""))
        || essence.next().is_some()
    {
        return false;
    }
    parts.all(|p| {
        let p = p.trim_start_matches(js_whitespace);
        let Some((key, value)) = p.split_once('=') else {
            return false;
        };
        !key.is_empty() && !value.is_empty() && !p.chars().any(|c| js_whitespace(c) || c == ';')
    })
}

/// Serde's struct decoder rejects duplicate fields, escaped duplicates, unknown
/// fields and invalid UTF-8 before these semantic checks run.
pub fn parse_metadata(
    bytes: &[u8],
    expected_reference: &str,
    topic_keys: &[String],
) -> Result<Metadata> {
    if bytes.len() > MAX_REVIEW_BYTES {
        return Err(CoreError("METADATA_TOO_LARGE"));
    }
    verify_reference(bytes, expected_reference)?;
    let metadata: Metadata = serde_json::from_slice(without_initial_bom(bytes))
        .map_err(|_| CoreError("INVALID_METADATA_JSON"))?;
    if metadata.schema_version != 1
        || ![
            "article", "post", "comment", "image", "video", "audio", "document", "dataset", "other",
        ]
        .contains(&metadata.entry_type.as_str())
        || !bounded(&metadata.title, 1, 200)
        || metadata
            .description
            .as_ref()
            .is_some_and(|s| !bounded(s, 0, 5000))
        || metadata
            .language
            .as_ref()
            .is_some_and(|s| !bounded(s, 0, 35) || !language(s))
        || !bounded(&metadata.content_type, 0, 255)
        || !mime(&metadata.content_type)
        || metadata
            .source
            .as_ref()
            .is_some_and(|s| !bounded(s, 0, 2048))
        || !(1..=5).contains(&topic_keys.len())
        || metadata.topics.len() != topic_keys.len()
    {
        return Err(CoreError("INVALID_METADATA_SCHEMA"));
    }
    for (i, topic) in metadata.topics.iter().enumerate() {
        if !bounded(topic, 1, 64)
            || topic.nfc().collect::<String>() != *topic
            || topic.to_lowercase() != *topic
            || topic.starts_with(' ')
            || topic.ends_with(' ')
            || topic.contains("  ")
            || topic.chars().any(|c| js_whitespace(c) && c != ' ')
            || metadata.topics[..i].contains(topic)
            || !crate::fixed_hex(&topic_keys[i], 32, false)
            || !keccak256_hex(topic.as_bytes()).eq_ignore_ascii_case(&topic_keys[i])
        {
            return Err(CoreError("METADATA_TOPICS_MISMATCH"));
        }
    }
    Ok(metadata)
}

/// Join only raw Swarm paths on a validated gateway. Query strings are rejected
/// because appending a reference to a query would change which resource is read.
pub fn resource_url(base: &str, path: &str, reference: &str) -> Result<String> {
    if !["bytes", "bzz"].contains(&path) || !crate::fixed_hex(reference, 32, true) {
        return Err(CoreError("INVALID_CONTENT_REFERENCE"));
    }
    let safe = crate::access_url(base)?;
    let mut url = url::Url::parse(&safe).map_err(|_| CoreError("INVALID_GATEWAY_URL"))?;
    if url.query().is_some() {
        return Err(CoreError("INVALID_GATEWAY_URL"));
    }
    if !url.path().ends_with('/') {
        url.set_path(&format!("{}/", url.path()));
    }
    url.join(&format!(
        "{}/{}{}",
        path,
        &reference[2..],
        if path == "bzz" { "/" } else { "" }
    ))
    .map(String::from)
    .map_err(|_| CoreError("INVALID_GATEWAY_URL"))
}

pub fn separate_content_url(
    base: &str,
    path: &str,
    reference: &str,
    app_origin: &str,
) -> Result<String> {
    let text = resource_url(base, path, reference)?;
    let url = url::Url::parse(&text).map_err(|_| CoreError("INVALID_GATEWAY_URL"))?;
    if url.origin().ascii_serialization() == app_origin {
        return Err(CoreError("SEPARATE_CONTENT_ORIGIN_REQUIRED"));
    }
    Ok(text)
}
