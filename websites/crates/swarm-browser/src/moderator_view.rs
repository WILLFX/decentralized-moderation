//! Human-facing descriptions. These never authorize a protocol action.
use swarm_core::{moderator::*, review::Metadata};

pub(crate) fn choice(action_type: u8, vote: u8) -> &'static str {
    match (action_type, vote) {
        (0, 1) => "List this content",
        (0, 2) => "Do not list this content",
        (1, 1) => "Remove this listing",
        (1, 2) => "Keep this listing",
        _ => "Unknown choice — do not commit",
    }
}

pub(crate) fn question(c: &CaseInfo) -> String {
    match c.action_type {
        0 => "LIST request: should this content be added to the index?".into(),
        1 => format!(
            "REMOVE request: should the listing from Case {} be removed from the index?",
            c.target_case_id
        ),
        _ => "Unsupported case type. Vote preparation is blocked.".into(),
    }
}

pub(crate) fn metadata(m: &Metadata) -> String {
    format!(
        "Title: {}\nDescription: {}\nDeclared type: {}\nDeclared content type: {}\nTopics: {}\nLanguage: {}\nPublisher-supplied source: {}\n\nThese metadata bytes are authenticated. Check whether their claims honestly describe the content.",
        m.title, m.description.as_deref().unwrap_or("Not provided"), m.entry_type,
        m.content_type, m.topics.join(", "), m.language.as_deref().unwrap_or("Not provided"),
        m.source.as_deref().unwrap_or("Not provided")
    )
}

pub(crate) fn deadline(s: &CaseSnapshot) -> Option<(&'static str, u64)> {
    match s.case.phase {
        1 | 2 => match committee_at(s) {
            Some(1) => Some(("Committee A commitment deadline", s.schedule.deadline_a)),
            _ => Some(("Committee B commitment deadline", s.schedule.deadline_b)),
        },
        3 if s.case.outcome_seed_block == 0 => Some(("Reveal deadline", s.case.phase_deadline)),
        4 => Some(("Challenge deadline", s.case.phase_deadline)),
        _ => None,
    }
}

/// A presentation group for checked, known work. It is neither a duty index nor
/// permission to send: opening a row must collect fresh evidence again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WorkKind {
    Required,
    Waiting,
    Blocked,
    Preparation,
    Settled,
    Other,
}

fn recorded_vote(s: &CaseSnapshot) -> bool {
    Uint256::hex(&s.vote.commitment).is_ok_and(|v| v != Uint256::ZERO)
}

pub(crate) fn work_kind(s: &CaseSnapshot, eligibility: Eligibility) -> WorkKind {
    let recorded = recorded_vote(s);
    let actions = case_actions(s, eligibility);
    if recorded && s.vote.settled {
        WorkKind::Settled
    } else if actions.allowed(Action::Claim)
        || actions.allowed(Action::Reveal) && [1, 2].contains(&s.vote.committee)
    {
        WorkKind::Required
    } else if recorded
        && matches!(
            draw_window(s),
            DrawWindow::LastObserved | DrawWindow::Expired
        )
    {
        WorkKind::Blocked
    } else if recorded {
        WorkKind::Waiting
    } else if actions.allowed(Action::Commit) {
        WorkKind::Preparation
    } else {
        // Public progress and a possible challenge do not create a personal
        // vote obligation. A challenge already recorded above does.
        WorkKind::Other
    }
}

/// Explain only blocked *new* participation. A recorded vote keeps its own duty.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ParticipationBlock {
    InactiveStake,
    FrozenStake,
    NotSelected,
    SeedUnavailable,
    ScheduleUnavailable,
}
pub(crate) fn participation_block(
    s: &CaseSnapshot,
    eligibility: Eligibility,
) -> Option<ParticipationBlock> {
    if recorded_vote(s) || committee_at(s).is_none() {
        return None;
    }
    let actions = case_actions(s, eligibility);
    let commit = actions
        .actions
        .iter()
        .find(|a| a.action == Action::Commit)?;
    if commit.allowed {
        return None;
    }
    Some(match commit.reason {
        "STAKE_INACTIVE_OR_FROZEN" if !s.moderator.staked => ParticipationBlock::InactiveStake,
        "STAKE_INACTIVE_OR_FROZEN" => ParticipationBlock::FrozenStake,
        "SCHEDULE_REVISION_UNAVAILABLE" => ParticipationBlock::ScheduleUnavailable,
        "LOTTERY_RESULT" if eligibility == Eligibility::NotSelected => {
            ParticipationBlock::NotSelected
        }
        "SeedUnavailable" => ParticipationBlock::SeedUnavailable,
        _ => return None,
    })
}
pub(crate) fn participation_hint(block: ParticipationBlock) -> &'static str {
    match block {
        ParticipationBlock::InactiveStake => "This account has no active stake. Check Stake before joining new votes.",
        ParticipationBlock::FrozenStake => "Stake is frozen for new votes. Check Stake for the end time.",
        ParticipationBlock::NotSelected => "This account is not selected for this committee. Browse other cases.",
        ParticipationBlock::SeedUnavailable => "Selection evidence is unavailable. Refresh case evidence or browse other cases.",
        ParticipationBlock::ScheduleUnavailable => "The committee schedule cannot accept a new vote at this read. Refresh or browse other cases.",
    }
}
pub(crate) fn participation_note(block: ParticipationBlock, frozen_until: &str) -> String {
    if block == ParticipationBlock::FrozenStake {
        format!("New votes are frozen until {frozen_until}. Refresh case evidence after that time.")
    } else {
        participation_hint(block).into()
    }
}
pub(crate) fn own_duty(s: &CaseSnapshot, eligibility: Eligibility) -> &'static str {
    match work_kind(s, eligibility) {
        WorkKind::Settled => "Your vote is settled. No further vote action is due.",
        WorkKind::Required if case_actions(s, eligibility).allowed(Action::Claim) => {
            "Settle your recorded vote. The result determines any payment or frozen time."
        }
        WorkKind::Required => "Your reveal is due. Open the case to check readiness.",
        WorkKind::Blocked => {
            "Outcome draw is blocked at this read. Keep recovery; settlement is not yet available."
        }
        WorkKind::Waiting if s.vote.committee == 0 => {
            "Your public challenge vote is recorded. Settle after the case finishes."
        }
        WorkKind::Waiting if s.vote.round != s.case.challenges => {
            "Your vote is from an earlier round. Settle after the case finishes."
        }
        WorkKind::Waiting if s.vote.revealed != 0 => {
            "Your vote is revealed. Return after the case finishes to settle."
        }
        WorkKind::Waiting if [1, 2].contains(&s.case.phase) => {
            "Your commitment is recorded. Return for reveal and settlement."
        }
        WorkKind::Waiting => {
            "Reveal is no longer available at this read. Keep recovery until settlement."
        }
        WorkKind::Preparation => {
            "You can review and prepare a vote. No on-chain vote is recorded for this account."
        }
        WorkKind::Other => participation_block(s, eligibility)
            .map(participation_hint)
            .unwrap_or("No on-chain vote is recorded for this account."),
    }
}

