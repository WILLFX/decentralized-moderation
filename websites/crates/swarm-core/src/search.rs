//! Read-only registry discovery. Categories are local query data, not approval authority.
use crate::{
    keccak256_hex,
    moderator::{CaseInfo, Uint256},
    CoreError, ModeratorProfile,
};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;
type Result<T> = std::result::Result<T, CoreError>;
pub const MAX_BINDINGS: usize = 10_000;
pub const MAX_CATEGORY_ROWS: usize = 500;
#[derive(Clone)]
pub struct SearchProfile {
    pub access: ModeratorProfile,
    pub content_gateway: String,
    pub page_size: usize,
    pub scan_size: usize,
}
pub fn parse_profile(text: &str) -> Result<SearchProfile> {
    if text.len() > 65536 {
        return Err(CoreError("CONFIG_TOO_LARGE"));
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Raw {
        deployment: crate::Deployment,
        rpc_url: String,
        gateway_url: String,
        content_gateway_url: Option<String>,
        metadata_path: Option<String>,
        content_path: Option<String>,
        guidelines_url: Option<String>,
        page_size: Option<usize>,
        scan_size: Option<usize>,
    }
    let raw: Raw = serde_json::from_str(text).map_err(|_| CoreError("INVALID_SEARCH_PROFILE"))?;
    let content_gateway = crate::access_url(
        raw.content_gateway_url
            .as_deref()
            .unwrap_or(&raw.gateway_url),
    )?;
    crate::review::resource_url(&content_gateway, "bytes", &format!("0x{}", "01".repeat(32)))?;
    let value = serde_json::json!({"deployment":raw.deployment,"rpcUrl":raw.rpc_url,"gatewayUrl":raw.gateway_url,"metadataPath":raw.metadata_path.unwrap_or("bytes".into()),"contentPath":raw.content_path.unwrap_or("bzz".into()),"guidelinesUrl":raw.guidelines_url.unwrap_or("./MODERATION_GUIDELINES.md".into()),"timing":{"clockErrorSeconds":0,"maxEvidenceAgeSeconds":30,"maxHeadLagSeconds":30,"inclusionBudgetSeconds":120}});
    let access = crate::parse_profile(&value.to_string())?;
    crate::review::resource_url(
        &access.gateway_url,
        "bytes",
        &format!("0x{}", "01".repeat(32)),
    )?;
    let page_size = raw.page_size.unwrap_or(6);
    let scan_size = raw.scan_size.unwrap_or(100);
    if !(1..=20).contains(&page_size) || !(1..=1000).contains(&scan_size) {
        return Err(CoreError("INVALID_SEARCH_LIMIT"));
    }
    Ok(SearchProfile {
        access,
        content_gateway,
        page_size,
        scan_size,
    })
}
fn whitespace(c: char) -> bool {
    c.is_whitespace() && c != '\u{0085}' || c == '\u{feff}'
}
pub fn normalize_topic(input: &str) -> Result<(String, String)> {
    if input.encode_utf16().count() > 4096 {
        return Err(CoreError("INVALID_TOPIC"));
    }
    let lower = input
        .nfc()
        .collect::<String>()
        .to_lowercase()
        .nfc()
        .collect::<String>();
    let normalized = lower
        .split(whitespace)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if !(1..=64).contains(&normalized.chars().count()) {
        return Err(CoreError("INVALID_TOPIC"));
    }
    let key = keccak256_hex(normalized.as_bytes());
    Ok((normalized, key))
}
pub fn pair_hash(a: &str, b: &str) -> Result<String> {
    let a = Uint256::hex(a)?;
    let b = Uint256::hex(b)?;
    Ok(keccak256_hex(&[a.0.as_slice(), b.0.as_slice()].concat()))
}
pub fn increment(mut id: Uint256) -> Result<Uint256> {
    for b in id.0.iter_mut().rev() {
        let (n, carry) = b.overflowing_add(1);
        *b = n;
        if !carry {
            return Ok(id);
        }
    }
    Err(CoreError("INTEGER_OVERFLOW"))
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub case_id: Uint256,
    pub claim: String,
    pub content: String,
    pub metadata: String,
    pub topics: Vec<String>,
}
/// Keep the cap explicit. Returning false leaves all retained bindings unchanged.
/// Callers must retain their staged cursor and mark provenance incomplete.
pub fn retain_binding(bindings: &mut Vec<Binding>, binding: Binding) -> Result<bool> {
    if bindings.len() > MAX_BINDINGS {
        return Err(CoreError("INVALID_SCAN_STATE"));
    }
    if bindings.len() == MAX_BINDINGS {
        return Ok(false);
    }
    bindings.push(binding);
    Ok(true)
}
pub fn candidate(id: Uint256, c: &CaseInfo, topics: Vec<String>) -> Result<Option<Binding>> {
    if c.action_type > 1 || !(1..=5).contains(&c.topic_count) {
        return Err(CoreError("INVALID_CONTRACT_STATE"));
    }
    if c.action_type != 0 {
        return Ok(None);
    }
    if topics.len() != 5
        || topics[c.topic_count as usize..]
            .iter()
            .any(|t| Uint256::hex(t) != Ok(Uint256::ZERO))
        || topics[..c.topic_count as usize]
            .iter()
            .any(|t| Uint256::hex(t) == Ok(Uint256::ZERO))
        || pair_hash(&c.content_hash, &c.meta_hash)? != c.claim_key
    {
        return Err(CoreError("INVALID_CONTRACT_STATE"));
    }
    if c.phase != 5 || c.preliminary != 1 {
        return Ok(None);
    }
    Ok(Some(Binding {
        case_id: id,
        claim: c.claim_key.clone(),
        content: c.content_hash.clone(),
        metadata: c.meta_hash.clone(),
        topics: topics[..c.topic_count as usize].to_vec(),
    }))
}
#[derive(Clone, Debug)]
pub enum Resolution {
    Unresolved,
    Ambiguous,
    Resolved(Binding),
}
pub fn resolve(
    bindings: &[Binding],
    entry: &str,
    topic: &str,
    complete: bool,
) -> Result<Resolution> {
    if !complete {
        return Ok(Resolution::Unresolved);
    }
    let mut unique: Vec<&Binding> = Vec::new();
    for b in bindings {
        if b.topics.iter().any(|t| t == topic)
            && pair_hash(&b.claim, topic)? == entry
            && !unique
                .iter()
                .any(|a| a.content == b.content && a.metadata == b.metadata && a.topics == b.topics)
        {
            unique.push(b)
        }
    }
    Ok(match unique.len() {
        0 => Resolution::Unresolved,
        1 => Resolution::Resolved(unique[0].clone()),
        _ => Resolution::Ambiguous,
    })
}
pub fn decode_page(raw: &str, maximum: usize) -> Result<Vec<String>> {
    let bytes = hex::decode(
        raw.strip_prefix("0x")
            .ok_or(CoreError("INVALID_ABI_RESULT"))?,
    )
    .map_err(|_| CoreError("INVALID_ABI_RESULT"))?;
    if bytes.len() < 64 || bytes.len() > 64 + maximum * 32 {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    let word =
        |i| -> Result<u64> { crate::decode_uint(&format!("0x{}", hex::encode(&bytes[i..i + 32]))) };
    if word(0)? != 32 {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    let n = word(32)? as usize;
    if n > maximum || bytes.len() != 64 + n * 32 {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    let out = bytes[64..]
        .chunks_exact(32)
        .map(|w| format!("0x{}", hex::encode(w)))
        .collect::<Vec<_>>();
    if out.iter().any(|k| Uint256::hex(k) == Ok(Uint256::ZERO))
        || out.iter().collect::<BTreeSet<_>>().len() != out.len()
    {
        return Err(CoreError("INVALID_REGISTRY_PAGE"));
    }
    Ok(out)
}
pub fn verify_entry(raw: &str) -> Result<()> {
    if raw.len() != 450
        || !raw.starts_with("0x")
        || !raw[2..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    let w = (0..7)
        .map(|i| Uint256::hex(&format!("0x{}", &raw[2 + i * 64..2 + (i + 1) * 64])))
        .collect::<Result<Vec<_>>>()?;
    let nums = w.iter().map(|x| x.as_u64()).collect::<Result<Vec<_>>>()?;
    if nums[0] != 1
        || ![1, 2].contains(&nums[1])
        || nums[2] > 1
        || nums[3] > 1
        || nums[4] > u32::MAX as u64
        || nums[5] > u32::MAX as u64
        || nums[6] >= (1 << 40)
    {
        return Err(CoreError("INVALID_REGISTRY_ENTRY"));
    }
    Ok(())
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Category {
    pub id: String,
    pub label: String,
    #[serde(rename = "topicKey")]
    pub topic_key: String,
    pub parents: Vec<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Graph {
    pub schema_version: u8,
    pub categories: Vec<Category>,
}
#[derive(Clone)]
pub struct CategoryPlan {
    pub terms: Vec<Vec<String>>,
    pub topics: Vec<String>,
    pub all: bool,
}
impl Graph {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > 65536 {
            return Err(CoreError("CATEGORY_GRAPH_TOO_LARGE"));
        }
        let g: Self = serde_json::from_slice(bytes.strip_prefix(&[239, 187, 191]).unwrap_or(bytes))
            .map_err(|_| CoreError("INVALID_CATEGORY_GRAPH"))?;
        if g.schema_version != 1 || g.categories.is_empty() || g.categories.len() > 256 {
            return Err(CoreError("INVALID_CATEGORY_GRAPH"));
        }
        let mut ids = BTreeSet::new();
        let mut keys = BTreeSet::new();
        let mut edges = 0;
        for c in &g.categories {
            if !valid_text(&c.id, 128)
                || !valid_text(&c.label, 200)
                || !ids.insert(&c.id)
                || !keys.insert(c.topic_key.to_lowercase())
                || !crate::fixed_hex(&c.topic_key, 32, true)
                || c.parents.len() > 256
                || c.parents.iter().collect::<BTreeSet<_>>().len() != c.parents.len()
            {
                return Err(CoreError("INVALID_CATEGORY_GRAPH"));
            }
            edges += c.parents.len();
        }
        if edges > 1024
            || g.categories
                .iter()
                .any(|c| c.parents.iter().any(|p| !ids.contains(p)))
        {
            return Err(CoreError("INVALID_CATEGORY_GRAPH"));
        }
        fn visit<'a>(id: &'a str, g: &'a Graph, marks: &mut BTreeMap<&'a str, u8>) -> Result<()> {
            match marks.get(id) {
                Some(1) => return Err(CoreError("CATEGORY_CYCLE")),
                Some(2) => return Ok(()),
                _ => {}
            }
            marks.insert(id, 1);
            for p in &g.categories.iter().find(|c| c.id == id).unwrap().parents {
                visit(p, g, marks)?
            }
            marks.insert(id, 2);
            Ok(())
        }
        let mut marks = BTreeMap::new();
        for c in &g.categories {
            visit(&c.id, &g, &mut marks)?
        }
        Ok(g)
    }
    pub fn plan(&self, ids: &[String], expanded: bool, all: bool) -> Result<CategoryPlan> {
        if ids.is_empty() || ids.len() > 5 || ids.iter().collect::<BTreeSet<_>>().len() != ids.len()
        {
            return Err(CoreError("INVALID_CATEGORY_TERMS"));
        }
        let mut terms = Vec::new();
        let mut union = BTreeSet::new();
        for id in ids {
            if !self.categories.iter().any(|c| &c.id == id) {
                return Err(CoreError("UNKNOWN_CATEGORY"));
            }
            let mut seen = BTreeSet::from([id.clone()]);
            if expanded {
                loop {
                    let before = seen.len();
                    for c in &self.categories {
                        if c.parents.iter().any(|p| seen.contains(p)) {
                            seen.insert(c.id.clone());
                        }
                    }
                    if before == seen.len() {
                        break;
                    }
                }
            }
            let keys = self
                .categories
                .iter()
                .filter(|c| seen.contains(&c.id))
                .map(|c| c.topic_key.to_lowercase())
                .collect::<Vec<_>>();
            union.extend(keys.iter().cloned());
            terms.push(keys);
        }
        if union.len() > 16 {
            return Err(CoreError("CATEGORY_QUERY_TOPIC_LIMIT"));
        }
        Ok(CategoryPlan {
            terms,
            topics: union.into_iter().collect(),
            all,
        })
    }
}
fn valid_text(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.chars().count() <= max
        && s.trim() == s
        && !s
            .chars()
            .any(|c| c <= '\u{1f}' || ('\u{7f}'..='\u{9f}').contains(&c))
}
impl CategoryPlan {
    pub fn matches(&self, topics: &[String]) -> bool {
        let hits = self
            .terms
            .iter()
            .map(|term| term.iter().any(|t| topics.contains(t)));
        if self.all {
            hits.fold(true, |a, b| a && b)
        } else {
            hits.fold(false, |a, b| a || b)
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalization_matches_authoring() {
        let (a, k) = normalize_topic("  BIOLOGY\tcell  ").unwrap();
        assert_eq!(a, "biology cell");
        assert_eq!(k, keccak256_hex(b"biology cell"));
        assert!(normalize_topic("").is_err());
    }
    #[test]
    fn page_rejects_duplicate_and_noncanonical_offset() {
        let h = "01".repeat(32);
        let p = format!(
            "0x{}{}{}{}",
            Uint256::from_u64(32).abi(),
            Uint256::from_u64(2).abi(),
            h,
            h
        );
        assert!(decode_page(&p, 20).is_err());
    }
    #[test]
    fn incomplete_provenance_never_resolves() {
        assert!(matches!(
            resolve(&[], "", "", false).unwrap(),
            Resolution::Unresolved
        ));
    }
    #[test]
    fn category_cycle_rejected() {
        let h = format!("0x{}", "01".repeat(32));
        let s=serde_json::json!({"schemaVersion":1,"categories":[{"id":"a","label":"a","topicKey":h,"parents":["a"]}]}).to_string();
        assert_eq!(
            Graph::parse(s.as_bytes()).err().unwrap().0,
            "CATEGORY_CYCLE"
        );
    }
    #[test]
    fn category_parent_query_does_not_create_topic() {
        let a = format!("0x{}", "01".repeat(32));
        let b = format!("0x{}", "02".repeat(32));
        let s=serde_json::json!({"schemaVersion":1,"categories":[{"id":"a","label":"a","topicKey":a,"parents":[]},{"id":"b","label":"b","topicKey":b,"parents":["a"]}]}).to_string();
        let g = Graph::parse(s.as_bytes()).unwrap();
        let p = g.plan(&["a".into()], true, true).unwrap();
        assert_eq!(p.topics.len(), 2);
        assert!(p.matches(&[b]));
        assert_eq!(g.plan(&["a".into()], false, true).unwrap().topics.len(), 1);
    }
}

#[cfg(test)]
mod provenance_tests {
    use super::*;
    fn hash(n: u8) -> String {
        format!("0x{}", format!("{n:02x}").repeat(32))
    }
    fn binding() -> Binding {
        let content = hash(1);
        let metadata = hash(2);
        Binding {
            case_id: Uint256::from_u64(1),
            claim: pair_hash(&content, &metadata).unwrap(),
            content,
            metadata,
            topics: vec![hash(3)],
        }
    }
    #[test]
    fn repeated_compatible_finalizations_do_not_create_ambiguity() {
        let a = binding();
        let mut b = a.clone();
        b.case_id = Uint256::from_u64(2);
        let entry = pair_hash(&a.claim, &hash(3)).unwrap();
        assert!(matches!(
            resolve(&[a, b], &entry, &hash(3), true).unwrap(),
            Resolution::Resolved(_)
        ));
    }
    #[test]
    fn incompatible_topic_binding_is_ambiguous() {
        let a = binding();
        let mut b = a.clone();
        b.topics.push(hash(4));
        let entry = pair_hash(&a.claim, &hash(3)).unwrap();
        assert!(matches!(
            resolve(&[a, b], &entry, &hash(3), true).unwrap(),
            Resolution::Ambiguous
        ));
    }
    #[test]
    fn unrelated_topic_cannot_resolve_entry() {
        let a = binding();
        let entry = pair_hash(&a.claim, &hash(4)).unwrap();
        assert!(matches!(
            resolve(&[a], &entry, &hash(4), true).unwrap(),
            Resolution::Unresolved
        ));
    }
    #[test]
    fn abi_entry_rejects_boolean_padding_and_invalid_status() {
        let mut words = [1u64, 1, 0, 0, 3, 0, 123];
        let encode = |w: &[u64]| {
            format!(
                "0x{}",
                w.iter()
                    .map(|n| Uint256::from_u64(*n).abi())
                    .collect::<String>()
            )
        };
        assert!(verify_entry(&encode(&words)).is_ok());
        words[2] = 2;
        assert!(verify_entry(&encode(&words)).is_err());
        words[2] = 0;
        words[1] = 3;
        assert!(verify_entry(&encode(&words)).is_err());
    }
    #[test]
    fn abi_entry_rejects_non_ascii_without_panic() {
        let s = format!("0x{}é", "0".repeat(446));
        assert!(verify_entry(&s).is_err());
    }
    #[test]
    fn page_bounds_and_zero_hash_are_rejected() {
        let page = format!(
            "0x{}{}{}",
            Uint256::from_u64(32).abi(),
            Uint256::from_u64(1).abi(),
            Uint256::ZERO.abi()
        );
        assert!(decode_page(&page, 6).is_err());
        assert!(decode_page("0x", 6).is_err());
    }
    #[test]
    fn overflow_never_wraps_a_scan_cursor() {
        assert!(increment(Uint256([255; 32])).is_err());
        assert_eq!(increment(Uint256::ZERO).unwrap(), Uint256::from_u64(1));
    }
    #[test]
    fn category_join_all_requires_observed_membership_for_each_term() {
        let p = CategoryPlan {
            terms: vec![vec![hash(1)], vec![hash(2)]],
            topics: vec![hash(1), hash(2)],
            all: true,
        };
        assert!(!p.matches(&[hash(1)]));
        assert!(p.matches(&[hash(1), hash(2)]));
        let mut any = p;
        any.all = false;
        assert!(any.matches(&[hash(1)]));
    }
    #[test]
    fn category_rejects_duplicate_keys() {
        assert!(Graph::parse(br#"{"schemaVersion":1,"schemaVersion":1,"categories":[]}"#).is_err());
    }
}

#[cfg(test)]
mod cap_tests {
    use super::*;
    #[test]
    fn capped_scan_retains_progress_without_becoming_resolved() {
        let hash = |n| format!("0x{}", format!("{n:02x}").repeat(32));
        let b = Binding {
            case_id: Uint256::from_u64(1),
            claim: pair_hash(&hash(1), &hash(2)).unwrap(),
            content: hash(1),
            metadata: hash(2),
            topics: vec![hash(3)],
        };
        let mut bindings = vec![b.clone(); MAX_BINDINGS - 1];
        assert!(retain_binding(&mut bindings, b.clone()).unwrap());
        assert!(!retain_binding(&mut bindings, b.clone()).unwrap());
        assert_eq!(bindings.len(), MAX_BINDINGS);
        let entry = pair_hash(&b.claim, &hash(3)).unwrap();
        assert!(matches!(
            resolve(&bindings, &entry, &hash(3), false).unwrap(),
            Resolution::Unresolved
        ));
        assert!(matches!(
            resolve(&bindings, &entry, &hash(3), true).unwrap(),
            Resolution::Resolved(_)
        ));
    }
}
