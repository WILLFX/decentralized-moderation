//! Transaction coordination. Every entry is an explicit UI operation. Public
//! transaction history omits calldata, vote choices, salts and recovery data.
use crate::{
    evidence::{self, CaseEvidence},
    transport::rpc,
    vault::{random_bytes, VoteVault},
    wallet, BrowserResult as Result,
};
use js_sys::Date;
use serde_json::{json, Value};
use std::rc::Rc;
use swarm_core::{moderator::*, recovery::VoteRecord, ModeratorProfile};

pub(crate) struct Session {
    pub profile: ModeratorProfile,
    pub voter: String,
    pub vault: VoteVault,
    pub active: Rc<dyn Fn() -> bool>,
    pub request_boundary: Option<(u64, u64)>,
}
pub(crate) struct Broadcast {
    pub hash: String,
    pub warning: Option<&'static str>,
}
/// Read-only observation for presentation. Sending never consumes this report.
pub(crate) struct RevealReport {
    pub ready: bool,
    pub reason: &'static str,
    pub remaining_seconds: Option<i128>,
    pub checked_wall_ms: u64,
    pub elapsed_ms: u64,
    pub finalized: SourceBlock,
    pub latest: SourceBlock,
    pub deadline: u64,
    pub budget: u64,
    pub clock_error: u64,
}
impl Session {
    pub fn current(&self) -> Result<()> {
        if (self.active)() {
            Ok(())
        } else {
            Err("CONTEXT_CHANGED")
        }
    }
    pub async fn read(&self, id: Uint256, tag: &str) -> Result<CaseEvidence> {
        self.current()?;
        let e = evidence::read_case(&self.profile, &self.voter, id, tag).await?;
        self.current()?;
        Ok(e)
    }
    fn record(&self, v: &VoteRecord) -> Result<Uint256> {
        let value = v.clone().normalized().map_err(|e| e.0)?;
        if value.chain_id != self.profile.deployment.chain_id.to_string()
            || !value
                .contract
                .eq_ignore_ascii_case(&self.profile.deployment.moderation.address)
            || !value.voter.eq_ignore_ascii_case(&self.voter)
        {
            return Err("CONTEXT_CHANGED");
        }
        let id = Uint256::decimal(&value.case_id).map_err(|e| e.0)?;
        let computed = make_commitment(
            self.profile.deployment.chain_id,
            &value.contract,
            id,
            value.round,
            &value.voter,
            value.vote,
            &value.salt,
        )
        .map_err(|e| e.0)?;
        if computed != value.commitment {
            return Err("SECRET_MISMATCH");
        }
        Ok(id)
    }
    fn stored(&self, v: &VoteRecord, backup: bool) -> Result<()> {
        self.current()?;
        self.record(v)?;
        if if backup {
            self.vault.get_vote(&v.context())?.as_ref() != Some(v)
        } else {
            !self.vault.list_votes()?.contains(v)
        } {
            return Err("SECRET_MISMATCH");
        }
        if backup && !self.vault.is_backed_up(&v.context())? {
            return Err("BACKUP_REQUIRED");
        }
        Ok(())
    }
    pub async fn draft(&self, id: Uint256, vote: u8) -> Result<VoteRecord> {
        self.save_choice(id, vote, None).await
    }
    pub async fn change_choice(&self, original: &VoteRecord, vote: u8) -> Result<VoteRecord> {
        let id = self.record(original)?;
        self.save_choice(id, vote, Some(original)).await
    }
    async fn save_choice(
        &self,
        id: Uint256,
        vote: u8,
        original: Option<&VoteRecord>,
    ) -> Result<VoteRecord> {
        crate::moderator_requests::ensure_clear(&self.profile, &self.voter)?;
        if !self.vault.is_unlocked() {
            return Err("VAULT_LOCKED");
        }
        if ![1, 2].contains(&vote) {
            return Err("INVALID_VOTE");
        }
        let e = self.read(id, "latest").await?;
        let actions = case_actions(&e.snapshot, e.eligibility);
        if !actions.allowed(Action::Commit) {
            return Err("ACTION_UNAVAILABLE");
        }
        let committee = actions.committee.ok_or("COMMIT_WINDOW_CLOSED")?;
        let context = swarm_core::recovery::VoteContext {
            chain_id: self.profile.deployment.chain_id.to_string(),
            contract: self
                .profile
                .deployment
                .moderation
                .address
                .to_ascii_lowercase(),
            voter: self.voter.clone(),
            case_id: id.to_decimal(),
            round: e.snapshot.case.challenges,
            committee,
        };
        if let Some(original) = original {
            if original.context() != context || !self.vault.can_correct(original) {
                return Err("CHOICE_PROTECTED");
            }
        } else if let Some(v) = self.vault.get_vote(&context)? {
            self.record(&v)?;
            if v.vote != vote {
                return Err("VOTE_CONFLICT");
            }
            return Ok(v);
        }
        let mut bytes = random_bytes(32)?;
        let salt = format!("0x{}", hex::encode(&bytes));
        bytes.fill(0);
        let commitment = make_commitment(
            self.profile.deployment.chain_id,
            &context.contract,
            id,
            context.round,
            &self.voter,
            vote,
            &salt,
        )
        .map_err(|e| e.0)?;
        let v = VoteRecord {
            chain_id: context.chain_id,
            contract: context.contract,
            voter: context.voter,
            case_id: context.case_id,
            round: context.round,
            committee,
            commitment,
            vote,
            salt,
        };
        self.current()?;
        crate::moderator_requests::ensure_clear(&self.profile, &self.voter)?;
        let saved = if let Some(original) = original {
            self.vault.correct_vote(original, v).await?
        } else {
            self.vault.save_vote(v).await?
        };
        self.current()?;
        Ok(saved)
    }
    pub fn saved_for(&self, e: &CaseEvidence) -> Result<VoteRecord> {
        self.current()?;
        let s = &e.snapshot;
        let context = swarm_core::recovery::VoteContext {
            chain_id: self.profile.deployment.chain_id.to_string(),
            contract: self.profile.deployment.moderation.address.clone(),
            voter: self.voter.clone(),
            case_id: s.case_id.to_decimal(),
            round: s.case.challenges,
            committee: s.vote.committee,
        };
        let record = crate::saved_vote::matching_record(
            &context,
            &s.vote.commitment,
            &self.vault.list_votes()?,
        )?;
        self.record(&record)?;
        Ok(record)
    }
    async fn reveal_ready(&self, v: &VoteRecord) -> Result<()> {
        let id = self.record(v)?;
        let clock = web_sys::window()
            .ok_or("CLOCK_INVALID")?
            .performance()
            .ok_or("CLOCK_INVALID")?;
        let start = clock.now();
        let finalized = self.read(id, "finalized").await?;
        let latest = self.read(id, "latest").await?;
        let end = clock.now();
        let wall = Date::now();
        if !start.is_finite()
            || !end.is_finite()
            || end < start
            || !wall.is_finite()
            || wall < 0.0
            || wall > 9_007_199_254_740_991.0
            || end - start > 9_007_199_254_740_991.0
        {
            return Err("CLOCK_INVALID");
        }
        let input = GuardInput {
            case_id: id,
            voter: &self.voter,
            commitment: &v.commitment,
            expected_round: v.round,
        };
        let guard = check_reveal(
            &finalized.snapshot,
            &latest.snapshot,
            &input,
            &self.profile.timing,
            wall.floor() as u64,
            (end - start).ceil() as u64,
        );
        if !guard.ready {
            return Err(guard.reason);
        }
        self.current()
    }
    /// Advisory read only. Sending a reveal still repeats the full guard.
    pub async fn check_reveal(&self, id: Uint256) -> Result<RevealReport> {
        let evidence = self.read(id, "latest").await?;
        let record = self.saved_for(&evidence)?;
        self.stored(&record, false)?;
        // Collect display evidence separately: the disclosure guard above stays unchanged.
        let clock = web_sys::window()
            .ok_or("CLOCK_INVALID")?
            .performance()
            .ok_or("CLOCK_INVALID")?;
        let start = clock.now();
        let finalized = self.read(id, "finalized").await?;
        let latest = self.read(id, "latest").await?;
        let end = clock.now();
        let wall = Date::now();
        if !start.is_finite()
            || !end.is_finite()
            || end < start
            || !wall.is_finite()
            || wall < 0.0
            || wall > 9_007_199_254_740_991.0
            || end - start > 9_007_199_254_740_991.0
        {
            return Err("CLOCK_INVALID");
        }
        let input = GuardInput {
            case_id: id,
            voter: &self.voter,
            commitment: &record.commitment,
            expected_round: record.round,
        };
        let wall_ms = wall.floor() as u64;
        let elapsed_ms = (end - start).ceil() as u64;
        let decision = check_reveal(
            &finalized.snapshot,
            &latest.snapshot,
            &input,
            &self.profile.timing,
            wall_ms,
            elapsed_ms,
        );
        self.current()?;
        Ok(RevealReport {
            ready: decision.ready,
            reason: decision.reason,
            remaining_seconds: decision.remaining_seconds,
            checked_wall_ms: wall_ms,
            elapsed_ms,
            finalized: finalized.snapshot.source,
            latest: latest.snapshot.source,
            deadline: latest.snapshot.case.phase_deadline,
            budget: self.profile.timing.inclusion_budget_seconds,
            clock_error: self.profile.timing.clock_error_seconds,
        })
    }
    pub async fn commit(&self, v: &VoteRecord) -> Result<Broadcast> {
        self.stored(v, true)?;
        // Consume before any attempt. Rejection or absent chain state cannot restore it.
        self.vault.seal_choice(v);
        let id = self.record(v)?;
        let e = self.read(id, "latest").await?;
        let input = ActionInput {
            action: Action::Commit,
            case_id: id,
            voter: &self.voter,
            beneficiary: None,
            expected_round: Some(v.round),
            expected_committee: Some(v.committee),
            expected_outcome: None,
            commitment: Some(&v.commitment),
            vote: None,
            salt: None,
        };
        let data = prepare_action(
            self.profile.deployment.chain_id,
            &self.profile.deployment.moderation.address,
            &e.snapshot,
            e.eligibility,
            &input,
        )
        .map_err(|e| e.0)?;
        wallet::check(self.profile.deployment.chain_id, &self.voter).await?;
        self.stored(v, true)?;
        self.broadcast(
            &self.profile.deployment.moderation.address,
            &data,
            "commit",
            Some(id),
        )
        .await
    }
    pub async fn reveal(&self, id: Uint256) -> Result<Broadcast> {
        let e = self.read(id, "latest").await?;
        let v = self.saved_for(&e)?;
        self.stored(&v, false)?;
        self.vault.seal_choice(&v);
        // Strong guard first, then intent preparation, then a SECOND guard after
        // wallet reads and immediately before disclosing calldata to the wallet.
        self.reveal_ready(&v).await?;
        let current = self.read(id, "latest").await?;
        let input = ActionInput {
            action: Action::Reveal,
            case_id: id,
            voter: &self.voter,
            beneficiary: None,
            expected_round: Some(v.round),
            expected_committee: None,
            expected_outcome: None,
            commitment: None,
            vote: Some(v.vote),
            salt: Some(&v.salt),
        };
        let data = prepare_action(
            self.profile.deployment.chain_id,
            &self.profile.deployment.moderation.address,
            &current.snapshot,
            current.eligibility,
            &input,
        )
        .map_err(|e| e.0)?;
        wallet::check(self.profile.deployment.chain_id, &self.voter).await?;
        self.stored(&v, false)?;
        // Complete durable IO BEFORE the final guard. Even synchronous storage
        // can stall long enough to consume the disclosure budget.
        let request = self.reserve(
            &self.profile.deployment.moderation.address,
            &data,
            "reveal",
            Some(id),
        )?;
        if let Err(error) = self
            .reveal_ready(&v)
            .await
            .and_then(|()| self.stored(&v, false))
        {
            crate::moderator_requests::not_sent(&self.profile, &self.voter, request)?;
            return Err(error);
        }
        self.broadcast_reserved(
            &self.profile.deployment.moderation.address,
            &data,
            "reveal",
            Some(id),
            request,
        )
        .await
    }