/// Sort only the known checked rows. Never compare a block-height draw limit to
/// a timestamp, or imply that a settlement has an invented time deadline.
pub(crate) fn work_order(s: &CaseSnapshot, eligibility: Eligibility) -> (u8, u64) {
    let next_deadline = || deadline(s).map(|(_, time)| time).unwrap_or(u64::MAX);
    match work_kind(s, eligibility) {
        WorkKind::Required if case_actions(s, eligibility).allowed(Action::Claim) => (0, u64::MAX),
        WorkKind::Required => (0, s.case.phase_deadline),
        WorkKind::Blocked => (1, u64::MAX),
        WorkKind::Waiting => (2, next_deadline()),
        WorkKind::Preparation => (3, next_deadline()),
        WorkKind::Other => (4, u64::MAX),
        WorkKind::Settled => (5, u64::MAX),
    }
}

pub(crate) fn duration(seconds: u64) -> String {
    format!(
        "{}d {}h {}m {}s",
        seconds / 86400,
        seconds / 3600 % 24,
        seconds / 60 % 60,
        seconds % 60
    )
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DrawWindow {
    Unarmed,
    Waiting,
    Open,
    LastObserved,
    Expired,
}
pub(crate) fn draw_window(s: &CaseSnapshot) -> DrawWindow {
    let target = s.case.outcome_seed_block;
    if s.case.phase != 3 || target == 0 {
        return DrawWindow::Unarmed;
    }
    if s.source.number <= target {
        return DrawWindow::Waiting;
    }
    if let Some(r) = &s.outcome_recovery {
        return if r.cached() || s.source.number < r.recover_until {
            DrawWindow::Open
        } else if s.source.number == r.recover_until {
            DrawWindow::LastObserved
        } else {
            DrawWindow::Expired
        };
    }
    match s.source.number - target {
        251.. => DrawWindow::Expired,
        250 => DrawWindow::LastObserved,
        _ => DrawWindow::Open,
    }
}
/// Browser preparation can withhold a new request; the core execution rule is unchanged.
pub(crate) fn draw_request_hold(s: &CaseSnapshot) -> Option<&'static str> {
    match draw_window(s) {
        DrawWindow::LastObserved => Some("DRAW_WINDOW_EXHAUSTED_AT_READ"),
        DrawWindow::Expired => Some("DRAW_TARGET_EXPIRED"),
        _ => None,
    }
}
pub(crate) fn draw_action_label(s: &CaseSnapshot) -> &'static str {
    match draw_window(s) {
        DrawWindow::Unarmed => "No current outcome draw is scheduled",
        DrawWindow::Waiting => "Wait for a block after the target, then refresh",
        DrawWindow::Open => {
            "Available at this read; timely transaction inclusion is still required"
        }
        DrawWindow::LastObserved => {
            "No new request: the final valid execution block is already observed"
        }
        DrawWindow::Expired if s.outcome_recovery.is_some() => {
            "Recovery boundary passed; complete the expired draw"
        }
        DrawWindow::Expired => "Blocked: recovery support could not be verified",
    }
}
/// Compact case-level public progress. This does not replace a personal duty
/// or authorize a transaction; the original draw and reveal checks still apply.
pub(crate) fn draw_phase_note(s: &CaseSnapshot) -> Option<String> {
    if let Some(r) = &s.outcome_recovery {
        if r.expired {
            return Some(if s.case.challenges == 0 {
                "Initial draw expired: unresolved. The submitter can withdraw the fee; settle recorded votes. Non-reveal penalties remain.".into()
            } else {
                "Expired draw: last completed outcome finalized. Ordinary rewards and freezes follow that fallback; they do not prove responsibility for draw failure. Settle recorded votes.".into()
            });
        }
        if s.case.phase == 3 && s.case.outcome_seed_block != 0 {
            return Some(if r.cached() {
                "Original draw hash saved. Anyone may draw; this hash has no expiry.".into()
            } else if s.source.number > r.recover_until {
                "Original hash recovery ended without a cache. Complete the expired draw to unlock settlement.".into()
            } else if s.source.number == r.recover_until {
                "Final recovery block observed. Refresh evidence; a new draw request would arrive too late.".into()
            } else if s.source.number <= s.case.outcome_seed_block {
                format!(
                    "Draw opens after target block {}. Refresh case evidence.",
                    s.case.outcome_seed_block
                )
            } else {
                "Draw now, or save the original hash for later. A failed history read does not permit early expiry.".into()
            });
        }
    }
    Some(match draw_window(s) {
        DrawWindow::Unarmed => return None,
        DrawWindow::Waiting => format!(
            "Draw is not open yet. Refresh from block {}.",
            s.case.outcome_seed_block.saturating_add(1)
        ),
        DrawWindow::Open if s.case.outcome_seed_block.saturating_add(250) - s.source.number == 1 =>
            "One later valid block remains at this read. Anyone may draw; inclusion is not guaranteed.".into(),
        DrawWindow::Open =>
            "Anyone may draw now. Timely inclusion is required; no caller is guaranteed.".into(),
        DrawWindow::LastObserved =>
            "New draw requests are blocked: the final valid block is already observed. Refresh evidence.".into(),
        DrawWindow::Expired =>
            "Recovery support was not verified at this read. Keep transaction history and refresh; no expiry action is enabled.".into(),
    })
}
pub(crate) fn draw_guidance(s: &CaseSnapshot) -> Option<String> {
    if let Some(r) = &s.outcome_recovery {
        let note = draw_phase_note(s)?;
        return Some(format!(
            "{note}\nOriginal target: {}. Recovery through block {} inclusive. Observed block: {}.",
            s.case.outcome_seed_block, r.recover_until, s.source.number
        ));
    }
    let target = s.case.outcome_seed_block;
    let last = target.saturating_add(250);
    let message=match draw_window(s) {
        DrawWindow::Unarmed=>return None,
        DrawWindow::Waiting=>"Wait for a block after the target, then refresh case evidence. Passing a time or block limit does not advance the case automatically.".into(),
        DrawWindow::Open=>format!("Draw now through an explicit transaction. {} later valid execution heights remain after this observed block. Wallet confirmation and inclusion can still be delayed; another caller is not guaranteed to act.",last-s.source.number),
        DrawWindow::LastObserved=>"The final valid execution block has already been observed. A new transaction first included in the next block would be too late, so this application will not prepare a new draw. Refresh to check current evidence; no later draw window is promised.".into(),
        DrawWindow::Expired=>"Recovery support was not verified at this read. This may be a legacy deployment or an unavailable capability read. Keep recovery and transaction history, and refresh evidence. No replacement hash or early expiry is permitted.".into(),
    };
    Some(format!("Outcome target block: {target}. Observed block: {}.\nValid execution heights: {} through {last}, inclusive.\n{message}\nThese are block limits as of this read, not a countdown in minutes.",s.source.number,target.saturating_add(1)))
}
/// Brief guidance only. The full report and repeated disclosure guards remain
/// authoritative; this text does not authorize a reveal.
pub(crate) fn reveal_summary(ready: bool, reason: &str) -> &'static str {
    if ready {
        return "Passed for this check only. Reveal repeats the guards before sending.";
    }
    match reason {
        "FINALIZED_REVEAL_REQUIRED" => {
            "Finalized evidence is outside reveal. Refresh the case and keep recovery."
        }
        "LATEST_REVEAL_REQUIRED" => {
            "Current evidence is outside reveal. Refresh the case for its next action."
        }
        "INCLUSION_BUDGET" => {
            "Too little time remains for a safe reveal. Keep recovery and refresh the case."
        }
        "WINDOW_EXPIRED" => {
            "The reveal time budget has expired. Keep recovery and refresh the case."
        }
        "HEAD_STALE" | "EVIDENCE_STALE" => {
            "Evidence is too old for a safe reveal. Refresh and check again."
        }
        "CLOCK_INVALID" | "HEAD_CLOCK_AHEAD" => {
            "Device and chain time could not be checked safely. Check your device clock."
        }
        "SOURCE_CHAIN_CHANGED"
        | "SOURCE_BLOCK_CHANGED"
        | "FINALIZED_TAG_CHANGED"
        | "NODE_ORDER_INVALID"
        | "SNAPSHOT_INVALID"
        | "INVALID_RPC_RESULT" => {
            "Source evidence could not be verified. Refresh and check the RPC connection."
        }
        "CASE_CHANGED"
        | "ROUND_CHANGED"
        | "COMMITMENT_CHANGED"
        | "DEADLINE_CHANGED"
        | "CONTEXT_CHANGED"
        | "WALLET_CONTEXT_CHANGED" => {
            "The case or vote context changed. Refresh this case and check again."
        }
        "VAULT_LOCKED" | "SECRET_NOT_FOUND" | "SECRET_MISMATCH" => {
            "Unlock or restore the matching saved vote before checking reveal readiness."
        }
        "TIMING_PROFILE_REQUIRED" => {
            "The timing profile is invalid. Use the intended deployment profile."
        }
        "VOTE_REVEALED" => "This vote is already revealed. Refresh the case for follow-up.",
        "VOTE_SETTLED" => "This vote is already settled. No reveal is due.",
        "OUTCOME_ARMED" => "Reveal has closed and an outcome draw is scheduled. Refresh the case.",
        _ => "Readiness could not be established. Inspect the check details.",
    }
}

