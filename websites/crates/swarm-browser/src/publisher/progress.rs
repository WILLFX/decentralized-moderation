//! Advisory task state. Every send still performs the original fresh checks.
use super::*;
use crate::token_amounts;

#[derive(Clone)]
pub(super) struct FundingRead {
    pub minimum: Uint256,
    pub balance: Uint256,
    pub allowance: Uint256,
    pub source: Value,
}
#[derive(Default)]
struct Ready {
    profile: bool,
    candidate: bool,
    content: bool,
    connected: bool,
    draft: bool,
    guidelines: bool,
    ack: bool,
    uploaded: bool,
    upload_config: bool,
    funds: bool,
    fee: bool,
    balance: bool,
    allowance: bool,
    journal: bool,
    approval_open: bool,
    submission_open: bool,
    submitted: bool,
    resubmit: bool,
}
struct Plan {
    next: &'static str,
    approve: bool,
    submit: bool,
}
fn plan(r: &Ready) -> Plan {
    let next = if !r.profile && r.candidate {
        "Review the candidate's chain, contract addresses and fingerprint against your trusted deployment source. Accept the reviewed profile before connecting."
    } else if !r.profile {
        "Load the publisher profile for the deployment you intend to use. You can write and save a draft before connecting a wallet."
    } else if !r.connected {
        "Connect wallet on the selected chain. This asks for your account; it does not approve spending or submit a publication."
    } else if r.approval_open {
        "Check the saved fee approval receipt. A sufficient allowance does not clear an unresolved wallet request. Use transaction recovery if its hash is missing or replaced."
    } else if r.submission_open {
        "Check the saved submission receipt. Do not submit again while the earlier request is unresolved."
    } else if r.submitted && !r.resubmit {
        "The matching submission is confirmed. Open it in My publications to check moderation and current listing status. To submit the same publication again, explicitly choose deliberate resubmission below; this pays another fee."
    } else if !r.content {
        "Upload or identify the intended content, inspect it through a checked copy or separate viewer, then acknowledge this exact reference before metadata upload or payment."
    } else if !r.draft {
        "Complete the publication fields, then preview the exact metadata."
    } else if !r.guidelines {
        "Load the pinned guidelines, read them and compare them with the exact metadata."
    } else if !r.ack {
        "Review the exact metadata and verified guidelines, then tick the review acknowledgement."
    } else if !r.upload_config {
        "This profile has no metadata upload settings. Obtain the endpoint and postage batch for your Bee node before uploading."
    } else if !r.uploaded {
        "Upload and verify the reviewed metadata. This uploads metadata, not the content itself."
    } else if !r.funds {
        "Refresh the fee, token balance and allowance before choosing the payment step."
    } else if !r.fee {
        "Choose the current minimum fee or enter a valid fee at least as large as that minimum."
    } else if !r.balance {
        "The token balance is below the selected fee. Fund this account with the selected token, then refresh balances."
    } else if !r.journal {
        "Resolve the saved-history or capacity problem before another wallet request. Open transaction recovery to see capacity, export records or archive verified resolved records. Keep uncertain requests."
    } else if !r.allowance {
        "Approve the exact selected fee. Approval grants spending permission; it does not pay the fee or submit your publication."
    } else {
        "Allowance covers the selected fee. Submit explicitly to pay that fee and enter moderation. The wallet estimates network gas separately."
    };
    let common = r.profile
        && r.connected
        && r.content
        && r.draft
        && r.guidelines
        && r.ack
        && r.uploaded
        && r.upload_config
        && r.funds
        && r.fee
        && r.balance
        && r.journal
        && !r.approval_open
        && !r.submission_open
        && (!r.submitted || r.resubmit);
    Plan {
        next,
        approve: common && !r.allowance,
        submit: common && r.allowance,
    }
}
pub(super) fn amount(a: &Rc<RefCell<App>>) -> Result<Uint256> {
    let s = a.borrow();
    let p = s.profile.as_ref().ok_or("PROFILE_REQUIRED")?;
    token_amounts::parse(&value("fee"), p.display.as_ref())
}
fn enabled(id: &str, yes: bool) {
    if yes {
        el(id).remove_attribute("disabled").unwrap();
    } else {
        el(id).set_attribute("disabled", "").unwrap();
    }
}
fn unresolved(r: &Value) -> bool {
    !["confirmed", "failed", "cancelled", "rejected"].contains(&r["state"].as_str().unwrap_or(""))
}
fn matches(r: &Value, d: &Draft) -> bool {
    r["action"] == "submit"
        && r["intent"]["contentHash"] == d.content_hash
        && r["intent"]["metaHash"] == d.meta_hash
        && r["intent"]["topics"] == json!(d.topic_keys)
}
fn latest<'a>(records: &'a [Value], action: &str) -> Option<&'a Value> {
    records
        .iter()
        .rev()
        .find(|r| r["action"] == action && unresolved(r))
        .or_else(|| records.iter().rev().find(|r| r["action"] == action))
}
fn hash(record: &Value) -> Option<&str> {
    record["resolution"]["hash"]
        .as_str()
        .or(record["candidateHash"].as_str())
        .or(record["hash"].as_str())
}
pub(super) async fn refresh_funds(a: &Rc<RefCell<App>>) -> Result<()> {
    a.borrow_mut().funding = None;
    let (p, who, epoch) = context(a)?;
    wallet::check(p.deployment.chain_id, &who).await?;
    let c = io::begin(&p).await?;
    let (minimum, balance, allowance) = io::funds(&p, &c, &who).await?;
    io::finish(&p, &c).await?;
    wallet::check(p.deployment.chain_id, &who).await?;
    active(a, epoch)?;
    a.borrow_mut().funding = Some(FundingRead {
        minimum,
        balance,
        allowance,
        source: c.source,
    });
    text("funds-feedback", success("funds"));
    Ok(())
}
pub(super) async fn check_latest(a: &Rc<RefCell<App>>, action: &str) -> Result<()> {
    let (p, who, _) = context(a)?;
    let records = history::load_current(a, &p, &who)?;
    let r = latest(&records, action).ok_or("SAVED_REQUEST_NOT_FOUND")?;
    let h = hash(r).ok_or("REQUEST_HASH_REQUIRED")?;
    input("txhash").set_value(h);
    a.borrow_mut().recovery_target = Some(recovery::identity(r));
    let _ = recovery::check(a).await?;
    after_receipt(a).await;
    Ok(())
}
pub(super) async fn after_receipt(a: &Rc<RefCell<App>>) {
    let Ok((p, who, _)) = context(a) else { return };
    let Ok(records) = history::load_current(a, &p, &who) else {
        return;
    };
    if records.iter().any(|r| {
        r["action"] == "approve"
            && r["state"] == "confirmed"
            && hash(r) == Some(value("txhash").as_str())
    }) {
        if let Err(code) = refresh_funds(a).await {
            text("funds-feedback",&format!("The approval receipt was checked, but the current allowance could not be refreshed. Refresh fee and balances before submitting. Details: {code}"));
        }
    }
}
pub(super) fn minimum(a: &Rc<RefCell<App>>) -> Result<()> {
    let s = a.borrow();
    let p = s.profile.as_ref().ok_or("PROFILE_REQUIRED")?;
    let f = s.funding.as_ref().ok_or("FUNDING_READ_REQUIRED")?;
    input("fee").set_value(&token_amounts::decimal(
        f.minimum,
        p.display.as_ref().map(|d| d.decimals).unwrap_or(0),
    ));
    Ok(())
}
pub(super) fn network(chain: u64) -> String {
    match chain {
        10200 => format!("Chiado (chain {chain})"),
        1 => format!("Ethereum (chain {chain})"),
        100 => format!("Gnosis (chain {chain})"),
        11155111 => format!("Sepolia (chain {chain})"),
        _ => format!("Chain {chain}"),
    }
}
pub(super) fn success(action: &str) -> &'static str {
    match action {
        "funds"=>"Current minimum fee, token balance and allowance refreshed below. Your chosen fee was kept.",
        "minimum"=>"The chosen fee now equals the current minimum. Review its readable amount and exact base units below.",
        "guidelines"=>"Pinned guidelines verified. Open the guidelines text and review it with the exact metadata before acknowledging.",
        "connect"=>"Wallet account connected on the selected chain. Continue with the publisher prerequisites.",
        _=>"Action finished. Read its result and the next step below.",
    }
}
pub(super) fn explain(a: &Rc<RefCell<App>>, code: &str, fallback: &str) -> String {
    if code == "WALLET_SELECTION_REQUIRED" {
        return "Choose the wallet you want to connect.".into();
    }
    let help=match code {
        "INVALID_FEE_AMOUNT"=>"Enter the publication fee as a plain nonnegative decimal within the profile's precision. Do not use commas or exponents. The exact base-unit amount appears below the field.",
        "FEE_OVERFLOW"=>"The selected fee exceeds the contract's amount limit. Choose a smaller fee; the application never rounds or truncates it.",
        "FEE_TOO_LOW"=>"The chosen fee is below the current minimum. Refresh fee and balances, then choose the minimum or enter a higher fee.",
        "INSUFFICIENT_BALANCE"=>"This account does not have enough of the selected token for the fee. Fund it and refresh balances. Native gas is separate.",
        "INSUFFICIENT_ALLOWANCE"=>"Current permission is below the selected fee. Refresh balances, then approve the exact selected fee and check its receipt before submitting.",
        "APPROVAL_NOT_NEEDED"=>"Allowance already covers this fee. No new approval was requested. Submit explicitly after checking the other prerequisites.",
        "METADATA_UPLOAD_REQUIRED"=>"Preview, review and upload the exact metadata before requesting a payment. A context or authoring change clears upload readiness.",
        "GUIDELINES_ACK_REQUIRED"=>"Load and review the verified guidelines with the exact metadata, then tick the review acknowledgement.",
        "DRAFT_REQUIRED"=>"Complete the publication fields and preview the exact metadata first.",
        "PROFILE_REQUIRED"=>"Choose the publisher JSON profile for the intended deployment. Your authoring text has been kept.",
        "INVALID_CONFIG"|"CONFIG_TOO_LARGE"|"INVALID_UPLOAD_CONFIG"=>"This file is not a usable publisher profile. Select the correct current profile; the previous configuration is no longer active. Your authoring text has been kept.",
        "CONNECT_WALLET"|"WALLET_ACCOUNT_CHANGED"=>"Connect or refresh the intended account. Previous review and funding evidence must be checked again after a wallet change.",
        "WALLET_EVENT_CLEANUP_FAILED"=>"The previous wallet connection could not be cleaned up. Reload before connecting again; keep your saved requests and recovery files.",
        "WALLET_EVENTS_UNAVAILABLE"|"WALLET_EVENT_REGISTRATION_FAILED"=>"The wallet connection could not be monitored safely. Reconnect or use another compatible browser wallet.",
        "WALLET_UNAVAILABLE"|"WALLET_PROVIDER_UNSUPPORTED"=>"Open this page in a browser with a compatible Ethereum wallet enabled, then connect your intended account.",
        "WALLET_CHAIN_CHANGED"=>return format!("Your wallet reports {}. Select {} in your wallet, then connect again. This check did not prepare a transaction.",a.borrow().wallet_chain.map(network).unwrap_or_else(||"a different chain".into()),a.borrow().profile.as_ref().map(|p|network(p.deployment.chain_id)).unwrap_or_else(||"the profile's chain".into())),
        "AUTHOR_FIELDS_INVALID"=>"Correct the highlighted fields, then preview again. Your entered values have been kept.",
        "CONTENT_INSPECTION_REQUIRED"=>"Inspect the current content and acknowledge it before metadata upload or payment. The content section provides checked downloads and a separate viewer.",
        "PROFILE_TRUST_ACK_REQUIRED"|"PROFILE_CANDIDATE_REQUIRED"=>"Load a profile candidate, compare its chain, addresses and fingerprint with the source you trust, then acknowledge and activate it. Nothing is accepted automatically.",
        "PROFILE_FINGERPRINT_REQUIRED"|"PROFILE_FINGERPRINT_MISMATCH"=>"The profile fingerprint is missing or does not match the supplied file bytes. No candidate was accepted. Check the expected fingerprint against your trusted deployment source.",
        "PUBLIC_PROFILE_URL_REQUIRED"=>"Use a public HTTPS profile URL, or loopback HTTP for your local service. Do not put private credentials or query access tokens in a shared setup link.",
        "PUBLIC_PROFILE_CONTAINS_ACCESS_SETTINGS"=>"The fetched profile contains private access settings. Obtain a public setup profile; local authorization and private RPC query settings must be loaded from your own file.",
        "REQUEST_HASH_REQUIRED"=>"The saved request has no returned hash. Use transaction recovery and wallet activity to find its original, replacement or cancellation hash. Do not resend it.",
        "FUNDING_READ_REQUIRED"=>"Refresh the current fee, balance and allowance before choosing the minimum.",
        "INVALID_REFERENCE"=>"Enter the content's nonzero 64-digit hexadecimal Swarm reference, with an optional 0x prefix. A filename or gateway URL is not a reference.",
        "UPLOAD_CONFIG_REQUIRED"=>"This profile has no metadata upload endpoint and postage batch. Obtain the publisher upload settings for your Bee node before continuing.",
        "RPC_ERROR"|"RPC_READ_FAILED"|"INVALID_RPC_RESPONSE"|"RESOURCE_READ_FAILED"|"RESOURCE_UNAVAILABLE"|"HTTP_ERROR"|"RPC_HTTP_ERROR"|"TIMEOUT"=>"The selected service did not return usable evidence. No payment was prepared by this check. Refresh the relevant task when the service is available; keep any earlier uncertain wallet request.",
        _=>return fallback.into(),
    };
    format!("{help}\nDetails: {code}")
}
pub(super) fn render(a: &Rc<RefCell<App>>) {
    wallet::render_picker("wallet-picker", a.borrow().busy);
    let (p, connected, draft, guidelines, uploaded, funding, busy) = {
        let s = a.borrow();
        (
            s.profile.clone(),
            s.account.is_some(),
            s.draft.clone(),
            s.guidelines,
            s.uploaded,
            s.funding.clone(),
            s.busy,
        )
    };
    let result = context(a).and_then(|(p, who, _)| history::load_current(a, &p, &who));
    let records = result.as_deref().unwrap_or(&[]);
    let approval = latest(records, "approve");
    let submission = latest(records, "submit");
    let selected = amount(a).ok();
    let ready = Ready {
        profile: p.is_some(),
        candidate: a.borrow().setup_candidate.is_some(),
        content: content::ready(a),
        connected,
        draft: draft.is_some(),
        guidelines,
        ack: input("ack").checked(),
        uploaded,
        upload_config: a.borrow().upload.is_some(),
        funds: funding.is_some(),
        fee: funding
            .as_ref()
            .zip(selected)
            .is_some_and(|(f, n)| n >= f.minimum),
        balance: funding
            .as_ref()
            .zip(selected)
            .is_some_and(|(f, n)| f.balance >= n),
        allowance: funding
            .as_ref()
            .zip(selected)
            .is_some_and(|(f, n)| f.allowance >= n),
        journal: result.is_ok()
            && context(a).is_ok_and(|(p, who, _)| !history::has_fault(a, &p, &who))
            && archive::room(a),
        approval_open: records
            .iter()
            .any(|r| r["action"] == "approve" && unresolved(r)),
        submission_open: records.iter().any(|r| {
            r["action"] == "submit" && draft.as_ref().is_none_or(|d| matches(r, d)) && unresolved(r)
        }),
        submitted: records
            .iter()
            .any(|r| r["state"] == "confirmed" && draft.as_ref().is_some_and(|d| matches(r, d))),
        resubmit: input("resubmit").checked(),
    };
    let plan = plan(&ready);
    let next = if busy {
        "An action is running. Its controls are locked. Read its status beside the active task; review any open request in wallet."
    } else {
        plan.next
    };
    text("publisher-next", next);
    text("payment-next", next);
    let list = el("publisher-steps");
    list.set_text_content(None);
    let completed = ready.submitted && !ready.resubmit;
    for (done, description) in [
        (ready.profile, "Select deployment profile"),
        (ready.connected, "Connect intended wallet account"),
        (ready.content, "Inspect the exact content reference"),
        (ready.draft, "Preview exact metadata"),
        (
            ready.guidelines && ready.ack,
            "Review pinned guidelines and metadata",
        ),
        (ready.uploaded, "Upload and verify metadata"),
        (
            completed || ready.funds && ready.fee && ready.balance,
            "Choose fee and check token balance",
        ),
        (
            completed || ready.allowance && !ready.approval_open,
            "Check allowance and any approval receipt",
        ),
        (completed, "Verify submission receipt"),
    ] {
        let row = doc().create_element("li").unwrap();
        row.set_text_content(Some(&format!(
            "{} — {description}",
            if done { "Done" } else { "To do" }
        )));
        list.append_child(&row).unwrap();
    }
    if let Some(p) = &p {
        let rpc_origin = web_sys::Url::new(&p.rpc_url)
            .map(|url| url.origin())
            .unwrap_or_else(|_| "Unavailable".into());
        text("config",&format!("{}\nModeration and allowance spender: {}\nToken: {}\nRPC origin: {}\nUpload credentials stay in memory only.",network(p.deployment.chain_id),p.deployment.moderation.address,p.deployment.token.address,rpc_origin));
        text(
            "fee-label",
            &p.display
                .as_ref()
                .map(|d| format!("Publication fee ({})", d.symbol))
                .unwrap_or_else(|| "Publication fee (integer base units)".into()),
        );
        text("token-context",&p.display.as_ref().map(|d|format!("Readable amounts use this profile's {} label and {} decimal places. The pinned token address above identifies the token; labels are not token identity. Exact base units are shown with each amount.",d.symbol,d.decimals)).unwrap_or_else(||"This profile has no token display settings. Amounts stay in exact integer base units; no decimal places or symbol are assumed.".into()));
        text("fee-exact",&match selected {Some(n)=>format!("Selected fee: {}. Ordinary refreshes keep your chosen fee.",token_amounts::describe(n,p.display.as_ref())),None=>"Enter a plain nonnegative decimal amount within this token's precision, or choose the current minimum. Exponents and commas are not accepted.".into()});
        if let Some(f) = &funding {
            let height =
                crate::transport::quantity(f.source["number"].as_str().unwrap_or("")).unwrap_or(0);
            text("funds",&format!("Minimum publication fee: {}\nYour token balance: {}\nCurrent allowance to moderation: {}\nRead at block {height}. These values are a snapshot; every wallet request checks them again.",token_amounts::describe(f.minimum,p.display.as_ref()),token_amounts::describe(f.balance,p.display.as_ref()),token_amounts::describe(f.allowance,p.display.as_ref())));
        } else {
            text("funds","No current fee, balance or allowance read for this context. Refresh before preparing a payment.");
        }
    } else {
        text("fee-label", "Publication fee");
        text("fee-exact", "");
        text("token-context","No publisher profile is active. Load the intended profile before choosing a token fee.");
        text(
            "funds",
            "No current fee, balance or allowance read for this context.",
        );
    }
    for (id, yes) in [
        ("connect", ready.profile),
        ("readfunds", ready.profile && connected),
        ("paymentfunds", ready.profile && connected),
        ("useminimum", funding.is_some()),
        ("fee", ready.profile),
        ("loadguidelines", connected && ready.draft),
        ("ack", ready.draft && guidelines),
        (
            "upload",
            connected
                && ready.content
                && ready.draft
                && guidelines
                && ready.ack
                && ready.upload_config
                && !uploaded,
        ),
        ("approve", plan.approve),
        ("submit", plan.submit),
        (
            "resubmit",
            ready.submitted && !ready.approval_open && !ready.submission_open,
        ),
        (
            "approvalreceipt",
            approval.is_some_and(|r| hash(r).is_some()),
        ),
        (
            "submissionreceipt",
            submission.is_some_and(|r| hash(r).is_some()),
        ),
        ("receipt", connected),
        ("history", connected),
        ("exporthistory", connected),
        ("savehistory", connected),
        ("importhistory", connected),
        ("readcase", connected),
        ("loadowned", connected),
        (
            "refund",
            connected && a.borrow().refund_ready && archive::room(a),
        ),
    ] {
        enabled(id, !busy && yes);
    }
    text(
        "approval-note",
        if ready.submitted && !ready.resubmit {
            "This submission is confirmed. It needs no further fee approval."
        } else if ready.approval_open {
            "An approval request is unresolved. Check its receipt here, or use recovery for a missing, speed-up or cancellation hash. No automatic resend."
        } else if ready.allowance {
            "Allowance covers the selected fee at the last read. No new approval is needed. Submitting still requires your explicit action and a fresh check."
        } else {
            "Approval grants permission to the moderation contract for exactly the selected fee. It does not transfer the fee or submit a publication."
        },
    );
    text(
        "submission-note",
        if ready.submission_open {
            "A submission is unresolved. Check its receipt before sending again."
        } else if ready.submitted && !ready.resubmit {
            "Matching submission confirmed. Continue in My publications; approval alone never creates a case."
        } else {
            "Submit pays the selected token fee and requests moderation. After broadcast, check the submission receipt here to obtain the verified case ID."
        },
    );
    setup::render(a);
    content::render(a);
    validation::fee(a);
    archive::render(a);
    a.borrow_mut().journey.readiness = journey::ReviewState {
        approve: plan.approve,
        submit: plan.submit,
        approval_open: ready.approval_open,
        submission_open: ready.submission_open,
        submitted: ready.submitted,
        journal: ready.journal,
    };
    if ready.profile && ready.connected && !ready.journal {
        let _ = el("history-maintenance").set_attribute("open", "");
    }
    journey::render(a);
}