    pub async fn action(
        &self,
        id: Uint256,
        action: Action,
        round: u8,
        outcome: u8,
    ) -> Result<Broadcast> {
        if [Action::Commit, Action::Reveal].contains(&action) {
            return Err("EXPLICIT_VOTE_FLOW_REQUIRED");
        }
        let e = self.read(id, "latest").await?;
        if action == Action::Challenge && !e.challenge_bound {
            return Err("CHALLENGE_INTENT_UNSUPPORTED");
        }
        if [Action::Draw, Action::CacheOutcome].contains(&action) {
            if let Some(reason) = crate::moderator_view::draw_request_hold(&e.snapshot) {
                return Err(reason);
            }
        }
        let input = ActionInput {
            action,
            case_id: id,
            voter: &self.voter,
            beneficiary: Some(&self.voter),
            expected_round: Some(round),
            expected_committee: None,
            expected_outcome: Some(outcome),
            commitment: None,
            vote: None,
            salt: None,
        };
        let data = prepare_action(
            self.profile.deployment.chain_id,
            &self.profile.deployment.moderation.address,
            &e.snapshot,
            e.eligibility,
            &input,
        )
        .map_err(|e| e.0)?;
        wallet::check(self.profile.deployment.chain_id, &self.voter).await?;
        self.current()?;
        self.broadcast(
            &self.profile.deployment.moderation.address,
            &data,
            action.signature(),
            Some(id),
        )
        .await
    }
    pub async fn stake_action(&self, action: &str) -> Result<Broadcast> {
        self.current()?;
        let e = evidence::read_moderator(&self.profile, &self.voter).await?;
        self.current()?;
        let a = staking_actions(
            &e.moderator,
            e.source.timestamp,
            e.funds.stake_amount,
            e.funds.balance,
            e.funds.allowance,
        );
        let d = &self.profile.deployment;
        let (to, data) = match action {
            "approveStake" if a.approve_stake => (
                d.token.address.clone(),
                format!(
                    "{}{:0>64}{}",
                    swarm_core::selector("approve(address,uint256)"),
                    &d.stakes.address[2..],
                    e.funds.stake_amount.abi()
                ),
            ),
            "stake" if a.stake => (d.stakes.address.clone(), swarm_core::selector("stake()")),
            "withdraw" if a.withdraw => {
                (d.stakes.address.clone(), swarm_core::selector("withdraw()"))
            }
            _ => return Err("ACTION_UNAVAILABLE"),
        };
        wallet::check(d.chain_id, &self.voter).await?;
        self.current()?;
        self.broadcast(&to, &data, action, None).await
    }
    fn reserve(&self, to: &str, data: &str, action: &str, id: Option<Uint256>) -> Result<usize> {
        self.current()?;
        crate::moderator_requests::begin(
            &self.profile,
            &self.voter,
            to,
            data,
            action,
            id.map(|v| v.to_decimal()),
            self.request_boundary.ok_or("REQUEST_BOUNDARY_REQUIRED")?,
        )
    }
    async fn broadcast(
        &self,
        to: &str,
        data: &str,
        action: &str,
        id: Option<Uint256>,
    ) -> Result<Broadcast> {
        let request = self.reserve(to, data, action, id)?;
        self.broadcast_reserved(to, data, action, id, request).await
    }
    async fn broadcast_reserved(
        &self,
        to: &str,
        data: &str,
        action: &str,
        id: Option<Uint256>,
        request: usize,
    ) -> Result<Broadcast> {
        if let Err(error) = self.current() {
            crate::moderator_requests::not_sent(&self.profile, &self.voter, request)?;
            return Err(error);
        }
        // Success path: no journal IO, RPC read or timer before wallet disclosure.
        let boundary = self.request_boundary.ok_or("REQUEST_BOUNDARY_REQUIRED")?;
        let hash = match wallet::send_journaled(
            self.profile.deployment.chain_id,
            &self.voter,
            to,
            data,
            boundary.1,
        )
        .await
        {
            Ok(hash) => hash,
            Err("WALLET_REJECTED") => {
                crate::moderator_requests::rejected(&self.profile, &self.voter, request)?;
                return Err("WALLET_REJECTED");
            }
            Err(_) => return Err("REQUEST_UNRESOLVED"),
        };
        let journal_saved =
            crate::moderator_requests::sent(&self.profile, &self.voter, request, &hash);
        // A wallet prompt can outlive a context change. Always preserve a valid
        // returned broadcast hash; a reset cannot cancel an already sent tx.
        let item = json!({"hash":hash,"action":action,"caseId":id.map(|v|v.to_decimal()),
            "chainId":self.profile.deployment.chain_id.to_string(),"contract":self.profile.deployment.moderation.address,
            "voter":self.voter,"at":Date::now()});
        let saved = save_public_transaction(item);
        let warning = if !(self.active)() {
            Some("CONTEXT_CHANGED_AFTER_SEND")
        } else if journal_saved.is_err() || saved.is_err() {
            Some("TRANSACTION_HISTORY_NOT_SAVED")
        } else {
            None
        };
        Ok(Broadcast { hash, warning })
    }
}
fn save_public_transaction(item: Value) -> Result<()> {
    let storage = web_sys::window()
        .ok_or("STORAGE_FAILED")?
        .local_storage()
        .map_err(|_| "STORAGE_FAILED")?
        .ok_or("STORAGE_FAILED")?;
    let mut history: Vec<Value> = storage
        .get_item("moderator-public-transactions-v1")
        .map_err(|_| "STORAGE_FAILED")?
        .filter(|s| s.len() <= 128 * 1024)
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    history.push(item);
    if history.len() > 200 {
        history.drain(..history.len() - 200);
    }
    storage
        .set_item(
            "moderator-public-transactions-v1",
            &serde_json::to_string(&history).map_err(|_| "STORAGE_FAILED")?,
        )
        .map_err(|_| "STORAGE_FAILED")
}
fn history_rows(profile: &ModeratorProfile, voter: &str) -> Result<Vec<Value>> {
    let storage = web_sys::window()
        .ok_or("STORAGE_FAILED")?
        .local_storage()
        .map_err(|_| "STORAGE_FAILED")?
        .ok_or("STORAGE_FAILED")?;
    let Some(raw) = storage
        .get_item("moderator-public-transactions-v1")
        .map_err(|_| "STORAGE_FAILED")?
    else {
        return Ok(vec![]);
    };
    if raw.len() > 128 * 1024 {
        return Err("PUBLIC_HISTORY_INVALID");
    }
    let rows: Vec<Value> = serde_json::from_str(&raw).map_err(|_| "PUBLIC_HISTORY_INVALID")?;
    if rows.len() > 200 {
        return Err("PUBLIC_HISTORY_INVALID");
    }
    Ok(rows
        .into_iter()
        .filter(|r| {
            r["chainId"].as_str() == Some(profile.deployment.chain_id.to_string().as_str())
                && r["contract"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(&profile.deployment.moderation.address))
                && r["voter"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(voter))
        })
        .filter(|r| {
            r["hash"]
                .as_str()
                .filter(|s| {
                    s.len() == 66
                        && s.starts_with("0x")
                        && s[2..].bytes().all(|b| b.is_ascii_hexdigit())
                })
                .is_some()
        })
        .collect())
}
pub(crate) fn public_history(profile: &ModeratorProfile, voter: &str) -> Result<Vec<String>> {
    Ok(history_rows(profile, voter)?
        .iter()
        .map(|r| {
            format!(
                "{} · Case {}\n{}",
                r["action"].as_str().unwrap_or("Transaction"),
                r["caseId"].as_str().unwrap_or("not applicable"),
                r["hash"].as_str().unwrap_or("")
            )
        })
        .collect())
}
pub(crate) fn public_case_ids(profile: &ModeratorProfile, voter: &str) -> Result<Vec<Uint256>> {
    let mut ids: Vec<Uint256> = history_rows(profile, voter)?
        .iter()
        .filter_map(|r| {
            r["caseId"]
                .as_str()
                .and_then(|id| Uint256::decimal(id).ok())
        })
        .collect();
    ids.extend(
        crate::moderator_requests::load(profile, voter)?
            .iter()
            .filter_map(|r| {
                r.case_id
                    .as_deref()
                    .and_then(|id| Uint256::decimal(id).ok())
            }),
    );
    ids.retain(|id| *id != Uint256::ZERO);
    Ok(ids)
}