pub(crate) fn reveal_decision_text(
    ready: bool,
    reason: &str,
    remaining: Option<i128>,
    budget: u64,
    clock_error: u64,
) -> String {
    let time=remaining.map(|v|format!("Conservative time remaining at this check: {v} seconds (includes the configured {clock_error}-second clock allowance).")).unwrap_or_else(||"Conservative remaining time was not accepted because an earlier evidence check refused.".into());
    let missed_budget = if matches!(reason, "INCLUSION_BUDGET" | "WINDOW_EXPIRED") {
        " Waiting does not restore a missed time budget; do not weaken timing settings to force a reveal."
    } else {
        ""
    };
    format!("{}\n{time}\nConfigured inclusion budget: {budget} seconds. Remaining time must be strictly greater than this budget.{missed_budget}\n{}\nThis is a past read-only observation. It does not reserve time or authorize disclosure. Reveal always repeats the full guards and can refuse after an earlier pass.",if ready{"Passed at this check only."}else{"Not ready at this check."},if ready{"Current evidence passed the unchanged reveal guard.".into()}else{error(reason)})
}

pub(crate) fn preparation_step(
    reviewed: bool,
    unlocked: bool,
    saved: bool,
    covered: bool,
) -> &'static str {
    if !reviewed {
        "Load the verified documents, inspect all metadata and the content, and complete both review acknowledgements."
    } else if !unlocked {
        "Unlock private storage before saving or using your private choice."
    } else if !saved {
        "Save your private choice. Review its practical effect before accepting the confirmation."
    } else if !covered {
        "Export encrypted recovery, save the file, select it and verify coverage for this exact vote."
    } else {
        "Your saved choice and recovery are ready. Commit is a separate wallet transaction; check the practical choice before confirming."
    }
}

