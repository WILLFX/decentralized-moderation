//! Encrypted vote recovery data. Envelope v1 also carries payload v2 archives.
use crate::CoreError;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
pub const FORMAT: &str = "moderator-vote-vault";
pub const ITERATIONS: u32 = 310_000;
pub const MAX_FILE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_RECORDS: usize = 512;
pub const AAD: &[u8] = b"moderator-vote-vault:1";
pub type Result<T> = std::result::Result<T, CoreError>;
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VoteContext {
    pub chain_id: String,
    pub contract: String,
    pub voter: String,
    pub case_id: String,
    pub round: u8,
    pub committee: u8,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VoteRecord {
    pub chain_id: String,
    pub contract: String,
    pub voter: String,
    pub case_id: String,
    pub round: u8,
    pub committee: u8,
    pub commitment: String,
    pub vote: u8,
    pub salt: String,
}
impl VoteRecord {
    pub fn context(&self) -> VoteContext {
        VoteContext {
            chain_id: self.chain_id.clone(),
            contract: self.contract.clone(),
            voter: self.voter.clone(),
            case_id: self.case_id.clone(),
            round: self.round,
            committee: self.committee,
        }
    }
}
fn decimal(s: &str) -> bool {
    const MAX: &str =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    !s.is_empty()
        && !s.starts_with('0')
        && s.bytes().all(|b| b.is_ascii_digit())
        && (s.len() < MAX.len() || s.len() == MAX.len() && s <= MAX)
}
fn fixed(s: &str, n: usize, nonzero: bool) -> bool {
    s.len() == n * 2 + 2
        && s.as_bytes()
            .get(..2)
            .is_some_and(|p| p.eq_ignore_ascii_case(b"0x"))
        && s[2..].bytes().all(|b| b.is_ascii_hexdigit())
        && (!nonzero || s[2..].bytes().any(|b| b != b'0'))
}
impl VoteContext {
    pub fn normalized(mut self) -> Result<Self> {
        if !decimal(&self.chain_id)
            || !decimal(&self.case_id)
            || !fixed(&self.contract, 20, true)
            || !fixed(&self.voter, 20, true)
            || self.round > 2
            || ![1, 2].contains(&self.committee)
        {
            return Err(CoreError("INVALID_RECORD"));
        }
        self.contract.make_ascii_lowercase();
        self.voter.make_ascii_lowercase();
        Ok(self)
    }
    pub fn identity(&self) -> Result<String> {
        Ok(serde_json::to_string(&self.clone().normalized()?).expect("context serialization"))
    }
}
impl VoteRecord {
    pub fn normalized(mut self) -> Result<Self> {
        let c = self.context().normalized()?;
        if ![1, 2].contains(&self.vote)
            || !fixed(&self.commitment, 32, true)
            || !fixed(&self.salt, 32, false)
        {
            return Err(CoreError("INVALID_RECORD"));
        }
        self.contract = c.contract;
        self.voter = c.voter;
        self.commitment.make_ascii_lowercase();
        self.salt.make_ascii_lowercase();
        Ok(self)
    }
    pub fn json_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("record serialization")
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Payload {
    pub version: u8,
    pub votes: Vec<VoteRecord>,
    pub backed_up: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub archived_votes: Vec<VoteRecord>,
}
impl Payload {
    pub fn empty() -> Self {
        Self {
            version: 1,
            votes: vec![],
            backed_up: vec![],
            archived_votes: vec![],
        }
    }
    pub fn all_votes(&self) -> impl Iterator<Item = &VoteRecord> {
        self.votes.iter().chain(self.archived_votes.iter())
    }
    /// Replace only the exact active record. The caller must also prove it unsent.
    pub fn corrected(&self, original: &VoteRecord, replacement: VoteRecord) -> Result<Self> {
        let replacement = replacement.normalized()?;
        let index = self
            .votes
            .iter()
            .position(|v| v == original)
            .ok_or(CoreError("SECRET_MISMATCH"))?;
        if original.context() != replacement.context()
            || original.vote == replacement.vote
            || original.salt == replacement.salt
            || original.commitment == replacement.commitment
        {
            return Err(CoreError("INVALID_CORRECTION"));
        }
        if self.all_votes().count() >= MAX_RECORDS {
            return Err(CoreError("VAULT_FULL"));
        }
        let mut next = self.clone();
        next.version = 2;
        next.archived_votes.push(original.clone());
        next.votes[index] = replacement;
        Self::parse(&serde_json::to_vec(&next).map_err(|_| CoreError("INVALID_BACKUP"))?)
    }
    pub fn merged(&self, incoming: &Self) -> Result<Self> {
        let mut next = self.clone();
        for v in &incoming.votes {
            // An old file may contain an earlier active choice that is now archived.
            if !next.all_votes().any(|old| old == v) {
                next.votes = merge(&next.votes, &[v.clone()])?;
            }
        }
        for v in &incoming.archived_votes {
            if !next.all_votes().any(|old| old == v) {
                next.archived_votes.push(v.clone());
            }
        }
        if !next.archived_votes.is_empty() {
            next.version = 2;
        }
        Self::parse(&serde_json::to_vec(&next).map_err(|_| CoreError("INVALID_BACKUP"))?)
    }
    pub fn parse(raw: &[u8]) -> Result<Self> {
        let mut p: Self = serde_json::from_slice(raw).map_err(|_| CoreError("INVALID_BACKUP"))?;
        if ![1, 2].contains(&p.version)
            || p.version == 1 && !p.archived_votes.is_empty()
            || p.votes.len() + p.archived_votes.len() > MAX_RECORDS
            || p.backed_up.len() > MAX_RECORDS
        {
            return Err(CoreError("INVALID_BACKUP"));
        }
        p.votes = p
            .votes
            .into_iter()
            .map(VoteRecord::normalized)
            .collect::<Result<_>>()?;
        p.archived_votes = p
            .archived_votes
            .into_iter()
            .map(VoteRecord::normalized)
            .collect::<Result<_>>()?;
        let mut records = HashSet::new();
        for v in p.all_votes() {
            if !records.insert(v.json_bytes()) {
                return Err(CoreError("INVALID_BACKUP"));
            }
        }
        let mut ids = HashSet::new();
        for v in &p.votes {
            if !ids.insert(v.context().identity()?) {
                return Err(CoreError("INVALID_BACKUP"));
            }
        }
        let mut coverage = HashSet::new();
        if p.backed_up.iter().any(|s| {
            s.len() != 64
                || !s
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                || !coverage.insert(s)
        }) {
            return Err(CoreError("INVALID_BACKUP"));
        }
        Ok(p)
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Kdf {
    pub name: String,
    pub hash: String,
    pub iterations: u32,
    pub salt: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Cipher {
    pub name: String,
    pub iv: String,
    pub data: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub format: String,
    pub version: u8,
    pub kdf: Kdf,
    pub cipher: Cipher,
}
fn lower_hex(s: &str, n: Option<usize>) -> bool {
    n.map_or(s.len() >= 32 && s.len() % 2 == 0, |n| s.len() == n * 2)
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
impl Envelope {
    pub fn parse(text: &str) -> Result<Self> {
        if text.len() > MAX_FILE_BYTES {
            return Err(CoreError("INVALID_BACKUP"));
        }
        let e: Self = serde_json::from_str(text).map_err(|_| CoreError("INVALID_BACKUP"))?;
        if e.format != FORMAT
            || e.version != 1
            || e.kdf.name != "PBKDF2"
            || e.kdf.hash != "SHA-256"
            || e.kdf.iterations != ITERATIONS
            || !lower_hex(&e.kdf.salt, Some(16))
            || e.cipher.name != "AES-GCM"
            || !lower_hex(&e.cipher.iv, Some(12))
            || !lower_hex(&e.cipher.data, None)
        {
            return Err(CoreError("INVALID_BACKUP"));
        }
        Ok(e)
    }
}
/// Merge without ever replacing a secret already stored for a voting context.
pub fn merge(existing: &[VoteRecord], incoming: &[VoteRecord]) -> Result<Vec<VoteRecord>> {
    let mut next = existing.to_vec();
    for v in incoming {
        let id = v.context().identity()?;
        if let Some(old) = next
            .iter()
            .find(|o| o.context().identity().ok().as_ref() == Some(&id))
        {
            if old != v {
                return Err(CoreError("VOTE_CONFLICT"));
            }
        } else {
            next.push(v.clone());
        }
    }
    if next.len() > MAX_RECORDS {
        return Err(CoreError("VAULT_FULL"));
    }
    Ok(next)
}