pub(crate) async fn receipt(profile: &ModeratorProfile, hash: &str) -> Result<&'static str> {
    if hash.len() != 66
        || !hash.starts_with("0x")
        || !hash[2..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("INVALID_TRANSACTION_HASH");
    }
    let chain = rpc(profile, "eth_chainId", json!([])).await?;
    if crate::transport::quantity(chain.as_str().ok_or("INVALID_RPC_RESULT")?)?
        != profile.deployment.chain_id
    {
        return Err("SOURCE_CHAIN_CHANGED");
    }
    let raw = rpc(profile, "eth_getTransactionReceipt", json!([hash])).await?;
    if raw.is_null() {
        check_receipt_chain(
            profile.deployment.chain_id,
            &rpc(profile, "eth_chainId", json!([])).await?,
        )?;
        return Ok("Receipt not yet available. Refresh before any retry.");
    }
    let (number, _) = receipt_anchor(&raw, hash)?;
    let canonical = rpc(
        profile,
        "eth_getBlockByNumber",
        json!([format!("0x{number:x}"), false]),
    )
    .await?;
    let chain = rpc(profile, "eth_chainId", json!([])).await?;
    let status =
        canonical_receipt_status(&raw, hash, &canonical, profile.deployment.chain_id, &chain)?;
    Ok(crate::moderator_requests::reconcile(profile, hash, &raw)
        .await?
        .unwrap_or(status))
}