pub(crate) fn next_step(s: &CaseSnapshot, eligibility: Eligibility) -> &'static str {
    let a = case_actions(s, eligibility);
    let used = Uint256::hex(&s.vote.commitment).is_ok_and(|v| v != Uint256::ZERO);
    if a.allowed(Action::ExpireOutcome) {
        if s.case.challenges == 0 {
            "Complete the expired draw as unresolved, then withdraw the submission refund and settle recorded votes."
        } else {
            "Complete the expired draw using the last completed outcome, then settle recorded votes against that fallback."
        }
    } else if draw_window(s) == DrawWindow::Open
        && s.outcome_recovery.as_ref().is_some_and(|r| r.cached())
    {
        "Draw using the saved original hash. This hash has no draw expiry."
    } else if draw_window(s) == DrawWindow::Expired {
        "Draw target expired at the verified legacy limit. Recovery support is unverified; refresh evidence and keep recovery/history. No expiry request is enabled."
    } else if draw_window(s) == DrawWindow::LastObserved {
        "The final valid draw block has already been observed. A new draw cannot be prepared for a later block. Refresh evidence and keep recovery/history; do not expect a new target."
    } else if draw_window(s) == DrawWindow::Open {
        "Draw the outcome now through Case progress. The window is bounded in blocks; a transaction still needs timely inclusion. Nobody is guaranteed to advance it for you."
    } else if draw_window(s) == DrawWindow::Waiting {
        "The outcome target is not yet past. Wait for a block after it, then refresh case evidence. The target will not be replaced if its draw window expires."
    } else if s.vote.settled {
        "This vote is settled. No further vote transaction is required."
    } else if a.allowed(Action::Claim) {
        "Settle your vote. Settlement can pay a reward, pay nothing, or apply frozen time according to the result."
    } else if a.allowed(Action::Reveal) {
        "Unlock the matching saved vote, then check reveal readiness. The finalized-state guard must pass again when revealing."
    } else if a.allowed(Action::CloseReveal) {
        "The reveal deadline has passed. Use Close reveal and advance case, then refresh. This explicit call applies the contract's turnout rule; a deadline alone does not open a draw or settle votes."
    } else if a.allowed(Action::CloseCommitB) {
        "Both commitment deadlines have passed. Use Close second committee to advance the case, then refresh its state. No automatic caller is guaranteed."
    } else if a.allowed(Action::CloseCommitA) {
        "The first committee deadline has passed. Close first committee can advance or synchronize the stored phase. Refresh to see the effective next deadline."
    } else if a.allowed(Action::CloseChallenge) {
        "The challenge deadline has passed. Finalize outcome is an explicit transaction; then refresh the case before settling."
    } else if used {
        "Your vote is recorded. Follow the observed phase and deadline, refresh when returning, and retain recovery until settlement. Phase changes can require an explicit caller."
    } else if a.allowed(Action::Commit) {
        "Review the case and all metadata, unlock private storage, save your choice, then export and verify recovery before committing."
    } else {
        "No vote can be committed now. Read the phase and action explanations below, or choose another case."
    }
}

/// Connection failures belong beside the wallet control, with Recovery reachable.
pub(crate) fn wallet_guidance(code: &str) -> Option<&'static str> {
    Some(match code.split(':').next().unwrap_or(code) {
        "WALLET_SELECTION_REQUIRED" => "Choose the wallet you want to connect.",
        "WALLET_DISCOVERY_FAILED" => "Wallet discovery could not finish. Reload this page and try again.",
        "WALLET_UNAVAILABLE" => "No browser wallet is available to this page. Open this site in a browser with your wallet enabled, then connect again.",
        "WALLET_PROVIDER_UNSUPPORTED" => "This wallet does not provide the connection API this app needs. Use a compatible Ethereum browser wallet.",
        "WALLET_EVENTS_UNAVAILABLE" => "This wallet cannot report account and network changes safely. Use a compatible Ethereum browser wallet.",
        "WALLET_EVENT_CLEANUP_FAILED" => "The earlier wallet connection could not be cleaned up. Reload this page before connecting again.",
        "WALLET_EVENT_REGISTRATION_FAILED" => "The wallet connection could not be monitored safely. Retry connection or reload this page.",
        "WALLET_REJECTED" => "Wallet access was declined. Connect again when you are ready.",
        "WALLET_REQUEST_FAILED" => "The wallet did not complete the account request. Check its prompt, then connect again.",
        "WALLET_CHAIN_MISMATCH" => "Select the deployment's network in your wallet, then connect again.",
        "NO_WALLET_ACCOUNT" => "Unlock your wallet and select an account, then connect again.",
        _ => return None,
    })
}

