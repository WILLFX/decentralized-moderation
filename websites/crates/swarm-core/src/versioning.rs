//! Explicit version identity. No discovery from an untrusted active address.
use crate::moderator::{CaseInfo, Uint256};
use crate::{ContractPin, CoreError, Deployment, Guidelines, LinkCheck, ModeratorProfile};
use serde::{Deserialize, Serialize};

type Result<T> = std::result::Result<T, CoreError>;
pub const MAX_VERSIONS: usize = 16;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PersistentDeployment {
    pub authority: ContractPin,
    pub versions: Vec<VersionPin>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VersionPin {
    pub moderation: ContractPin,
    pub guidelines: Guidelines,
    pub rules_hash: String,
    pub guidelines_url: String,
}

pub fn version<'a>(d: &'a Deployment, address: &str) -> Result<&'a VersionPin> {
    d.persistent
        .as_ref()
        .and_then(|p| {
            p.versions
                .iter()
                .find(|v| v.moderation.address.eq_ignore_ascii_case(address))
        })
        .ok_or(CoreError("UNKNOWN_CASE_VERSION"))
}

pub(crate) fn validate(d: &Deployment) -> Result<()> {
    let Some(p) = &d.persistent else {
        return Ok(());
    };
    let pin = |p: &ContractPin| {
        crate::fixed_hex(&p.address, 20, true) && crate::fixed_hex(&p.code_hash, 32, true)
    };
    if !pin(&p.authority) || p.versions.is_empty() || p.versions.len() > MAX_VERSIONS {
        return Err(CoreError("INVALID_VERSION_PROFILE"));
    }
    let mut addresses = std::collections::BTreeSet::new();
    for v in &p.versions {
        if !pin(&v.moderation)
            || !crate::fixed_hex(&v.rules_hash, 32, true)
            || !crate::fixed_hex(&v.guidelines.hash, 32, true)
            || v.guidelines.version == 0
            || v.guidelines.version > u32::MAX as u64
            || !addresses.insert(v.moderation.address.to_ascii_lowercase())
            || [
                &p.authority.address,
                &d.stakes.address,
                &d.index.address,
                &d.token.address,
            ]
            .iter()
            .any(|a| a.eq_ignore_ascii_case(&v.moderation.address))
        {
            return Err(CoreError("INVALID_VERSION_PROFILE"));
        }
        if v.guidelines_url != "./MODERATION_GUIDELINES.md" {
            crate::access_url(&v.guidelines_url)?;
        }
    }
    let v = version(d, &d.moderation.address)?;
    if !v
        .moderation
        .code_hash
        .eq_ignore_ascii_case(&d.moderation.code_hash)
        || v.guidelines.version != d.guidelines.version
        || !v.guidelines.hash.eq_ignore_ascii_case(&d.guidelines.hash)
    {
        return Err(CoreError("SELECTED_VERSION_MISMATCH"));
    }
    Ok(())
}

pub fn select(profile: &ModeratorProfile, address: &str) -> Result<ModeratorProfile> {
    let v = version(&profile.deployment, address)?;
    let mut p = profile.clone();
    p.deployment.moderation = v.moderation.clone();
    p.deployment.guidelines = v.guidelines.clone();
    p.guidelines_url = v.guidelines_url.clone();
    Ok(p)
}

pub fn runtime_pins(d: &Deployment) -> Vec<&ContractPin> {
    let mut pins = vec![&d.moderation, &d.stakes, &d.index, &d.token];
    if let Some(p) = &d.persistent {
        pins.push(&p.authority);
    }
    pins
}

pub(crate) fn links(d: &Deployment) -> Vec<LinkCheck> {
    let p = d.persistent.as_ref().expect("persistent deployment");
    [
        (&d.moderation, "stakes()", &d.stakes),
        (&d.moderation, "token()", &d.token),
        (&d.moderation, "index()", &d.index),
        (&d.moderation, "authority()", &p.authority),
        (&d.stakes, "authority()", &p.authority),
        (&d.stakes, "token()", &d.token),
        (&d.index, "authority()", &p.authority),
        (&p.authority, "stakes()", &d.stakes),
        (&p.authority, "index()", &d.index),
        (&p.authority, "token()", &d.token),
    ]
    .into_iter()
    .map(|(from, signature, to)| LinkCheck {
        contract_address: from.address.clone(),
        signature,
        expected_address: to.address.clone(),
    })
    .collect()
}

