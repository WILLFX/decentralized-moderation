//! Canonical ABI and protocol decisions. Network evidence and wallet approval belong to callers.
use crate::{keccak256_hex, selector, CoreError, Timing};
type Result<T> = std::result::Result<T, CoreError>;

/// Full-width unsigned amounts and case IDs. No floating point conversion is used.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct Uint256(pub [u8; 32]);
impl Uint256 {
    pub fn to_decimal(self) -> String {
        if self == Self::ZERO {
            return "0".into();
        }
        let mut bytes = self.0;
        let mut digits = Vec::new();
        while bytes.iter().any(|b| *b != 0) {
            let mut remainder = 0u16;
            for byte in &mut bytes {
                let value = (remainder << 8) + *byte as u16;
                *byte = (value / 10) as u8;
                remainder = value % 10;
            }
            digits.push(b'0' + remainder as u8);
        }
        digits.reverse();
        String::from_utf8(digits).expect("decimal ASCII")
    }
    pub const ZERO: Self = Self([0; 32]);
    pub fn from_u64(n: u64) -> Self {
        let mut b = [0; 32];
        b[24..].copy_from_slice(&n.to_be_bytes());
        Self(b)
    }
    pub fn decimal(s: &str) -> Result<Self> {
        if s.is_empty()
            || (s.len() > 1 && s.starts_with('0'))
            || !s.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(CoreError("INVALID_INPUT"));
        }
        let mut b = [0u8; 32];
        for digit in s.bytes() {
            let mut carry = (digit - b'0') as u16;
            for byte in b.iter_mut().rev() {
                let n = *byte as u16 * 10 + carry;
                *byte = n as u8;
                carry = n >> 8;
            }
            if carry != 0 {
                return Err(CoreError("INVALID_INPUT"));
            }
        }
        Ok(Self(b))
    }
    pub fn hex(s: &str) -> Result<Self> {
        Ok(Self(fixed::<32>(s)?))
    }
    pub fn abi(self) -> String {
        hex::encode(self.0)
    }
    pub fn quantity(self) -> String {
        let s = self.abi();
        format!(
            "0x{}",
            if self == Self::ZERO {
                "0"
            } else {
                s.trim_start_matches('0')
            }
        )
    }
    pub fn as_u64(self) -> Result<u64> {
        if self.0[..24].iter().any(|b| *b != 0) {
            return Err(CoreError("INTEGER_OVERFLOW"));
        }
        Ok(u64::from_be_bytes(self.0[24..].try_into().unwrap()))
    }
}
impl std::fmt::Display for Uint256 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.to_decimal())
    }
}
fn fixed<const N: usize>(s: &str) -> Result<[u8; N]> {
    if !s.starts_with("0x") || s.len() != 2 + N * 2 {
        return Err(CoreError("INVALID_INPUT"));
    }
    let mut b = [0; N];
    hex::decode_to_slice(&s[2..], &mut b).map_err(|_| CoreError("INVALID_INPUT"))?;
    Ok(b)
}
fn address(s: &str) -> Result<String> {
    let b = fixed::<20>(s)?;
    if b.iter().all(|x| *x == 0) {
        return Err(CoreError("INVALID_INPUT"));
    }
    Ok(format!("{}{}", "0".repeat(24), hex::encode(b)))
}
fn hash(s: &str, allow_zero: bool) -> Result<String> {
    let b = fixed::<32>(s)?;
    if !allow_zero && b.iter().all(|x| *x == 0) {
        return Err(CoreError("INVALID_INPUT"));
    }
    Ok(hex::encode(b))
}
fn words(s: &str, n: usize) -> Result<Vec<Uint256>> {
    if s.len() != 2 + n * 64
        || !s.starts_with("0x")
        || !s[2..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    (0..n)
        .map(|i| {
            Uint256::hex(&format!("0x{}", &s[2 + i * 64..2 + (i + 1) * 64]))
                .map_err(|_| CoreError("INVALID_ABI_RESULT"))
        })
        .collect()
}
fn bounded(w: Uint256, bits: u32) -> Result<u64> {
    let n = w.as_u64().map_err(|_| CoreError("INVALID_ABI_RESULT"))?;
    if bits < 64 && n >= (1u64 << bits) {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    Ok(n)
}
fn boolean(w: Uint256) -> Result<bool> {
    match bounded(w, 8)? {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(CoreError("INVALID_ABI_RESULT")),
    }
}
fn bytes32(w: Uint256) -> String {
    format!("0x{}", w.abi())
}
fn nonzero_hash(s: &str) -> bool {
    fixed::<32>(s).is_ok_and(|b| b.iter().any(|v| *v != 0))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaseInfo {
    pub content_hash: String,
    pub meta_hash: String,
    pub claim_key: String,
    pub submitter: String,
    pub topic_count: u8,
    pub action_type: u8,
    pub target_case_id: Uint256,
    pub phase: u8,
    pub challenges: u8,
    pub phase_deadline: u64,
    pub finalized_at: u64,
    pub seed_block_a: u64,
    pub seed_block_b: u64,
    pub outcome_seed_block: u64,
    pub elig_bits: u8,
    pub commits_a: u32,
    pub commits_b: u32,
    pub reveals_a: u32,
    pub reveals_b: u32,
    pub pooled_approve: u32,
    pub pooled_reject: u32,
    pub preliminary: u8,
    pub tickets_approve: u8,
    pub ever_challenged: bool,
    pub pot: Uint256,
}
pub fn decode_case(raw: &str) -> Result<CaseInfo> {
    let w = words(raw, 25)?;
    if w[24].0[..16].iter().any(|b| *b != 0) {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    let c = CaseInfo {
        content_hash: bytes32(w[0]),
        meta_hash: bytes32(w[1]),
        claim_key: bytes32(w[2]),
        submitter: crate::decode_address(&bytes32(w[3]))?,
        topic_count: bounded(w[4], 8)? as u8,
        action_type: bounded(w[5], 8)? as u8,
        target_case_id: w[6],
        phase: bounded(w[7], 8)? as u8,
        challenges: bounded(w[8], 8)? as u8,
        phase_deadline: bounded(w[9], 40)?,
        finalized_at: bounded(w[10], 40)?,
        seed_block_a: bounded(w[11], 40)?,
        seed_block_b: bounded(w[12], 40)?,
        outcome_seed_block: bounded(w[13], 40)?,
        elig_bits: bounded(w[14], 8)? as u8,
        commits_a: bounded(w[15], 32)? as u32,
        commits_b: bounded(w[16], 32)? as u32,
        reveals_a: bounded(w[17], 32)? as u32,
        reveals_b: bounded(w[18], 32)? as u32,
        pooled_approve: bounded(w[19], 32)? as u32,
        pooled_reject: bounded(w[20], 32)? as u32,
        preliminary: bounded(w[21], 8)? as u8,
        tickets_approve: bounded(w[22], 8)? as u8,
        ever_challenged: boolean(w[23])?,
        pot: w[24],
    };
    if !(1..=6).contains(&c.phase) {
        return Err(CoreError("CASE_UNAVAILABLE"));
    }
    Ok(c)
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VoteInfo {
    pub commitment: String,
    pub committee: u8,
    pub round: u8,
    pub revealed: u8,
    pub settled: bool,
}
pub fn decode_vote(raw: &str) -> Result<VoteInfo> {
    let w = words(raw, 5)?;
    Ok(VoteInfo {
        commitment: bytes32(w[0]),
        committee: bounded(w[1], 8)? as u8,
        round: bounded(w[2], 8)? as u8,
        revealed: bounded(w[3], 8)? as u8,
        settled: boolean(w[4])?,
    })
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairSchedule {
    pub deadline_a: u64,
    pub deadline_b: u64,
    pub entropy_b: String,
    pub revised: bool,
}
pub fn decode_schedule(raw: &str) -> Result<PairSchedule> {
    let w = words(raw, 4)?;
    Ok(PairSchedule {
        deadline_a: bounded(w[0], 40)?,
        deadline_b: bounded(w[1], 40)?,
        entropy_b: bytes32(w[2]),
        revised: boolean(w[3])?,
    })
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StakeInfo {
    pub staked: bool,
    pub frozen_until: u64,
    pub open_votes: u32,
    pub total_frozen: Uint256,
}
pub fn decode_stake(raw: &str) -> Result<StakeInfo> {
    let w = words(raw, 4)?;
    if w[3].0[..16].iter().any(|b| *b != 0) {
        return Err(CoreError("INVALID_ABI_RESULT"));
    }
    Ok(StakeInfo {
        staked: boolean(w[0])?,
        frozen_until: bounded(w[1], 40)?,
        open_votes: bounded(w[2], 32)? as u32,
        total_frozen: w[3],
    })
}
pub fn decode_topics(raw: &str) -> Result<Vec<String>> {
    Ok(words(raw, 5)?.into_iter().map(bytes32).collect())
}
pub fn decode_bool(raw: &str) -> Result<bool> {
    boolean(words(raw, 1)?[0])
}

/// Solidity abi.encode (not packed encoding), including chain and contract domain separation.
pub fn make_commitment(
    chain_id: u64,
    moderation: &str,
    case_id: Uint256,
    round: u8,
    voter: &str,
    vote: u8,
    salt: &str,
) -> Result<String> {
    if case_id == Uint256::ZERO || round > 2 || ![1, 2].contains(&vote) {
        return Err(CoreError("INVALID_INPUT"));
    }
    let encoded = format!(
        "{}{}{}{}{}{}{}{}",
        hash(&keccak256_hex(b"commit"), false)?,
        Uint256::from_u64(chain_id).abi(),
        address(moderation)?,
        case_id.abi(),
        Uint256::from_u64(round.into()).abi(),
        address(voter)?,
        Uint256::from_u64(vote.into()).abi(),
        hash(salt, true)?
    );
    Ok(keccak256_hex(
        &hex::decode(encoded).map_err(|_| CoreError("INVALID_INPUT"))?,
    ))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceBlock {
    pub number: u64,
    pub timestamp: u64,
    pub hash: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaseSnapshot {
    pub case_id: Uint256,
    pub source: SourceBlock,
    pub case: CaseInfo,
    pub vote: VoteInfo,
    pub schedule: PairSchedule,
    pub moderator: StakeInfo,
    pub refund_owed: Uint256,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Eligibility {
    Selected,
    NotSelected,
    SeedUnavailable,
    NotOpen,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Commit,
    Reveal,
    Challenge,
    Claim,
    CloseCommitA,
    CloseCommitB,
    CloseReveal,
    Draw,
    CloseChallenge,
    WithdrawRefund,
}
impl Action {
    pub fn signature(self) -> &'static str {
        match self {
            Self::Commit => "commit(uint256,bytes32)",
            Self::Reveal => "reveal(uint256,uint8,bytes32)",
            Self::Challenge => "challenge(uint256)",
            Self::Claim => "claim(uint256,address)",
            Self::CloseCommitA => "closeCommitA(uint256)",
            Self::CloseCommitB => "closeCommitB(uint256)",
            Self::CloseReveal => "closeReveal(uint256)",
            Self::Draw => "draw(uint256)",
            Self::CloseChallenge => "closeChallenge(uint256)",
            Self::WithdrawRefund => "withdrawRefund(uint256)",
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Availability {
    pub action: Action,
    pub allowed: bool,
    pub reason: &'static str,
}
#[derive(Clone, Debug)]
pub struct CaseActions {
    pub committee: Option<u8>,
    pub state: &'static str,
    pub actions: Vec<Availability>,
}
impl CaseActions {
    pub fn allowed(&self, a: Action) -> bool {
        self.actions.iter().any(|v| v.action == a && v.allowed)
    }
}
pub fn committee_at(s: &CaseSnapshot) -> Option<u8> {
    let c = &s.case;
    let now = s.source.timestamp;
    if c.phase == 1 && now < s.schedule.deadline_a {
        Some(1)
    } else if c.phase == 2 && now < s.schedule.deadline_b
        || [1, 2].contains(&c.phase)
            && now < s.schedule.deadline_b
            && !(c.challenges == 0 && c.commits_a == 0)
    {
        Some(2)
    } else {
        None
    }
}
pub fn case_actions(s: &CaseSnapshot, eligibility: Eligibility) -> CaseActions {
    let c = &s.case;
    let v = &s.vote;
    let now = s.source.timestamp;
    let height = s.source.number;
    let committee = committee_at(s);
    let used = nonzero_hash(&v.commitment);
    let active = s.moderator.staked && s.moderator.frozen_until <= now;
    let revision = committee == Some(1)
        && c.commits_a == 2
        && (s.schedule.revised || height >= c.seed_block_b || nonzero_hash(&s.schedule.entropy_b));
    let reason = if used {
        "ALREADY_VOTED"
    } else if !active {
        "STAKE_INACTIVE_OR_FROZEN"
    } else if revision {
        "SCHEDULE_REVISION_UNAVAILABLE"
    } else {
        match eligibility {
            Eligibility::NotOpen => "COMMIT_WINDOW_CLOSED",
            Eligibility::SeedUnavailable => "SeedUnavailable",
            _ => "LOTTERY_RESULT",
        }
    };
    let checks = [
        (
            Action::Commit,
            committee.is_some()
                && active
                && !used
                && !revision
                && eligibility == Eligibility::Selected,
            reason,
        ),
        (
            Action::Reveal,
            c.phase == 3
                && now < c.phase_deadline
                && used
                && v.round == c.challenges
                && v.revealed == 0,
            "NO_CURRENT_UNREVEALED_VOTE_OR_WINDOW_CLOSED",
        ),
        (
            Action::Challenge,
            c.phase == 4 && now < c.phase_deadline && c.challenges < 2 && active && !used,
            "CHALLENGE_UNAVAILABLE",
        ),
        (
            Action::Claim,
            [5, 6].contains(&c.phase) && used && !v.settled,
            "NO_UNSETTLED_FINAL_VOTE",
        ),
        (
            Action::CloseCommitA,
            c.phase == 1 && now >= c.phase_deadline,
            "A_NOT_CLOSABLE",
        ),
        (
            Action::CloseCommitB,
            [1, 2].contains(&c.phase) && now >= s.schedule.deadline_b,
            "B_NOT_CLOSABLE",
        ),
        (
            Action::CloseReveal,
            c.phase == 3 && now >= c.phase_deadline && c.outcome_seed_block == 0,
            "REVEAL_NOT_CLOSABLE",
        ),
        (
            Action::Draw,
            c.phase == 3
                && c.outcome_seed_block != 0
                && height > c.outcome_seed_block
                && height.saturating_sub(c.outcome_seed_block) <= 250,
            "OUTCOME_NOT_DRAWABLE",
        ),
        (
            Action::CloseChallenge,
            c.phase == 4 && now >= c.phase_deadline,
            "CHALLENGE_NOT_CLOSABLE",
        ),
        (
            Action::WithdrawRefund,
            s.refund_owed > Uint256::ZERO,
            "NO_REFUND",
        ),
    ];
    let state = match c.phase {
        1 | 2 => match committee {
            Some(1) => "COMMIT_A",
            Some(2) => "COMMIT_B",
            _ => "COMMIT_PAIR_CLOSED",
        },
        3 => {
            if c.outcome_seed_block != 0 {
                if height.saturating_sub(c.outcome_seed_block) > 250 {
                    "OUTCOME_EXPIRED"
                } else {
                    "OUTCOME_PENDING"
                }
            } else if now >= c.phase_deadline {
                "REVEAL_CLOSED"
            } else {
                "REVEAL"
            }
        }
        4 => {
            if now >= c.phase_deadline {
                "CHALLENGE_CLOSED"
            } else {
                "CHALLENGE"
            }
        }
        5 => "FINALIZED",
        6 => "UNRESOLVED",
        _ => "NONE",
    };
    CaseActions {
        committee,
        state,
        actions: checks
            .into_iter()
            .map(|(action, allowed, reason)| Availability {
                action,
                allowed,
                reason: if allowed {
                    "AVAILABLE_AT_SOURCE_BLOCK"
                } else {
                    reason
                },
            })
            .collect(),
    }
}

/// Calldata only. Callers must refresh evidence and check availability before wallet submission.
pub fn encode_action(action: Action, case_id: Uint256, extra: &[String]) -> Result<String> {
    if case_id == Uint256::ZERO {
        return Err(CoreError("INVALID_INPUT"));
    }
    let args = match action {
        Action::Commit if extra.len() == 1 => hash(&extra[0], false)?,
        Action::Reveal if extra.len() == 2 => {
            let v = Uint256::decimal(&extra[0])?;
            if ![Uint256::from_u64(1), Uint256::from_u64(2)].contains(&v) {
                return Err(CoreError("INVALID_INPUT"));
            }
            format!("{}{}", v.abi(), hash(&extra[1], true)?)
        }
        Action::Claim if extra.len() == 1 => address(&extra[0])?,
        Action::Commit | Action::Reveal | Action::Claim => return Err(CoreError("INVALID_INPUT")),
        _ if extra.is_empty() => String::new(),
        _ => return Err(CoreError("INVALID_INPUT")),
    };
    Ok(format!(
        "{}{}{}",
        selector(action.signature()),
        case_id.abi(),
        args
    ))
}

/// Bound transaction intent, checked against a newly read snapshot before encoding.
pub struct ActionInput<'a> {
    pub action: Action,
    pub case_id: Uint256,
    pub voter: &'a str,
    pub beneficiary: Option<&'a str>,
    pub expected_round: Option<u8>,
    pub expected_committee: Option<u8>,
    pub expected_outcome: Option<u8>,
    pub commitment: Option<&'a str>,
    pub vote: Option<u8>,
    pub salt: Option<&'a str>,
}
pub fn prepare_action(
    chain_id: u64,
    moderation: &str,
    s: &CaseSnapshot,
    eligibility: Eligibility,
    i: &ActionInput<'_>,
) -> Result<String> {
    address(i.voter)?;
    address(moderation)?;
    if i.case_id != s.case_id {
        return Err(CoreError("CONTEXT_CHANGED_CASE"));
    }
    let actions = case_actions(s, eligibility);
    if !actions.allowed(i.action) {
        return Err(CoreError("ACTION_UNAVAILABLE"));
    }
    if i.expected_round
        .is_some_and(|round| round != s.case.challenges)
        || [Action::Commit, Action::Reveal, Action::Challenge].contains(&i.action)
            && i.expected_round.is_none()
    {
        return Err(CoreError("CONTEXT_CHANGED_ROUND"));
    }
    let extra = match i.action {
        Action::Commit => {
            if i.expected_committee != actions.committee {
                return Err(CoreError("CONTEXT_CHANGED_COMMITTEE"));
            }
            vec![i.commitment.ok_or(CoreError("INVALID_INPUT"))?.to_string()]
        }
        Action::Reveal => {
            let vote = i.vote.ok_or(CoreError("INVALID_INPUT"))?;
            let salt = i.salt.ok_or(CoreError("INVALID_INPUT"))?;
            let commitment = make_commitment(
                chain_id,
                moderation,
                i.case_id,
                i.expected_round.ok_or(CoreError("INVALID_INPUT"))?,
                i.voter,
                vote,
                salt,
            )?;
            if !commitment.eq_ignore_ascii_case(&s.vote.commitment) {
                return Err(CoreError("CONTEXT_CHANGED_COMMITMENT"));
            }
            vec![vote.to_string(), salt.to_string()]
        }
        Action::Challenge => {
            if i.expected_outcome != Some(s.case.preliminary) || i.expected_outcome == Some(0) {
                return Err(CoreError("CONTEXT_CHANGED_OUTCOME"));
            }
            vec![]
        }
        Action::Claim => vec![i.beneficiary.unwrap_or(i.voter).to_string()],
        _ => vec![],
    };
    encode_action(i.action, i.case_id, &extra)
}
/// Static ABI arguments for read calls; addresses use canonical zero padding.
pub fn encode_read(
    signature: &str,
    case_id: Option<Uint256>,
    voter: Option<&str>,
) -> Result<String> {
    let mut out = selector(signature);
    if let Some(id) = case_id {
        out.push_str(&id.abi());
    }
    if let Some(a) = voter {
        out.push_str(&address(a)?);
    }
    Ok(out)
}
#[derive(Debug, PartialEq, Eq)]
pub struct StakingActions {
    pub approve_stake: bool,
    pub stake: bool,
    pub withdraw: bool,
}
pub fn staking_actions(
    m: &StakeInfo,
    now: u64,
    stake_amount: Uint256,
    balance: Uint256,
    allowance: Uint256,
) -> StakingActions {
    StakingActions {
        approve_stake: !m.staked && allowance < stake_amount,
        stake: !m.staked && balance >= stake_amount && allowance >= stake_amount,
        withdraw: m.staked && m.frozen_until <= now && m.open_votes == 0,
    }
}

pub struct GuardInput<'a> {
    pub case_id: Uint256,
    pub voter: &'a str,
    pub commitment: &'a str,
    pub expected_round: u8,
}
#[derive(Debug, PartialEq, Eq)]
pub struct RevealDecision {
    pub ready: bool,
    pub reason: &'static str,
    pub remaining_seconds: Option<i128>,
}
fn hold(reason: &'static str) -> RevealDecision {
    RevealDecision {
        ready: false,
        reason,
        remaining_seconds: None,
    }
}
/// Validate finalized and latest evidence against the real wall clock and measured request duration.
/// The browser must take both clocks itself, recheck immediately before disclosure, and fail on read errors.
pub fn check_reveal(
    f: &CaseSnapshot,
    h: &CaseSnapshot,
    i: &GuardInput<'_>,
    t: &Timing,
    wall_ms: u64,
    elapsed_ms: u64,
) -> RevealDecision {
    if t.max_evidence_age_seconds == 0
        || t.max_head_lag_seconds == 0
        || t.inclusion_budget_seconds == 0
        || [
            t.clock_error_seconds,
            t.max_evidence_age_seconds,
            t.max_head_lag_seconds,
            t.inclusion_budget_seconds,
        ]
        .iter()
        .any(|v| *v > 9_007_199_254_740_991)
    {
        return hold("TIMING_PROFILE_REQUIRED");
    }
    if i.case_id == Uint256::ZERO
        || i.expected_round > 2
        || address(i.voter).is_err()
        || hash(i.commitment, false).is_err()
    {
        return hold("INVALID_INPUT");
    }
    if wall_ms > 9_007_199_254_740_991 {
        return hold("CLOCK_INVALID");
    }
    if elapsed_ms.div_ceil(1000) > t.max_evidence_age_seconds {
        return hold("EVIDENCE_STALE");
    }
    if [f, h]
        .iter()
        .any(|s| fixed::<32>(&s.source.hash).is_err() || hash(&s.vote.commitment, true).is_err())
    {
        return hold("SNAPSHOT_INVALID");
    }
    if f.case_id != i.case_id || h.case_id != i.case_id {
        return hold("CASE_CHANGED");
    }
    let a = &f.case;
    let b = &h.case;
    if !a.content_hash.eq_ignore_ascii_case(&b.content_hash)
        || !a.meta_hash.eq_ignore_ascii_case(&b.meta_hash)
        || !a.claim_key.eq_ignore_ascii_case(&b.claim_key)
        || !a.submitter.eq_ignore_ascii_case(&b.submitter)
        || a.topic_count != b.topic_count
        || a.action_type != b.action_type
        || a.target_case_id != b.target_case_id
    {
        return hold("CASE_CHANGED");
    }
    if a.phase != 3 {
        return hold("FINALIZED_REVEAL_REQUIRED");
    }
    if b.phase != 3 {
        return hold("LATEST_REVEAL_REQUIRED");
    }
    for s in [f, h] {
        if s.case.challenges != i.expected_round || s.vote.round != i.expected_round {
            return hold("ROUND_CHANGED");
        }
        if !s.vote.commitment.eq_ignore_ascii_case(i.commitment) {
            return hold("COMMITMENT_CHANGED");
        }
        if s.vote.revealed != 0 {
            return hold("VOTE_REVEALED");
        }
        if s.vote.settled {
            return hold("VOTE_SETTLED");
        }
        if s.case.outcome_seed_block != 0 {
            return hold("OUTCOME_ARMED");
        }
    }
    if a.phase_deadline != b.phase_deadline {
        return hold("DEADLINE_CHANGED");
    }
    let fs = &f.source;
    let hs = &h.source;
    if fs.number > hs.number
        || fs.timestamp > hs.timestamp
        || fs.number == hs.number
            && (!fs.hash.eq_ignore_ascii_case(&hs.hash) || fs.timestamp != hs.timestamp)
    {
        return hold("NODE_ORDER_INVALID");
    }
    let upper_wall = (wall_ms / 1000) as u128 + t.clock_error_seconds as u128;
    if hs.timestamp as u128 > upper_wall {
        return hold("HEAD_CLOCK_AHEAD");
    }
    if upper_wall - hs.timestamp as u128 > t.max_head_lag_seconds as u128 {
        return hold("HEAD_STALE");
    }
    let remaining = b.phase_deadline as i128 - upper_wall as i128;
    RevealDecision {
        ready: remaining > t.inclusion_budget_seconds as i128,
        reason: if remaining <= 0 {
            "WINDOW_EXPIRED"
        } else if remaining <= t.inclusion_budget_seconds as i128 {
            "INCLUSION_BUDGET"
        } else {
            "FINALIZED_REVEAL_READY"
        },
        remaining_seconds: Some(remaining),
    }
}