pub(crate) fn error(code: &str) -> String {
    let explanation = match code {
        "REQUEST_UNRESOLVED" => "A previous request is unfinished. Open Transactions and check its hash from your wallet activity before sending again. Keep your private recovery and site data.",
        "REQUEST_TRANSACTION_MISMATCH" => "This transaction does not match the unfinished request. Keep the request and check the original wallet activity.",
        "FINALITY_NOT_AVAILABLE" => "The source cannot confirm finality yet. Keep the saved request and check its receipt later.",
        "REQUEST_ORIGINAL_UNAVAILABLE" => "The original transaction could not be verified. Keep the saved request and check wallet activity; another hash alone cannot resolve it.",
        "REQUEST_WAIT_FINALITY" => "The matching transaction is mined. Wait for chain finality, then check its receipt again before sending another action.",
        "REQUEST_BUSY_IN_ANOTHER_TAB" => "Another tab is checking or sending a transaction. Finish there, then return here.",
        "REQUEST_COORDINATION_UNAVAILABLE" | "REQUEST_COORDINATION_FAILED" => "Sending is unavailable in this browser or connection. Use a secure HTTPS site or your local Bee gateway. Keep this site's data and recovery files.",
        "REQUEST_STORAGE_FAILED" | "REQUEST_HISTORY_INVALID" | "REQUEST_HISTORY_CONFLICT" | "REQUEST_HISTORY_FULL" => "The saved request could not be safely updated. Sending is blocked. Keep this site's data and recovery files.",
        "RPC_READ_FAILED" => "Could not read chain evidence. Refresh to try again.",
        "VAULT_LOCKED" => "Private storage is locked. Unlock the existing vault first. If its password is unavailable, keep its data and restore your recovery file in a separate browser profile with fresh site storage. Do not clear this vault.",
        "BACKUP_AUTHENTICATION_FAILED" => "The recovery file could not be opened. Check that you selected the intended file and entered its recovery password.",
        "SELECT_RECOVERY_FILE" => "Choose the encrypted recovery file saved on your device first.",
        "BACKUP_REQUIRED" => "Export the encrypted recovery, select the saved file, and verify that it covers this exact vote before committing.",
        "VOTE_CONFLICT" => "A different private choice is already saved for this vote context. No transaction was sent by preparation. Keep the existing recovery; this version does not replace saved choices.",
        "SECRET_MISMATCH" | "SECRET_NOT_FOUND" => "The matching private vote is missing. Import the recovery made for this account, deployment, case, round and committee.",
        "REVIEW_REQUIRED" => "Load the verified documents, review the declared metadata and content, and complete both acknowledgements before saving or committing.",
        "WALLET_REJECTED" => "The wallet request was rejected. Read the current evidence before choosing another action.",
        "WALLET_NOT_CONNECTED" => "Connect the intended wallet account first.",
        "CHOICE_PROTECTED" => "This choice cannot be changed safely. Keep its recovery file and check any earlier transaction.",
          "SELECT_CASE_FIRST" => "Open a case from My work or the review queue first.",
        "VAULT_CHANGED" => "Private storage changed in another tab. Lock and unlock again before continuing; keep your recovery files.",
        "FINALIZED_REVEAL_REQUIRED" => "Finalized evidence does not show this case in REVEAL. Keep your recovery file. If the latest case is in REVEAL, wait for finalized evidence to catch up, then refresh the case and check readiness again.",
        "LATEST_REVEAL_REQUIRED" => "The latest verified case is outside REVEAL. Refresh the case to see its current phase and next available action. Keep your recovery file until settlement.",
        "HEAD_STALE" | "EVIDENCE_STALE" => "The chain evidence is too old for a safe reveal. Refresh the case and check readiness again. If this continues, check the configured RPC connection.",
        "HEAD_CLOCK_AHEAD" | "CLOCK_INVALID" => "The device clock and chain time could not be checked safely. Check your device time, then refresh the case and check readiness again.",
        "INCLUSION_BUDGET" => "Too little time remains under the configured inclusion budget. This application will not reveal. Keep your recovery file and refresh the case for its next available action.",
        "WINDOW_EXPIRED" => "No conservative reveal time remains after the configured clock allowance. This application will not disclose your vote. Refresh the case and retain recovery; settlement requires a terminal case.",
        "OUTCOME_ARMED" => "Reveal has closed and an outcome target is already scheduled. Refresh the case and follow its bounded draw window. An earlier reveal readiness pass cannot be reused.",
        "DEADLINE_CHANGED" | "ROUND_CHANGED" => "The reveal context changed between the evidence reads. Refresh the selected case and repeat readiness with its current deadline and round.",
        "TIMING_PROFILE_REQUIRED" => "The configured timing profile is invalid. Obtain the intended deployment profile; do not weaken timing settings to force a reveal.",
        "CHALLENGE_INTENT_UNSUPPORTED" => "This deployment does not support a challenge bound to your reviewed choice. No challenge was sent.",
        "DRAW_TARGET_EXPIRED" => "No new draw request was prepared at this read. Refresh the case to check original-hash recovery or the expiry action. Keep recovery and transaction history.",
        "DRAW_WINDOW_EXHAUSTED_AT_READ" => "The last valid execution block is already in the observed chain. A newly included draw would be too late. No new draw request was prepared; refresh the case and keep recovery/history.",
        "OUTCOME_NOT_DRAWABLE" | "SEED_UNAVAILABLE" => "The outcome draw could not be prepared from current evidence. Refresh the case and read its target, observed height and last valid execution block. Waiting only helps before the target; it cannot replace an expired target.",
        _ => "The action could not complete. Its checks remain in force. Refresh the relevant evidence before continuing; check wallet activity and any receipt before retrying a send.",
    };
    format!("{explanation}\nDetails: {code}")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wallet_connection_guidance_is_actionable_and_does_not_echo_provider_text() {
        for code in [
            "WALLET_UNAVAILABLE",
            "WALLET_PROVIDER_UNSUPPORTED",
            "WALLET_EVENTS_UNAVAILABLE",
            "WALLET_EVENT_CLEANUP_FAILED",
            "WALLET_EVENT_REGISTRATION_FAILED",
            "WALLET_REQUEST_FAILED",
            "WALLET_REJECTED",
            "NO_WALLET_ACCOUNT",
            "WALLET_CHAIN_MISMATCH: untrusted provider detail",
        ] {
            let text = wallet_guidance(code).unwrap();
            assert!(!text.contains("untrusted provider detail"));
            assert!(!text.contains("MetaMask"));
            assert!(!text.contains("WALLET_"));
        }
        assert_eq!(wallet_guidance("BACKUP_REQUIRED"), None);
    }
    fn snapshot() -> CaseSnapshot {
        let mut values = [0u64; 25];
        values[7] = 1;
        values[9] = 900;
        values[15] = 3;
        let raw = |v: &[u64]| {
            format!(
                "0x{}",
                v.iter()
                    .map(|n| Uint256::from_u64(*n).abi())
                    .collect::<String>()
            )
        };
        CaseSnapshot {
            outcome_recovery: None,
            case_id: Uint256::from_u64(8),
            source: SourceBlock {
                number: 100,
                timestamp: 1000,
                hash: format!("0x{}", "aa".repeat(32)),
            },
            case: decode_case(&raw(&values)).unwrap(),
            vote: decode_vote(&raw(&[0, 0, 0, 0, 0])).unwrap(),
            schedule: decode_schedule(&raw(&[900, 1500, 0, 0])).unwrap(),
            moderator: decode_stake(&raw(&[1, 0, 0, 0])).unwrap(),
            refund_owed: Uint256::ZERO,
        }
    }
    #[test]
    fn practical_choices_preserve_listing_and_removal_meaning() {
        assert_eq!(choice(0, 1), "List this content");
        assert_eq!(choice(1, 1), "Remove this listing");
        assert_eq!(choice(1, 2), "Keep this listing");
        let mut s = snapshot();
        s.case.action_type = 1;
        s.case.target_case_id = Uint256::decimal("18446744073709551616").unwrap();
        assert!(question(&s.case).contains("18446744073709551616"));
        assert!(choice(2, 1).contains("do not commit"));
    }
    #[test]
    fn unsynchronized_committee_b_uses_effective_schedule_not_old_a_deadline() {
        let s = snapshot();
        assert_eq!(s.case.phase_deadline, 900);
        assert_eq!(
            deadline(&s),
            Some(("Committee B commitment deadline", 1500))
        );
    }
    fn record_vote(s: &mut CaseSnapshot) {
        s.vote.commitment = format!("0x{}", "11".repeat(32));
        s.vote.committee = 1;
    }
    #[test]
    fn optional_challenge_and_public_progress_are_not_personal_duties() {
        let mut s = snapshot();
        s.case.phase = 4;
        s.case.phase_deadline = 1500;
        assert!(case_actions(&s, Eligibility::NotOpen).allowed(Action::Challenge));
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Other);
        assert!(own_duty(&s, Eligibility::NotOpen).starts_with("No on-chain vote"));
        s.case.phase = 3;
        s.case.outcome_seed_block = 99;
        assert!(case_actions(&s, Eligibility::NotOpen).allowed(Action::Draw));
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Other);
        s.source.number = 350;
        assert_eq!(draw_window(&s), DrawWindow::Expired);
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Other);
    }
    #[test]
    fn reveal_is_a_duty_at_the_snapshot_but_not_a_readiness_pass() {
        let mut s = snapshot();
        record_vote(&mut s);
        s.case.phase = 3;
        s.case.phase_deadline = 1500;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Required);
        assert_eq!(work_order(&s, Eligibility::NotOpen), (0, 1500));
        assert!(own_duty(&s, Eligibility::NotOpen).contains("check readiness"));
        s.vote.revealed = 2;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Waiting);
        assert!(own_duty(&s, Eligibility::NotOpen).contains("revealed"));
        s.vote.revealed = 0;
        s.case.phase_deadline = s.source.timestamp;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Waiting);
        assert!(own_duty(&s, Eligibility::NotOpen).contains("no longer available"));
    }
    #[test]
    fn terminal_unsettled_votes_include_public_challenges_without_promising_rewards() {
        for phase in [5, 6] {
            for committee in [0, 1, 2] {
                let mut s = snapshot();
                record_vote(&mut s);
                s.vote.committee = committee;
                s.vote.revealed = if committee == 0 { 2 } else { 0 };
                s.case.phase = phase;
                assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Required);
                assert_eq!(work_order(&s, Eligibility::NotOpen), (0, u64::MAX));
                assert!(own_duty(&s, Eligibility::NotOpen).starts_with("Settle"));
                assert!(own_duty(&s, Eligibility::NotOpen).contains("any payment"));
                s.vote.settled = true;
                assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Settled);
            }
        }
    }
    #[test]
    fn settled_vote_status_is_separate_from_public_draw_progress() {
        let mut s = snapshot();
        record_vote(&mut s);
        s.case.phase = 3;
        s.case.outcome_seed_block = 99;
        s.vote.revealed = 1;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Waiting);
        s.source.number = 350;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Blocked);
        assert_eq!(work_order(&s, Eligibility::NotOpen), (1, u64::MAX));
        assert!(own_duty(&s, Eligibility::NotOpen).contains("settlement is not yet available"));
        s.vote.settled = true;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Settled);
        assert!(own_duty(&s, Eligibility::NotOpen).contains("No further vote action"));
    }
    #[test]
    fn recorded_commitment_and_new_preparation_use_effective_b_deadline() {
        let mut s = snapshot();
        assert_eq!(work_kind(&s, Eligibility::Selected), WorkKind::Preparation);
        assert_eq!(work_order(&s, Eligibility::Selected), (3, 1500));
        record_vote(&mut s);
        assert_eq!(work_kind(&s, Eligibility::Selected), WorkKind::Waiting);
        assert_eq!(work_order(&s, Eligibility::Selected), (2, 1500));
        assert!(own_duty(&s, Eligibility::Selected).contains("Return for reveal"));
    }
    #[test]
    fn earlier_round_and_public_challenge_wait_without_another_reveal_duty() {
        let mut s = snapshot();
        record_vote(&mut s);
        s.case.phase = 3;
        s.case.phase_deadline = 1500;
        s.case.challenges = 1;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Waiting);
        assert!(own_duty(&s, Eligibility::NotOpen).contains("earlier round"));
        s.vote.committee = 0;
        s.vote.revealed = 2;
        assert_eq!(work_kind(&s, Eligibility::NotOpen), WorkKind::Waiting);
        assert!(own_duty(&s, Eligibility::NotOpen).contains("public challenge vote"));
    }
    #[test]
    fn all_judgment_fields_and_untrusted_source_label_are_visible() {
        let m: Metadata = serde_json::from_str(r#"{"schemaVersion":1,"type":"image","title":"A document","contentType":"text/plain","topics":["biology"],"language":"en","source":"claimed source"}"#).unwrap();
        let display = metadata(&m);
        for term in [
            "Declared type: image",
            "Declared content type: text/plain",
            "Language: en",
            "Publisher-supplied source: claimed source",
            "honestly describe",
        ] {
            assert!(display.contains(term));
        }
    }
    #[test]
    fn terminal_vote_stays_findable_until_settlement() {
        let mut s = snapshot();
        s.case.phase = 5;
        s.vote.commitment = format!("0x{}", "11".repeat(32));
        assert!(next_step(&s, Eligibility::NotOpen).starts_with("Settle"));
        s.vote.settled = true;
        assert!(next_step(&s, Eligibility::NotOpen).contains("No further"));
    }
    #[test]
    fn next_step_moves_forward_as_local_prerequisites_are_completed() {
        assert!(preparation_step(false, true, true, true).starts_with("Load"));
        assert!(preparation_step(true, false, false, false).starts_with("Unlock"));
        assert!(preparation_step(true, true, false, false).starts_with("Save"));
        assert!(preparation_step(true, true, true, false).starts_with("Export"));
        assert!(preparation_step(true, true, true, true).contains("ready"));
    }
    #[test]
    fn draw_boundary_is_explicit_without_changing_core_execution_rule() {
        let mut s = snapshot();
        s.case.phase = 3;
        s.case.outcome_seed_block = 100;
        s.case.phase_deadline = 900;
        for (height, expected) in [
            (99, DrawWindow::Waiting),
            (100, DrawWindow::Waiting),
            (101, DrawWindow::Open),
            (349, DrawWindow::Open),
            (350, DrawWindow::LastObserved),
            (351, DrawWindow::Expired),
        ] {
            s.source.number = height;
            assert_eq!(draw_window(&s), expected);
            let message = draw_guidance(&s).unwrap();
            assert!(message.contains("101 through 350, inclusive"));
            assert!(message.contains("not a countdown in minutes"));
        }
        s.source.number = 350;
        assert!(case_actions(&s, Eligibility::NotOpen).allowed(Action::Draw));
        assert_eq!(draw_request_hold(&s), Some("DRAW_WINDOW_EXHAUSTED_AT_READ"));
        s.source.number = 351;
        assert!(!case_actions(&s, Eligibility::NotOpen).allowed(Action::Draw));
        assert_eq!(draw_request_hold(&s), Some("DRAW_TARGET_EXPIRED"));
        s.case.phase = 4;
        assert_eq!(draw_window(&s), DrawWindow::Unarmed);
    }
    #[test]
    fn draw_and_expiry_take_priority_for_recorded_voters_and_non_voters() {
        let mut s = snapshot();
        s.case.phase = 3;
        s.case.outcome_seed_block = 100;
        s.source.number = 101;
        for commitment in [
            format!("0x{}", "00".repeat(32)),
            format!("0x{}", "11".repeat(32)),
        ] {
            s.vote.commitment = commitment;
            assert!(next_step(&s, Eligibility::NotOpen).starts_with("Draw"));
            s.source.number = 351;
            assert!(next_step(&s, Eligibility::NotOpen).starts_with("Draw target expired"));
            s.source.number = 101;
        }
        s.case.outcome_seed_block = 0;
        s.case.phase_deadline = 999;
        assert!(next_step(&s, Eligibility::NotOpen).contains("Close reveal and advance"));
    }
    #[test]
    fn compact_draw_cue_keeps_public_progress_separate_from_personal_status() {
        let mut s = snapshot();
        s.case.phase = 3;
        s.case.outcome_seed_block = 100;
        for height in [99, 100] {
            s.source.number = height;
            assert!(draw_phase_note(&s).unwrap().contains("not open yet"));
        }
        s.source.number = 101;
        assert!(draw_phase_note(&s).unwrap().contains("Anyone may draw"));
        assert!(own_duty(&s, Eligibility::NotOpen).contains("No on-chain vote"));
        record_vote(&mut s);
        s.vote.revealed = 1;
        assert!(own_duty(&s, Eligibility::NotOpen).contains("Your vote is revealed"));
        assert!(draw_phase_note(&s).unwrap().contains("Anyone may draw"));
        s.vote.settled = true;
        assert!(own_duty(&s, Eligibility::NotOpen).contains("Your vote is settled"));
        s.source.number = 349;
        assert!(draw_phase_note(&s)
            .unwrap()
            .contains("One later valid block"));
        s.source.number = 350;
        assert!(draw_phase_note(&s).unwrap().contains("already observed"));
        assert_eq!(draw_request_hold(&s), Some("DRAW_WINDOW_EXHAUSTED_AT_READ"));
        s.source.number = 351;
        assert!(draw_phase_note(&s)
            .unwrap()
            .contains("Recovery support was not verified"));
        assert_eq!(draw_request_hold(&s), Some("DRAW_TARGET_EXPIRED"));
        s.case.outcome_seed_block = 0;
        assert!(draw_phase_note(&s).is_none());
    }
    #[test]
    fn participation_reasons_follow_checked_commit_refusal_and_freeze_boundary() {
        let mut s = snapshot();
        assert!(participation_block(&s, Eligibility::Selected).is_none());
        s.moderator.staked = false;
        assert_eq!(
            participation_block(&s, Eligibility::NotSelected),
            Some(ParticipationBlock::InactiveStake)
        );
        s.moderator.staked = true;
        s.moderator.frozen_until = s.source.timestamp + 1;
        assert_eq!(
            participation_block(&s, Eligibility::Selected),
            Some(ParticipationBlock::FrozenStake)
        );
        assert!(
            participation_note(ParticipationBlock::FrozenStake, "checked UTC time")
                .contains("checked UTC time")
        );
        s.moderator.frozen_until = s.source.timestamp;
        assert!(participation_block(&s, Eligibility::Selected).is_none());
        assert_eq!(
            participation_block(&s, Eligibility::NotSelected),
            Some(ParticipationBlock::NotSelected)
        );
        assert_eq!(
            participation_block(&s, Eligibility::SeedUnavailable),
            Some(ParticipationBlock::SeedUnavailable)
        );
        s.schedule.deadline_a = 1500;
        s.case.commits_a = 2;
        assert_eq!(
            participation_block(&s, Eligibility::Selected),
            Some(ParticipationBlock::ScheduleUnavailable)
        );
    }
    #[test]
    fn stake_and_selection_blocks_never_replace_recorded_reveal_or_settlement() {
        let mut s = snapshot();
        record_vote(&mut s);
        for staked in [false, true] {
            s.moderator.staked = staked;
            s.moderator.frozen_until = s.source.timestamp + 3600;
            for eligibility in [Eligibility::NotSelected, Eligibility::SeedUnavailable] {
                s.case.phase = 3;
                s.case.phase_deadline = 1500;
                assert!(participation_block(&s, eligibility).is_none());
                assert!(case_actions(&s, eligibility).allowed(Action::Reveal));
                assert!(own_duty(&s, eligibility).contains("reveal is due"));
                s.case.phase = 5;
                assert!(participation_block(&s, eligibility).is_none());
                assert!(case_actions(&s, eligibility).allowed(Action::Claim));
                assert!(own_duty(&s, eligibility).contains("Settle your recorded vote"));
            }
        }
        s.vote.commitment = format!("0x{}", "00".repeat(32));
        assert!(participation_block(&s, Eligibility::NotOpen).is_none());
    }
    #[test]
    fn report_exposes_the_unchanged_strict_budget_and_clock_allowance() {
        let mut f = snapshot();
        f.case.phase = 3;
        f.vote.commitment = format!("0x{}", "11".repeat(32));
        let timing = swarm_core::Timing {
            clock_error_seconds: 5,
            max_evidence_age_seconds: 30,
            max_head_lag_seconds: 30,
            inclusion_budget_seconds: 120,
        };
        for (deadline, remaining, ready) in [
            (1126, 121, true),
            (1125, 120, false),
            (1124, 119, false),
            (1005, 0, false),
        ] {
            f.case.phase_deadline = deadline;
            let mut h = f.clone();
            h.source.number += 1;
            let input = GuardInput {
                case_id: f.case_id,
                voter: "0x1111111111111111111111111111111111111111",
                commitment: &f.vote.commitment,
                expected_round: 0,
            };
            let result = check_reveal(&f, &h, &input, &timing, 1_000_000, 10);
            assert_eq!(result.ready, ready);
            assert_eq!(result.remaining_seconds, Some(remaining));
            let text = reveal_decision_text(
                result.ready,
                result.reason,
                result.remaining_seconds,
                120,
                5,
            );
            assert!(text.contains(&format!("{remaining} seconds")));
            assert!(text.contains("strictly greater"));
            assert!(text.contains("5-second clock allowance"));
        }
    }
    #[test]
    fn compact_reveal_summary_distinguishes_real_guard_results() {
        let mut f = snapshot();
        f.case.phase = 3;
        f.case.phase_deadline = 1500;
        f.vote.commitment = format!("0x{}", "11".repeat(32));
        let mut h = f.clone();
        h.source.number += 1;
        let input = GuardInput {
            case_id: f.case_id,
            voter: "0x1111111111111111111111111111111111111111",
            commitment: &f.vote.commitment,
            expected_round: 0,
        };
        let timing = swarm_core::Timing {
            clock_error_seconds: 5,
            max_evidence_age_seconds: 30,
            max_head_lag_seconds: 30,
            inclusion_budget_seconds: 120,
        };
        f.case.phase = 2;
        let result = check_reveal(&f, &h, &input, &timing, 1_000_000, 10);
        assert!(!result.ready);
        assert!(reveal_summary(result.ready, result.reason).starts_with("Finalized evidence"));
        f.case.phase = 3;
        h.case.phase = 2;
        let result = check_reveal(&f, &h, &input, &timing, 1_000_000, 10);
        assert!(!result.ready);
        assert!(reveal_summary(result.ready, result.reason).starts_with("Current evidence"));
        h.case.phase = 3;
        for (deadline, term) in [
            (1126, "this check only"),
            (1125, "Too little time"),
            (1005, "expired"),
        ] {
            f.case.phase_deadline = deadline;
            h.case.phase_deadline = deadline;
            let result = check_reveal(&f, &h, &input, &timing, 1_000_000, 10);
            let summary = reveal_summary(result.ready, result.reason);
            assert!(summary.contains(term));
            if result.ready {
                assert!(summary.contains("repeats the guards"));
            } else {
                assert!(summary.contains("Keep recovery"));
            }
        }
    }
    #[test]
    fn compact_reveal_failures_give_local_guidance_without_raw_error_codes() {
        for (reason, term) in [
            ("HEAD_STALE", "Refresh"),
            ("EVIDENCE_STALE", "Refresh"),
            ("CLOCK_INVALID", "device clock"),
            ("SNAPSHOT_INVALID", "Source evidence"),
            ("SOURCE_BLOCK_CHANGED", "RPC connection"),
            ("ROUND_CHANGED", "context changed"),
            ("COMMITMENT_CHANGED", "context changed"),
            ("CONTEXT_CHANGED", "context changed"),
            ("SECRET_NOT_FOUND", "restore"),
            ("VOTE_REVEALED", "already revealed"),
            ("VOTE_SETTLED", "already settled"),
        ] {
            let summary = reveal_summary(false, reason);
            assert!(summary.contains(term));
            assert!(!summary.contains(reason));
            assert!(!summary.contains("Passed"));
        }
        let unknown = "Unrecognized provider text must not become compact UI copy";
        assert_eq!(
            reveal_summary(false, unknown),
            "Readiness could not be established. Inspect the check details."
        );
    }
    #[test]
    fn cached_hash_has_no_draw_deadline_and_expiry_has_a_safe_route() {
        let mut s = snapshot();
        s.case.phase = 3;
        s.case.outcome_seed_block = 100;
        s.outcome_recovery = Some(OutcomeRecovery {
            original_hash: format!("0x{}", "ab".repeat(32)),
            recover_until: 8291,
            expired: false,
        });
        s.source.number = 50000;
        assert_eq!(draw_window(&s), DrawWindow::Open);
        assert_eq!(draw_request_hold(&s), None);
        assert!(next_step(&s, Eligibility::NotOpen).contains("no draw expiry"));
        assert!(draw_phase_note(&s).unwrap().contains("no expiry"));
        s.outcome_recovery.as_mut().unwrap().original_hash = format!("0x{}", "00".repeat(32));
        assert!(next_step(&s, Eligibility::NotOpen).starts_with("Complete the expired draw"));
        s.case.phase = 5;
        s.case.challenges = 1;
        s.outcome_recovery.as_mut().unwrap().expired = true;
        assert!(draw_phase_note(&s)
            .unwrap()
            .contains("do not prove responsibility"));
    }
}