fn check_receipt_chain(expected: u64, observed: &Value) -> Result<()> {
    if crate::transport::quantity(observed.as_str().ok_or("INVALID_RPC_RESULT")?)? != expected {
        return Err("SOURCE_CHAIN_CHANGED");
    }
    Ok(())
}

fn receipt_anchor(raw: &Value, hash: &str) -> Result<(u64, String)> {
    if raw["transactionHash"]
        .as_str()
        .is_none_or(|s| !s.eq_ignore_ascii_case(hash))
    {
        return Err("INVALID_RECEIPT");
    }
    let block_hash = raw["blockHash"].as_str().ok_or("INVALID_RECEIPT")?;
    if block_hash.len() != 66
        || !block_hash.starts_with("0x")
        || !block_hash[2..].bytes().all(|v| v.is_ascii_hexdigit())
        || block_hash[2..].bytes().all(|v| v == b'0')
    {
        return Err("INVALID_RECEIPT");
    }
    let number = crate::transport::quantity(raw["blockNumber"].as_str().ok_or("INVALID_RECEIPT")?)
        .map_err(|_| "INVALID_RECEIPT")?;
    Ok((number, block_hash.to_ascii_lowercase()))
}

/// A successful status is a canonical observation, not a finality guarantee.
pub(crate) fn canonical_receipt_status(
    raw: &Value,
    hash: &str,
    canonical: &Value,
    expected_chain: u64,
    observed_chain: &Value,
) -> Result<&'static str> {
    let (number, block_hash) = receipt_anchor(raw, hash)?;
    check_receipt_chain(expected_chain, observed_chain)?;
    if canonical["hash"]
        .as_str()
        .is_none_or(|v| !v.eq_ignore_ascii_case(&block_hash))
        || canonical["number"]
            .as_str()
            .and_then(|v| crate::transport::quantity(v).ok())
            != Some(number)
    {
        return Err("RECEIPT_BLOCK_CHANGED");
    }
    match raw["status"].as_str() {
        Some("0x1") => Ok("Transaction confirmed. Refresh the case to read updated state."),
        Some("0x0") => Ok("Transaction reverted. Refresh evidence before trying again."),
        _ => Err("INVALID_RECEIPT"),
    }
}