pub struct WordCheck {
    pub contract: String,
    pub signature: &'static str,
    pub args: String,
    pub expected: String,
}
pub fn word_checks(d: &Deployment) -> Result<Vec<WordCheck>> {
    let Some(p) = &d.persistent else {
        return Ok(vec![]);
    };
    let v = version(d, &d.moderation.address)?;
    let args = address_word(&d.moderation.address)?;
    Ok(vec![
        WordCheck {
            contract: p.authority.address.clone(),
            signature: "codeHashOf(address)",
            args: args.clone(),
            expected: d.moderation.code_hash.clone(),
        },
        WordCheck {
            contract: p.authority.address.clone(),
            signature: "rulesHashOf(address)",
            args,
            expected: v.rules_hash.clone(),
        },
        WordCheck {
            contract: d.moderation.address.clone(),
            signature: "rulesHash()",
            args: String::new(),
            expected: v.rules_hash.clone(),
        },
    ])
}
pub fn verify_word(check: &WordCheck, raw: &str) -> Result<()> {
    crate::word(raw)?;
    if raw.eq_ignore_ascii_case(&check.expected) {
        Ok(())
    } else {
        Err(CoreError("DEPLOYMENT_VERSION_MISMATCH"))
    }
}
pub fn address_word(address: &str) -> Result<String> {
    if !crate::fixed_hex(address, 20, true) {
        return Err(CoreError("INVALID_ADDRESS"));
    }
    Ok(format!("{:0>64}", address[2..].to_ascii_lowercase()))
}
pub fn registration_args(address: &str, id: Uint256) -> Result<String> {
    Ok(format!("{}{}", address_word(address)?, id.abi()))
}
fn words(raw: &str, n: usize) -> Result<Vec<&str>> {
    if raw.len() != 2 + n * 64
        || !raw.starts_with("0x")
        || !raw[2..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    Ok((0..n).map(|i| &raw[2 + 64 * i..2 + 64 * (i + 1)]).collect())
}
pub fn verify_registration(d: &Deployment, c: &CaseInfo, raw: &str) -> Result<Option<String>> {
    let w = words(raw, 4)?;
    let number = |s| crate::decode_uint(&format!("0x{s}"));
    let target = crate::decode_address(&format!("0x{}", w[2]))?;
    let target_id = Uint256::hex(&format!("0x{}", w[3]))?;
    if number(w[0])? != 1 || number(w[1])? != u64::from(matches!(c.phase, 5 | 6)) {
        return Err(CoreError("CASE_VERSION_MISMATCH"));
    }
    match c.action_type {
        0 if target == format!("0x{}", "00".repeat(20))
            && target_id == Uint256::ZERO
            && c.target_case_id == Uint256::ZERO =>
        {
            Ok(None)
        }
        1 if target_id == c.target_case_id && target_id != Uint256::ZERO => {
            version(d, &target)?;
            Ok(Some(target))
        }
        _ => Err(CoreError("CASE_VERSION_MISMATCH")),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Origin {
    pub moderation: String,
    pub case_id: Uint256,
    pub guidelines: Guidelines,
}
pub fn decode_origin(d: &Deployment, raw: &str) -> Result<Origin> {
    let w = words(raw, 4)?;
    let moderation = crate::decode_address(&format!("0x{}", w[0]))?;
    let v = version(d, &moderation)?;
    let id = Uint256::hex(&format!("0x{}", w[1]))?;
    let guidelines = Guidelines {
        version: crate::decode_uint(&format!("0x{}", w[2]))?,
        hash: format!("0x{}", w[3].to_ascii_lowercase()),
    };
    if id == Uint256::ZERO
        || guidelines.version != v.guidelines.version
        || !guidelines.hash.eq_ignore_ascii_case(&v.guidelines.hash)
    {
        return Err(CoreError("ENTRY_VERSION_MISMATCH"));
    }
    Ok(Origin {
        moderation,
        case_id: id,
        guidelines,
    })
}

/// Identity displays must not expose private guideline service URLs from a file.
pub fn identity(d: &Deployment) -> Result<serde_json::Value> {
    let mut value = serde_json::to_value(d).map_err(|_| CoreError("INVALID_DEPLOYMENT"))?;
    if let Some(versions) = value
        .get_mut("persistent")
        .and_then(|f| f.get_mut("versions"))
        .and_then(|v| v.as_array_mut())
    {
        for version in versions {
            if let Some(object) = version.as_object_mut() {
                object.remove("guidelinesUrl");
            }
        }
    }
    Ok(value)
}