#[cfg(test)]
mod tests {
    use super::*;
    fn reviewed() -> Ready {
        Ready {
            profile: true,
            content: true,
            connected: true,
            draft: true,
            guidelines: true,
            ack: true,
            uploaded: true,
            upload_config: true,
            funds: true,
            fee: true,
            balance: true,
            journal: true,
            ..Ready::default()
        }
    }
    #[test]
    fn existing_allowance_skips_approval_but_uncertain_approval_still_blocks() {
        let mut r = reviewed();
        r.allowance = true;
        assert!(plan(&r).submit);
        assert!(!plan(&r).approve);
        r.approval_open = true;
        assert!(!plan(&r).submit);
        assert!(plan(&r).next.contains("receipt"));
        r.approval_open = false;
        r.allowance = false;
        assert!(plan(&r).approve);
        assert!(!plan(&r).submit);
    }
    #[test]
    fn fresh_checks_and_exact_review_are_required_after_context_changes() {
        let mut r = reviewed();
        r.allowance = true;
        r.funds = false;
        assert!(!plan(&r).submit);
        r.funds = true;
        r.ack = false;
        assert!(!plan(&r).submit);
        r.ack = true;
        r.journal = false;
        assert!(!plan(&r).submit);
        r.journal = true;
        r.submitted = true;
        assert!(!plan(&r).submit);
        assert!(plan(&r).next.contains("My publications"));
        r.resubmit = true;
        assert!(plan(&r).submit);
        r.submission_open = true;
        assert!(!plan(&r).submit);
        assert!(plan(&r).next.contains("receipt"));
        assert!(plan(&Ready::default()).next.contains("save a draft"));
    }
}
