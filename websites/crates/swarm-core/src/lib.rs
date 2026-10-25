//! Pure profile validation and deployment identity checks shared by the websites.
//! Network and wallet access deliberately live outside this crate.
pub mod review;

use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use std::fmt;
use url::Url;

pub mod moderator;

const MAX_CONFIG_BYTES: usize = 64 * 1024;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// Safe errors never contain endpoint credentials or untrusted provider text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreError(pub &'static str);

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for CoreError {}
type Result<T> = std::result::Result<T, CoreError>;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModeratorProfile {
    pub deployment: Deployment,
    pub rpc_url: String,
    pub gateway_url: String,
    #[serde(default = "metadata_path", deserialize_with = "nullable_metadata_path")]
    pub metadata_path: String,
    #[serde(default = "content_path", deserialize_with = "nullable_content_path")]
    pub content_path: String,
    #[serde(
        default = "guidelines_url",
        deserialize_with = "nullable_guidelines_url"
    )]
    pub guidelines_url: String,
    pub timing: Timing,
    pub display: Option<Display>,
}
fn metadata_path() -> String {
    "bytes".into()
}
fn content_path() -> String {
    "bzz".into()
}
fn guidelines_url() -> String {
    "./MODERATION_GUIDELINES.md".into()
}
fn nullable_metadata_path<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_else(metadata_path))
}
fn nullable_content_path<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_else(content_path))
}
fn nullable_guidelines_url<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_else(guidelines_url))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Deployment {
    #[serde(deserialize_with = "decimal_u64")]
    pub chain_id: u64,
    pub moderation: ContractPin,
    pub stakes: ContractPin,
    pub index: ContractPin,
    pub token: ContractPin,
    pub guidelines: Guidelines,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContractPin {
    pub address: String,
    pub code_hash: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Guidelines {
    pub hash: String,
    #[serde(deserialize_with = "decimal_u64")]
    pub version: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timing {
    pub clock_error_seconds: u64,
    pub max_evidence_age_seconds: u64,
    pub max_head_lag_seconds: u64,
    pub inclusion_budget_seconds: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Display {
    pub decimals: u8,
    pub symbol: String,
}

fn decimal_u64<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<u64, D::Error> {
    let value = serde_json::Value::deserialize(d)?;
    match value {
        serde_json::Value::Number(n) => n.as_u64(),
        serde_json::Value::String(s)
            if !s.is_empty()
                && (s == "0" || !s.starts_with('0'))
                && s.bytes().all(|b| b.is_ascii_digit()) =>
        {
            s.parse().ok()
        }
        _ => None,
    }
    .ok_or_else(|| serde::de::Error::custom("expected unsigned decimal integer"))
}

/// Accept HTTPS, or HTTP on localhost/IPv4/IPv6 loopback; reject credentials/fragments.
pub fn access_url(value: &str) -> Result<String> {
    let url = Url::parse(value).map_err(|_| CoreError("INVALID_ACCESS_URL"))?;
    let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if !(url.scheme() == "https" || url.scheme() == "http" && loopback)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.host_str().is_none()
    {
        return Err(CoreError("INVALID_ACCESS_URL"));
    }
    Ok(url.into())
}

fn fixed_hex(value: &str, bytes: usize, nonzero: bool) -> bool {
    value.len() == bytes * 2 + 2
        && value.starts_with("0x")
        && value[2..].bytes().all(|b| b.is_ascii_hexdigit())
        && (!nonzero || value[2..].bytes().any(|b| b != b'0'))
}

/// Parse the existing JSON profile without accepting unsafe access endpoints.
pub fn parse_profile(text: &str) -> Result<ModeratorProfile> {
    if text.len() > MAX_CONFIG_BYTES {
        return Err(CoreError("CONFIG_TOO_LARGE"));
    }
    let mut profile: ModeratorProfile =
        serde_json::from_str(text).map_err(|_| CoreError("INVALID_CONFIG_JSON"))?;
    let d = &profile.deployment;
    if ![100, 10200].contains(&d.chain_id)
        || [&d.moderation, &d.stakes, &d.index, &d.token]
            .iter()
            .any(|p| !fixed_hex(&p.address, 20, true) || !fixed_hex(&p.code_hash, 32, true))
        || !fixed_hex(&d.guidelines.hash, 32, true)
        || d.guidelines.version == 0
    {
        return Err(CoreError("INVALID_DEPLOYMENT"));
    }
    profile.rpc_url = access_url(&profile.rpc_url)?;
    profile.gateway_url = access_url(&profile.gateway_url)?;
    if ![&profile.metadata_path, &profile.content_path]
        .iter()
        .all(|p| ["bytes", "bzz"].contains(&p.as_str()))
    {
        return Err(CoreError("INVALID_SWARM_PATH"));
    }
    if profile.guidelines_url != guidelines_url() {
        profile.guidelines_url = access_url(&profile.guidelines_url)?;
    }
    let t = &profile.timing;
    if t.clock_error_seconds > MAX_SAFE_INTEGER
        || [
            t.max_evidence_age_seconds,
            t.max_head_lag_seconds,
            t.inclusion_budget_seconds,
        ]
        .iter()
        .any(|n| *n == 0 || *n > MAX_SAFE_INTEGER)
    {
        return Err(CoreError("TIMING_PROFILE_REQUIRED"));
    }
    if let Some(display) = &profile.display {
        if display.decimals > 36
            || display.symbol.is_empty()
            || display.symbol.len() > 16
            || !display
                .symbol
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b" _-".contains(&b))
        {
            return Err(CoreError("INVALID_TOKEN_DISPLAY"));
        }
    }
    Ok(profile)
}

pub fn keccak256_hex(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(Keccak256::digest(bytes)))
}
pub fn selector(signature: &str) -> String {
    keccak256_hex(signature.as_bytes())[..10].into()
}

fn word(raw: &str) -> Result<Vec<u8>> {
    if !fixed_hex(raw, 32, false) {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    hex::decode(&raw[2..]).map_err(|_| CoreError("INVALID_ABI_RESULT"))
}
/// Decode one canonical ABI address word. Padding must be zero.
pub fn decode_address(raw: &str) -> Result<String> {
    let bytes = word(raw)?;
    if bytes[..12].iter().any(|b| *b != 0) {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    Ok(format!("0x{}", hex::encode(&bytes[12..])))
}
/// Decode a canonical uint256 word into a bounded integer; reject overflow.
pub fn decode_uint(raw: &str) -> Result<u64> {
    let bytes = word(raw)?;
    if bytes[..24].iter().any(|b| *b != 0) {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    Ok(u64::from_be_bytes(
        bytes[24..].try_into().expect("eight-byte slice"),
    ))
}
pub fn verify_runtime(pin: &ContractPin, code: &str) -> Result<()> {
    let bytes = code
        .strip_prefix("0x")
        .and_then(|s| hex::decode(s).ok())
        .filter(|b| !b.is_empty())
        .ok_or(CoreError("DEPLOYMENT_MISMATCH_RUNTIME"))?;
    if !keccak256_hex(&bytes).eq_ignore_ascii_case(&pin.code_hash) {
        return Err(CoreError("DEPLOYMENT_MISMATCH_RUNTIME"));
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct LinkCheck {
    pub contract_address: String,
    pub signature: &'static str,
    pub expected_address: String,
}
/// The six reciprocal links used by the existing moderator adapter.
pub fn link_checks(d: &Deployment) -> Vec<LinkCheck> {
    [
        (&d.moderation, "stakes()", &d.stakes),
        (&d.moderation, "token()", &d.token),
        (&d.moderation, "index()", &d.index),
        (&d.stakes, "moderation()", &d.moderation),
        (&d.stakes, "token()", &d.token),
        (&d.index, "moderation()", &d.moderation),
    ]
    .into_iter()
    .map(|(from, signature, to)| LinkCheck {
        contract_address: from.address.clone(),
        signature,
        expected_address: to.address.clone(),
    })
    .collect()
}
pub fn verify_link(check: &LinkCheck, raw: &str) -> Result<()> {
    if !decode_address(raw)?.eq_ignore_ascii_case(&check.expected_address) {
        return Err(CoreError("DEPLOYMENT_MISMATCH_LINK"));
    }
    Ok(())
}
/// Arguments are the raw ABI results of guidelinesVersion() and guidelinesHash().
pub fn verify_guidelines(d: &Deployment, version: &str, hash: &str) -> Result<()> {
    word(hash)?;
    if decode_uint(version)? != d.guidelines.version
        || !hash.eq_ignore_ascii_case(&d.guidelines.hash)
    {
        return Err(CoreError("DEPLOYMENT_MISMATCH_GUIDELINES"));
    }
    Ok(())
}

pub mod recovery;

pub mod publisher;

pub mod search;
