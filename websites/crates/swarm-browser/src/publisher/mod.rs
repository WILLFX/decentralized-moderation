//! Publisher UI: exact metadata bytes, pinned reads and explicit wallet actions.
mod archive;
mod authoring;
mod content;
mod history;
mod io;
mod journey;
mod ledger;
mod presentation;
mod progress;
mod publications;
mod recovery;
mod setup;
mod transfers;
mod validation;
use crate::{
    transport::{as_str, rpc},
    wallet, BrowserResult as Result,
};
use serde_json::{json, Value};
use std::{cell::RefCell, rc::Rc};
use swarm_core::{
    moderator::Uint256,
    publisher::{create_draft, encode_approve, encode_submit, fee, AuthorFields, Draft},
    ModeratorProfile,
};
use wasm_bindgen::{prelude::*, JsCast};
use wasm_bindgen_futures::{spawn_local, JsFuture};
use web_sys::{Element, HtmlInputElement};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    PrepareArchive,
    VerifyArchive,
    CommitArchive,
    HistoryPrevious,
    HistoryNext,
    PublicationPrevious,
    PublicationNext,
    LoadProfile,
    SelectVersion,
    FetchProfile,
    UseProfile,
    SelectContent,
    ApplyBee,
    UploadContent,
    CheckContent,
    DownloadContent,
    Connect,
    ReadFunds,
    UseMinimum,
    UseMimeType,
    CheckApprovalReceipt,
    CheckSubmissionReceipt,
    PreviewDraft,
    LoadGuidelines,
    UploadMetadata,
    Approve,
    Submit,
    ReadCase,
    ReadOwned,
    Refund,
    CheckReceipt,
    ReadHistory,
    ExportDraft,
    ImportDraft,
    ExportHistory,
    SaveHistory,
    ImportHistory,
    OpenPublication,
}

impl Action {
    fn is_archive(self) -> bool {
        matches!(
            self,
            Self::PrepareArchive | Self::VerifyArchive | Self::CommitArchive
        )
    }
    fn is_content(self) -> bool {
        matches!(
            self,
            Self::SelectContent
                | Self::ApplyBee
                | Self::UploadContent
                | Self::CheckContent
                | Self::DownloadContent
        )
    }
    fn is_authoring_file(self) -> bool {
        matches!(self, Self::ExportDraft | Self::ImportDraft)
    }
    fn writes_history(self) -> bool {
        matches!(
            self,
            Self::Approve
                | Self::Submit
                | Self::Refund
                | Self::CheckReceipt
                | Self::CheckApprovalReceipt
                | Self::CheckSubmissionReceipt
                | Self::OpenPublication
                | Self::ImportHistory
                | Self::SaveHistory
                | Self::CommitArchive
        )
    }
    fn working_message(self) -> &'static str {
        match self {
            Self::Approve
            | Self::Submit
            | Self::Refund
            | Self::CheckReceipt
            | Self::ReadHistory
            | Self::OpenPublication => "Working… Check the saved request and wallet status below.",
            Self::Connect => "Working… Review the open wallet request in wallet.",
            _ => "Working… Wait for this check to finish.",
        }
    }
    fn success_message(self) -> &'static str {
        match self {
            Self::ReadFunds => "Current minimum fee, token balance and allowance refreshed below. Your chosen fee was kept.",
            Self::UseMinimum => "The chosen fee now equals the current minimum. Review its readable amount and exact base units below.",
            Self::LoadGuidelines => "Pinned guidelines verified. Open the guidelines text and review it with the exact metadata before acknowledging.",
            Self::Connect => "Wallet account connected on the selected chain. Continue with the publisher prerequisites.",
            _ => "Action finished. Read its result and the next step below.",
        }
    }
}

struct Outcome {
    message: String,
    notice: Option<String>,
}

struct ActionFailure {
    code: &'static str,
    message: Option<String>,
}

impl From<&'static str> for ActionFailure {
    fn from(code: &'static str) -> Self {
        Self {
            code,
            message: None,
        }
    }
}

type ActionResult<T = Outcome> = std::result::Result<T, ActionFailure>;

#[derive(Default)]
struct App {
    journey: journey::State,
    wallet_subscriptions: wallet::Subscriptions,