#[cfg(test)]
mod receipt_tests {
    use super::*;

    fn fixture() -> (String, Value, Value) {
        let hash = format!("0x{}", "11".repeat(32));
        let block_hash = format!("0x{}", "ab".repeat(32));
        let receipt = json!({"transactionHash":hash,"blockNumber":"0x42", "blockHash":block_hash,"status":"0x1"});
        let block = json!({"number":"0x42","hash":block_hash});
        (hash, receipt, block)
    }

    #[test]
    fn canonical_success_and_revert_keep_distinct_status() {
        let (hash, mut receipt, block) = fixture();
        assert!(
            canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x27d8"))
                .unwrap()
                .starts_with("Transaction confirmed.")
        );
        receipt["status"] = json!("0x0");
        assert!(
            canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x27d8"))
                .unwrap()
                .starts_with("Transaction reverted.")
        );
    }

    #[test]
    fn successful_orphan_receipt_and_wrong_block_number_are_rejected() {
        let (hash, receipt, mut block) = fixture();
        block["hash"] = json!(format!("0x{}", "cd".repeat(32)));
        assert_eq!(
            canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x27d8")),
            Err("RECEIPT_BLOCK_CHANGED")
        );
        let (_, _, mut block) = fixture();
        block["number"] = json!("0x43");
        assert_eq!(
            canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x27d8")),
            Err("RECEIPT_BLOCK_CHANGED")
        );
        assert_eq!(
            canonical_receipt_status(&receipt, &hash, &Value::Null, 10200, &json!("0x27d8")),
            Err("RECEIPT_BLOCK_CHANGED")
        );
    }

    #[test]
    fn chain_change_during_receipt_read_is_rejected() {
        let (hash, receipt, block) = fixture();
        assert_eq!(
            canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x64")),
            Err("SOURCE_CHAIN_CHANGED")
        );
    }

    #[test]
    fn receipt_anchor_requires_a_mined_hash_and_canonical_quantity() {
        let (hash, receipt, _) = fixture();
        for field in ["blockHash", "blockNumber", "transactionHash"] {
            let mut invalid = receipt.clone();
            invalid[field] = Value::Null;
            assert_eq!(receipt_anchor(&invalid, &hash), Err("INVALID_RECEIPT"));
        }
        for block_hash in [
            "0x00".to_owned(),
            format!("0x{}", "00".repeat(32)),
            format!("0x{}", "gg".repeat(32)),
        ] {
            let mut invalid = receipt.clone();
            invalid["blockHash"] = json!(block_hash);
            assert_eq!(receipt_anchor(&invalid, &hash), Err("INVALID_RECEIPT"));
        }
        let mut invalid = receipt.clone();
        invalid["blockNumber"] = json!("0x042");
        assert_eq!(receipt_anchor(&invalid, &hash), Err("INVALID_RECEIPT"));
    }

    #[test]
    fn unknown_status_is_rejected_and_hash_case_does_not_change_identity() {
        let (hash, mut receipt, mut block) = fixture();
        block["hash"] = json!(format!("0x{}", "AB".repeat(32)));
        assert!(canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x27d8")).is_ok());
        receipt["status"] = json!("0x2");
        assert_eq!(
            canonical_receipt_status(&receipt, &hash, &block, 10200, &json!("0x27d8")),
            Err("INVALID_RECEIPT")
        );
    }
}