    journal: Rc<history::Journal>,
    profile: Option<ModeratorProfile>,
    upload: Option<Value>,
    account: Option<String>,
    draft: Option<Draft>,
    uploaded: bool,
    guidelines: bool,
    epoch: u64,
    busy: bool,
    recovery_target: Option<String>,
    authoring_storage_blocked: bool,
    publication_target: Option<String>,
    refund_ready: bool,
    funding: Option<progress::FundingRead>,
    setup_candidate: Option<setup::Candidate>,
    setup_accepted: Option<setup::Candidate>,
    content: content::ContentState,
    validation_shown: bool,
    wallet_chain: Option<u64>,
    archive_candidate: Option<archive::Prepared>,
    history_page: usize,
    publication_page: usize,
}
fn doc() -> web_sys::Document {
    web_sys::window().unwrap().document().unwrap()
}
fn journal(a: &Rc<RefCell<App>>) -> Rc<history::Journal> {
    a.borrow().journal.clone()
}
fn el(id: &str) -> Element {
    doc().get_element_by_id(id).unwrap()
}
fn text(id: &str, v: &str) {
    el(id).set_text_content(Some(v));
}
fn input(id: &str) -> HtmlInputElement {
    el(id).dyn_into().unwrap()
}
fn area(id: &str) -> web_sys::HtmlTextAreaElement {
    el(id).dyn_into().unwrap()
}
fn authoring_fields() -> AuthorFields {
    let topics = area("topics")
        .value()
        .lines()
        .filter(|line| {
            !js_sys::JsString::from(*line)
                .trim()
                .as_string()
                .unwrap_or_default()
                .is_empty()
        })
        .map(str::to_owned)
        .collect();
    AuthorFields {
        entry_type: value("entrytype"),
        title: value("title"),
        description: area("description").value(),
        topics,
        language: value("language"),
        content_type: value("contenttype"),
        source: value("source"),
    }
}
fn authoring_metadata() -> Result<Value> {
    authoring_fields().metadata().map_err(|e| e.0)
}
fn value(id: &str) -> String {
    if ["entrytype", "mimechoice"].contains(&id) {
        el(id)
            .dyn_into::<web_sys::HtmlSelectElement>()
            .unwrap()
            .value()
    } else {
        input(id).value()
    }
}
fn invalidate(a: &Rc<RefCell<App>>) {
    for id in ["setup-feedback", "bee-feedback", "history-feedback"] {
        text(id, "");
    }
    content::clear(a);
    a.borrow_mut().funding = None;
    text("funds-feedback","Funding evidence cleared after the deployment or wallet context changed. Refresh before preparing a payment.");
    invalidate_review(a);
}
fn invalidate_review(a: &Rc<RefCell<App>>) {
    let mut s = a.borrow_mut();
    s.journal.context_changed();
    s.archive_candidate = None;
    s.history_page = 0;
    s.publication_page = 0;
    s.recovery_target = None;
    s.publication_target = None;
    s.refund_ready = false;
    s.epoch = s.epoch.wrapping_add(1);
    s.draft = None;
    s.uploaded = false;
    s.guidelines = false;
    input("ack").set_checked(false);
    input("resubmit").set_checked(false);
    text("archive-feedback","Archive context cleared. Existing transaction records are retained; prepare a new backup in the intended context.");
    for id in ["funds", "case", "owned", "guidelines"] {
        text(id, "Evidence cleared after context changed.");
    }
    text("preview", "Authoring text retained. Preview, upload and review evidence cleared. Preview exact metadata again before submitting.");
    el("request-list").set_text_content(None);
    text("selected-request", "No saved request selected.");
    text("selected-request-short", "Select a saved request to check.");
    el("publication-list").set_text_content(None);
    text(
        "publication-list-note",
        "Reconnect the intended account to read its saved submissions.",
    );
    text("publication-status","Current publication status cleared. Authoring text and saved submission history are retained.");
    text(
        "request-list-note",
        "Reconnect the intended account to read its saved requests.",
    );
    drop(s);
    journey::clear_publication(a);
    text("draft-feedback", "");
    text("transaction-feedback", "");
    presentation::pending(a);
    progress::render(a);
}
fn active(a: &Rc<RefCell<App>>, epoch: u64) -> Result<()> {
    if a.borrow().epoch != epoch {
        Err("CONTEXT_CHANGED")
    } else {
        Ok(())
    }
}
fn context(a: &Rc<RefCell<App>>) -> Result<(ModeratorProfile, String, u64)> {
    let s = a.borrow();
    Ok((
        s.profile.clone().ok_or("PROFILE_REQUIRED")?,
        s.account.clone().ok_or("CONNECT_WALLET")?,
        s.epoch,
    ))
}
fn bind(a: &Rc<RefCell<App>>, id: &str, action: Action, event: &str) {
    let state = a.clone();
    let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| dispatch(state.clone(), action));
    el(id)
        .add_event_listener_with_callback(event, cb.as_ref().unchecked_ref())
        .unwrap();
    cb.forget();
}
fn dispatch(a: Rc<RefCell<App>>, action: Action) {
    if a.borrow().busy {
        return;
    }
    let navigation_revision = a.borrow().journey.revision;
    let feedback = presentation::task_feedback(action, a.borrow().journey.view);
    {
        let mut state = a.borrow_mut();
        state.journey.notice_view = state.journey.view;
    }
    presentation::busy(&a, true);
    progress::render(&a);
    text("notice", "Working… Wait for this action to finish.");
    text(feedback, action.working_message());
    spawn_local(async move {
        let result = history::coordinated(&a, action).await;
        let succeeded = result.is_ok();
        let wallet_selection_required =
            matches!(&result, Err(error) if error.code == "WALLET_SELECTION_REQUIRED");
        presentation::busy(&a, false);
        match result {
            Err(error) => {
                let code = error.code;
                let message = if action == Action::ImportHistory && code == "FILE_REQUIRED" {
                    "Choose a saved public history JSON file before merging. Existing requests have been kept.\nDetails: FILE_REQUIRED".into()
                } else if action.is_content() {
                    error.message.unwrap_or_else(|| content::help(code))
                } else if action.is_authoring_file() {
                    format!("The authoring file could not be saved or loaded. Your current text has been kept. Check the selected file and try saving a draft file again.\nDetails: {code}")
                } else if action.is_archive()
                    || matches!(
                        action,
                        Action::Approve
                            | Action::Submit
                            | Action::Refund
                            | Action::CheckReceipt
                            | Action::ReadHistory
                            | Action::SaveHistory
                            | Action::ImportHistory
                            | Action::ExportHistory
                            | Action::OpenPublication
                    )
                {
                    presentation::error(code)
                } else {
                    code.to_owned()
                };
                let message = progress::explain(&a, code, &message);
                text("notice", &message);
                text(feedback, &message);
                if a.borrow().journey.revision == navigation_revision {
                    validation::action_error(action, code);
                }
                if action.is_authoring_file() {
                    text("authoring-note", &message);
                }
            }
            Ok(outcome) => {
                progress::render(&a);
                let message = if action == Action::ReadFunds && feedback == "setup-feedback" {
                    let s = a.borrow();
                    let height = s
                        .funding
                        .as_ref()
                        .and_then(|f| {
                            f.source["number"]
                                .as_str()
                                .and_then(|n| crate::transport::quantity(n).ok())
                        })
                        .unwrap_or(0);
                    format!(
                        "{}\nBlock {height} snapshot. Rechecked before payment.",
                        journey::review_cost(&s)
                    )
                } else if action == Action::ApplyBee && feedback == "bee-feedback" {
                    "Local Bee settings applied. Inspect content again before reviewing.".into()
                } else {
                    outcome.message
                };
                text(feedback, &message);
                text("notice", outcome.notice.as_deref().unwrap_or(&message));
            }
        }
        presentation::pending(&a);
        if context(&a).is_ok() {
            if let Err(code) = presentation::render_history(&a) {
                text("request-list-note", &presentation::error(code));
            }
            if let Err(code) = publications::render(&a) {
                text("publication-list-note", &presentation::error(code));
            }
        }
        progress::render(&a);
        let same_workspace = a.borrow().journey.revision == navigation_revision;
        if action == Action::PreviewDraft && same_workspace {
            validation::focus_first();
        }
        if same_workspace && action.is_archive() {
            let _ = el("archive-feedback")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
        if action == Action::UseMimeType && same_workspace {
            let _ = input("contenttype").focus();
        }
        journey::after_action(&a, action, succeeded, navigation_revision);
        if same_workspace && succeeded && action == Action::UseProfile && wallet::needs_selection()
        {
            let _ = el("wallet-picker")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
        if same_workspace && action == Action::Connect && wallet_selection_required {
            let _ = el("wallet-picker")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
        if same_workspace
            && (succeeded || action != Action::ApplyBee)
            && matches!(
                action,
                Action::ApplyBee
                    | Action::ReadFunds
                    | Action::ReadHistory
                    | Action::SaveHistory
                    | Action::ImportHistory
                    | Action::ExportHistory
            )
        {
            journey::open_ancestors(&el(feedback));
            let _ = el(feedback)
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
    });
}
async fn run(a: &Rc<RefCell<App>>, action: Action) -> ActionResult {
    let mut outcome = Outcome {
        message: action.success_message().into(),
        notice: None,
    };
    match action {
        Action::ExportDraft | Action::ImportDraft => authoring::transfer(a, action).await?,
        Action::UseMinimum => progress::minimum(a)?,
        Action::PrepareArchive => outcome.message = archive::prepare(a)?,
        Action::VerifyArchive => outcome.message = archive::verify(a).await?,
        Action::CommitArchive => outcome.message = archive::commit(a).await?,
        Action::HistoryPrevious | Action::HistoryNext => {
            let page = a.borrow().history_page;
            a.borrow_mut().history_page = if action == Action::HistoryPrevious {
                page.saturating_sub(1)
            } else {
                page.saturating_add(1)
            };
        }
        Action::PublicationPrevious | Action::PublicationNext => {
            let page = a.borrow().publication_page;
            a.borrow_mut().publication_page = if action == Action::PublicationPrevious {
                page.saturating_sub(1)
            } else {
                page.saturating_add(1)
            };
        }
        Action::UseMimeType => outcome.message = validation::apply_format(a)?,
        Action::SelectVersion => outcome.message = setup::choose_version(a)?,
        Action::CheckApprovalReceipt => {
            outcome.message = progress::check_latest(a, "approve").await?
        }
        Action::CheckSubmissionReceipt => {
            outcome.message = progress::check_latest(a, "submit").await?
        }
        Action::ExportHistory | Action::ImportHistory | Action::SaveHistory => {
            outcome.message = transfers::transfer(a, action).await?
        }
        Action::LoadProfile => outcome.message = setup::load(a, false).await?,
        Action::FetchProfile => outcome.message = setup::load(a, true).await?,
        Action::UseProfile => outcome.message = setup::accept(a)?,
        Action::SelectContent => outcome.message = content::selected(a),
        Action::ApplyBee => outcome.message = content::apply_bee(a)?,
        Action::UploadContent => outcome.message = content::upload(a).await?,
        Action::CheckContent => outcome.message = content::check(a).await?,
        Action::DownloadContent => outcome.message = content::download(a)?,
        Action::Connect => {
            let p = a.borrow().profile.clone().ok_or("PROFILE_REQUIRED")?;
            choose_wallet(a)?;
            install_events(a)?;
            invalidate(a);
            a.borrow_mut().account = None;
            let account = wallet::account(&wallet::read("eth_requestAccounts").await?)?;
            // Initial authorization may emit accountsChanged before resolving.
            // Later account/network changes still invalidate the checks below.
            let epoch = a.borrow().epoch;
            let chain = wallet::read("eth_chainId")
                .await?
                .as_string()
                .ok_or("INVALID_WALLET_CHAIN")?;
            a.borrow_mut().wallet_chain = Some(crate::transport::quantity(&chain)?);
            wallet::check(p.deployment.chain_id, &account).await?;
            active(a, epoch)?;
            text("wallet", &format!("Connected: {account}"));
            a.borrow_mut().account = Some(account);
        }
        Action::ReadFunds => {
            progress::refresh_funds(a).await?;
        }
        Action::LoadGuidelines => {
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            let c = io::begin(&p).await?;
            let url = if p.guidelines_url == "./MODERATION_GUIDELINES.md" {
                let loc = web_sys::window()
                    .unwrap()
                    .location()
                    .href()
                    .map_err(|_| "INVALID_LOCATION")?;
                web_sys::Url::new_with_base(&p.guidelines_url, &loc)
                    .map_err(|_| "INVALID_LOCATION")?
                    .href()
            } else {
                p.guidelines_url.clone()
            };
            let bytes = crate::transport::fetch(
                &url,
                &web_sys::RequestInit::new(),
                swarm_core::review::MAX_REVIEW_BYTES,
            )
            .await?;
            let body =
                swarm_core::review::verify_guideline_bytes(&bytes, &p.deployment.guidelines.hash)
                    .map_err(|e| e.0)?;
            io::finish(&p, &c).await?;
            active(a, epoch)?;
            text("guidelines", &body);
            a.borrow_mut().guidelines = true;
        }
        Action::PreviewDraft => {
            invalidate_review(a);
            if !validation::check(a, true) {
                return Err("AUTHOR_FIELDS_INVALID".into());
            }
            let mut metadata = authoring_metadata()?;
            // Preserve ECMAScript contextual Unicode lowercase (including final sigma).
            // Rust owns authoring and validation; the browser supplies its string semantics.
            let mut case_changes = Vec::new();
            if let Some(topics) = metadata["topics"].as_array_mut() {
                for topic in topics {
                    let original = topic.as_str().ok_or("INVALID_TOPICS")?.to_owned();
                    let lowered = js_sys::JsString::from(original.as_str())
                        .normalize("NFC")
                        .to_lower_case()
                        .normalize("NFC")
                        .as_string()
                        .ok_or("INVALID_TOPICS")?;
                    if original != lowered {
                        case_changes.push(format!("{} → {}", original, lowered));
                    }
                    *topic = json!(lowered);
                }
            }
            let mut draft = create_draft(&value("reference"), &metadata).map_err(|e| e.0)?;
            draft.changes.extend(case_changes);
            text(
                "preview",
                &format!(
                    "Content: {}\nMetadata: {}\nTopic changes: {}\nExact document:\n{}",
                    draft.content_hash,
                    draft.meta_hash,
                    draft.changes.join("; "),
                    String::from_utf8_lossy(&draft.bytes)
                ),
            );
            a.borrow_mut().draft = Some(draft);
            outcome.message = "Review normalized topics and exact metadata; load verified guidelines before acknowledging.".into();
        }
        Action::UploadMetadata => {
            content::require(a)?;
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            let (draft, upload) = {
                let s = a.borrow();
                if !s.guidelines || !input("ack").checked() {
                    return Err("GUIDELINES_ACK_REQUIRED".into());
                }
                (
                    s.draft.clone().ok_or("DRAFT_REQUIRED")?,
                    s.upload.clone().ok_or("UPLOAD_CONFIG_REQUIRED")?,
                )
            };
            io::upload(&upload, &draft).await?;
            active(a, epoch)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            a.borrow_mut().uploaded = true;
            outcome.message = "Uploaded metadata bytes verified. This does not establish persistence or replication.".into();
        }
        Action::Approve | Action::Submit | Action::Refund => {
            let request = match action {
                Action::Approve => "approve",
                Action::Submit => "submit",
                Action::Refund => "refund",
                _ => unreachable!(),
            };
            a.borrow()
                .profile
                .as_ref()
                .ok_or("PROFILE_REQUIRED")?
                .purpose
                .check_publication(request)
                .map_err(|e| e.0)?;
            if action != Action::Refund {
                content::require(a)?;
            }
            a.borrow_mut().funding = None;
            text("funds-feedback","The earlier balance snapshot was cleared for this wallet request. Refresh balances before preparing another payment.");
            if action == Action::Refund {
                a.borrow_mut().refund_ready = false;
            }
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            let c = io::begin(&p).await?;
            if action != Action::Refund {
                crate::versioning::require_active(&p, &c.pin).await?;
            }
            let (to, data) = if action == Action::Refund {
                let id = positive(&value("caseid"))?;
                let (case, owed, _) = io::case(&p, &c, id).await?;
                if owed == Uint256::ZERO {
                    return Err("NO_REFUND".into());
                }
                text(
                    "case",
                    &format!(
                        "Refund {} is paid to original submitter {}.",
                        crate::token_amounts::describe(owed, p.display.as_ref()),
                        case.submitter
                    ),
                );
                (
                    p.deployment.moderation.address.clone(),
                    format!(
                        "{}{}",
                        swarm_core::selector("withdrawRefund(uint256)"),
                        id.abi()
                    ),
                )
            } else {
                let d = {
                    let s = a.borrow();
                    if !s.uploaded {
                        return Err("METADATA_UPLOAD_REQUIRED".into());
                    }
                    if !s.guidelines || !input("ack").checked() {
                        return Err("GUIDELINES_ACK_REQUIRED".into());
                    }
                    s.draft.clone().ok_or("DRAFT_REQUIRED")?
                };
                let amount = progress::amount(a)?;
                let (min, balance, allowance) = io::funds(&p, &c, &who).await?;
                if amount < min {
                    return Err("FEE_TOO_LOW".into());
                }
                if action == Action::Approve {
                    if allowance >= amount {
                        return Err("APPROVAL_NOT_NEEDED".into());
                    }
                    (
                        p.deployment.token.address.clone(),
                        encode_approve(&p.deployment.moderation.address, amount)
                            .map_err(|e| e.0)?,
                    )
                } else {
                    if balance < amount {
                        return Err("INSUFFICIENT_BALANCE".into());
                    }
                    if allowance < amount {
                        return Err("INSUFFICIENT_ALLOWANCE".into());
                    }
                    (
                        p.deployment.moderation.address.clone(),
                        encode_submit(&d, amount).map_err(|e| e.0)?,
                    )
                }
            };
            io::finish(&p, &c).await?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            let intended = if action == Action::Submit {
                let s = a.borrow();
                let d = s.draft.as_ref().ok_or("DRAFT_REQUIRED")?;
                Some(
                    json!({"contentHash":d.content_hash,"metaHash":d.meta_hash,"topics":d.topic_keys,"fee":progress::amount(a)?.to_decimal()}),
                )
            } else {
                None
            };
            if journal(a).has_fault(&p, &who) {
                return Err("HISTORY_SAVE_REQUIRED".into());
            }
            let records = journal(a).load_current(&p, &who)?;
            let intent = intended.clone().unwrap_or(Value::Null);
            let caseid = if action == Action::Refund {
                value("caseid")
            } else {
                String::new()
            };
            history::guard_family(a, &p, &who, &records, request, &intent, &caseid)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            let mut reservation = history::record(&p, &who, request, &to, &data, intent, caseid);
            reservation["anchor"] = json!({"number":c.source["number"],"hash":c.source["hash"]});
            let mut pending = journal(a).reserve(&p, &who, records, reservation)?;
            a.borrow_mut().recovery_target = Some(recovery::identity(pending.record()));
            journal(a).begin_wallet(pending.record(), p.display.clone());
            input("resubmit").set_checked(false);
            presentation::pending(a);
            let _ = el("wallet-request")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
            let result = wallet::send_prepared(p.deployment.chain_id, &who, &to, &data).await;
            a.borrow_mut().funding = None;
            let hash = match result {
                Ok(hash) => hash,
                Err(e) => {
                    pending.failed(e);
                    return Err(e.into());
                }
            };
            let mut journal_saved = pending.broadcast(&hash);
            presentation::pending(a);
            // Preserve public hash even when wallet context changed while the prompt was open.
            input("txhash").set_value(&hash);
            outcome.message = format!("{request} broadcast: {hash}. Check receipt; do not resend an uncertain transaction.");
            text("transaction", &outcome.message);
            // The hash is already retained. A single optional read captures the actual nonce;
            // never predict or force a nonce before opening the wallet.
            if let Ok(nonce) = recovery::observe(&p, pending.record()).await {
                journal_saved &= pending.observed_nonce(nonce);
            }
            if !journal_saved {
                outcome.notice = Some(
                    "Broadcast hash retained in memory; save public history before another send."
                        .into(),
                );
            }
            if a.borrow().epoch != epoch {
                outcome.notice =
                    Some("Context changed after broadcast. Transaction hash retained.".into());
            }
        }
        Action::ReadHistory => {
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            let records = journal(a).load_current(&p, &who)?;
            outcome.message = format!("{} retained records for this context. Read the paged recovery cards below; export saves the displayed page.",records.len());
            text("transaction", &outcome.message);
            presentation::render_history(a)?;
        }
        Action::ReadOwned => {
            let (p, who, epoch) = context(a)?;
            let cursor = value("cursor")
                .parse::<u64>()
                .map_err(|_| "INVALID_CURSOR")?;
            if cursor == 0 {
                return Err("INVALID_CURSOR".into());
            }
            let c = io::begin(&p).await?;
            let next = Uint256::hex(
                &io::view(&p, &c, &p.deployment.moderation.address, "nextCaseId()", "").await?,
            )
            .map_err(|e| e.0)?
            .as_u64()
            .map_err(|_| "SCAN_RANGE_UNSUPPORTED")?;
            let end = cursor.saturating_add(20).min(next);
            let mut lines = vec![];
            for id in cursor..end {
                let (case, refund, _) = io::case(&p, &c, Uint256::from_u64(id)).await?;
                active(a, epoch)?;
                if case.submitter.eq_ignore_ascii_case(&who) {
                    lines.push(format!(
                        "Case {id}: phase {}, refund {}, metadata {}",
                        case.phase,
                        crate::token_amounts::describe(refund, p.display.as_ref()),
                        case.meta_hash
                    ));
                }
            }
            io::finish(&p, &c).await?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            input("cursor").set_value(&end.max(1).to_string());
            text(
                "owned",
                &format!(
                    "Source block {}. Scanned IDs {cursor} through {}. Next cursor {}.\n{}",
                    c.source["number"],
                    end.saturating_sub(1),
                    end,
                    lines.join("\n")
                ),
            );
        }
        Action::ReadCase => publications::read_case(a, positive(&value("caseid"))?, None).await?,
        Action::OpenPublication => publications::open(a).await?,
        Action::CheckReceipt => {
            outcome.message = recovery::check(a).await?.message;
            progress::after_receipt(a).await;
        }
    };
    Ok(outcome)
}
fn positive(s: &str) -> Result<Uint256> {
    let n = Uint256::decimal(s).map_err(|e| e.0)?;
    if n == Uint256::ZERO {
        return Err("INVALID_CASE_ID");
    }
    Ok(n)
}
pub fn start_publisher() -> std::result::Result<(), JsValue> {
    el("app").set_inner_html(include_str!("view.html"));
    let a = Rc::new(RefCell::new(App::default()));
    let discovery_app = a.clone();
    let _ = wallet::discover(Rc::new(move || progress::render(&discovery_app)));
    bind_wallet_picker(&a)?;
    authoring::restore_tab(&a);
    setup::seed_link(&a);
    content::bind(&a)?;
    presentation::bind_requests(&a)?;
    publications::bind(&a)?;
    for (id, action, event) in [
        ("preparearchive", Action::PrepareArchive, "click"),
        ("verifyarchive", Action::VerifyArchive, "click"),
        ("commitarchive", Action::CommitArchive, "click"),
        ("historyprev", Action::HistoryPrevious, "click"),
        ("historynext", Action::HistoryNext, "click"),
        ("publicationprev", Action::PublicationPrevious, "click"),
        ("publicationnext", Action::PublicationNext, "click"),
        ("profile", Action::LoadProfile, "change"),
        ("profile-version", Action::SelectVersion, "change"),
        ("loadprofilefile", Action::LoadProfile, "click"),
        ("fetchprofile", Action::FetchProfile, "click"),
        ("useprofile", Action::UseProfile, "click"),
        ("contentfile", Action::SelectContent, "change"),
        ("applybee", Action::ApplyBee, "click"),
        ("uploadcontent", Action::UploadContent, "click"),
        ("checkcontent", Action::CheckContent, "click"),
        ("downloadcontent", Action::DownloadContent, "click"),
        ("connect", Action::Connect, "click"),
        ("readfunds", Action::ReadFunds, "click"),
        ("paymentfunds", Action::ReadFunds, "click"),
        ("useminimum", Action::UseMinimum, "click"),
        ("usemimetype", Action::UseMimeType, "click"),
        ("approvalreceipt", Action::CheckApprovalReceipt, "click"),
        ("submissionreceipt", Action::CheckSubmissionReceipt, "click"),
        ("draft", Action::PreviewDraft, "click"),
        ("loadguidelines", Action::LoadGuidelines, "click"),
        ("upload", Action::UploadMetadata, "click"),
        ("approve", Action::Approve, "click"),
        ("submit", Action::Submit, "click"),
        ("readcase", Action::ReadCase, "click"),
        ("loadowned", Action::ReadOwned, "click"),
        ("refund", Action::Refund, "click"),
        ("receipt", Action::CheckReceipt, "click"),
        ("history", Action::ReadHistory, "click"),
        ("exportdraft", Action::ExportDraft, "click"),
        ("importdraft", Action::ImportDraft, "click"),
        ("exporthistory", Action::ExportHistory, "click"),
        ("savehistory", Action::SaveHistory, "click"),
        ("importhistory", Action::ImportHistory, "click"),
    ] {
        bind(&a, id, action, event);
    }
    for id in [
        "reference",
        "entrytype",
        "title",
        "description",
        "topics",
        "language",
        "contenttype",
        "source",
    ] {
        let state = a.clone();
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            if !state.borrow().busy {
                if id == "reference" {
                    content::clear(&state);
                }
                invalidate_review(&state);
                authoring::save_tab(&state);
                let validation_shown = state.borrow().validation_shown;
                if validation_shown {
                    validation::check(&state, false);
                }
                if context(&state).is_ok() {
                    let _ = presentation::render_history(&state);
                }
                if context(&state).is_ok() {
                    let _ = publications::render(&state);
                }
                progress::render(&state);
            }
        });
        el(id).add_event_listener_with_callback("input", cb.as_ref().unchecked_ref())?;
        cb.forget();
    }
    for id in [
        "fee",
        "caseid",
        "cursor",
        "txhash",
        "draftfile",
        "historyfile",
        "archivefile",
    ] {
        let state = a.clone();
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            if state.borrow().busy {
                return;
            }
            let mut s = state.borrow_mut();
            s.epoch = s.epoch.wrapping_add(1);
            if id == "archivefile" {
                if let Some(c) = s.archive_candidate.as_mut() {
                    c.verified = false;
                }
            }
            if id == "caseid" {
                s.refund_ready = false;
                el("refund").set_attribute("disabled", "").unwrap();
            }
            text("case", "Evidence cleared after input changed.");
            drop(s);
            progress::render(&state);
        });
        el(id).add_event_listener_with_callback("input", cb.as_ref().unchecked_ref())?;
        cb.forget();
    }
    for id in ["profileurl", "profilepin"] {
        let state = a.clone();
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            if state.borrow().busy {
                return;
            }
            setup::clear(&state);
            validation::field(id, None);
            progress::render(&state);
        });
        el(id).add_event_listener_with_callback("input", cb.as_ref().unchecked_ref())?;
        cb.forget();
    }
    for id in [
        "beeendpoint",
        "beebatch",
        "beeauth",
        "contentgateway",
        "contentcollection",
    ] {
        let state = a.clone();
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            if state.borrow().busy {
                return;
            }
            if ["beeendpoint", "beebatch", "beeauth"].contains(&id) {
                state.borrow_mut().upload = None;
            }
            if id != "contentcollection" {
                validation::field(id, None);
            }
            content::clear(&state);
            invalidate_review(&state);
            progress::render(&state);
        });
        el(id).add_event_listener_with_callback(
            if id == "contentcollection" {
                "change"
            } else {
                "input"
            },
            cb.as_ref().unchecked_ref(),
        )?;
        cb.forget();
    }
    for id in ["trustprofile", "contentack", "resubmit"] {
        let state = a.clone();
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            progress::render(&state);
        });
        el(id).add_event_listener_with_callback("change", cb.as_ref().unchecked_ref())?;
        cb.forget();
    }
    let state = a.clone();
    let ack = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        progress::render(&state);
    });
    el("ack").add_event_listener_with_callback("change", ack.as_ref().unchecked_ref())?;
    ack.forget();
    journey::bind(&a)?;
    progress::render(&a);
    Ok(())
}
fn choose_wallet(a: &Rc<RefCell<App>>) -> Result<bool> {
    let id = wallet::picker_choice("wallet-picker")?;
    if wallet::selected_id() == Some(id) {
        return Ok(false);
    }
    invalidate(a);
    {
        let mut s = a.borrow_mut();
        s.account = None;
        s.wallet_chain = None;
    }
    text("wallet", "Not connected.");
    cleanup_events(a)?;
    wallet::select(id)?;
    text("wallet", "Wallet selected. Connect your intended account.");
    Ok(true)
}
fn bind_wallet_picker(a: &Rc<RefCell<App>>) -> Result<()> {
    let state = a.clone();
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if state.borrow().busy {
            progress::render(&state);
            return;
        }
        if let Err(code) = choose_wallet(&state) {
            text("setup-feedback", &progress::explain(&state, code, code));
        }
        progress::render(&state);
    });
    el("wallet-picker")
        .add_event_listener_with_callback("change", handler.as_ref().unchecked_ref())
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?;
    handler.forget();
    Ok(())
}
fn cleanup_events(a: &Rc<RefCell<App>>) -> Result<()> {
    let mut subscriptions = std::mem::take(&mut a.borrow_mut().wallet_subscriptions);
    let result = subscriptions.clear();
    a.borrow_mut().wallet_subscriptions = subscriptions;
    result
}
fn install_events(a: &Rc<RefCell<App>>) -> Result<()> {
    let mut subscriptions = std::mem::take(&mut a.borrow_mut().wallet_subscriptions);
    let weak = Rc::downgrade(a);
    let result = subscriptions.install(move |_, _| {
        let Some(state) = weak.upgrade() else {
            return;
        };
        invalidate(&state);
        state.borrow_mut().account = None;
        text("wallet", "Wallet context changed. Connect again.");
        progress::render(&state);
    });
    a.borrow_mut().wallet_subscriptions = subscriptions;
    result
}
