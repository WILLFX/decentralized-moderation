//! Publisher UI: exact metadata bytes, pinned reads and explicit wallet actions.
#[path = "publisher/archive.rs"]
mod archive;
#[path = "publisher/authoring.rs"]
mod authoring;
#[path = "publisher/content.rs"]
mod content;
#[path = "publisher/history.rs"]
mod history;
#[path = "publisher/io.rs"]
mod io;
#[path = "publisher/journey.rs"]
mod journey;
#[path = "publisher/ledger.rs"]
mod ledger;
#[path = "publisher/presentation.rs"]
mod presentation;
#[path = "publisher/progress.rs"]
mod progress;
#[path = "publisher/publications.rs"]
mod publications;
#[path = "publisher/recovery.rs"]
mod recovery;
#[path = "publisher/setup.rs"]
mod setup;
#[path = "publisher/transfers.rs"]
mod transfers;
#[path = "publisher/validation.rs"]
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
#[derive(Default)]
struct App {
    journey: journey::State,
    events_bound: bool,
    wallet_listeners: Vec<WalletListener>,

    history_faults: std::collections::BTreeSet<String>,
    history_write_lock: bool,
    history_bases: std::collections::BTreeMap<String, Vec<Value>>,
    history_cache: std::collections::BTreeMap<String, Vec<Value>>,
    profile: Option<ModeratorProfile>,
    upload: Option<Value>,
    account: Option<String>,
    draft: Option<Draft>,
    uploaded: bool,
    guidelines: bool,
    epoch: u64,
    busy: bool,
    pending_wallet: Option<presentation::PendingIntent>,
    recovery_target: Option<String>,
    authoring_storage_blocked: bool,
    publication_target: Option<String>,
    refund_ready: bool,
    funding: Option<progress::FundingRead>,
    setup_candidate: Option<setup::Candidate>,
    content: content::ContentState,
    validation_shown: bool,
    wallet_chain: Option<u64>,
    archive_candidate: Option<archive::Prepared>,
    history_page: usize,
    publication_page: usize,
}
struct WalletListener {
    provider: JsValue,
    remove: js_sys::Function,
    event: &'static str,
    handler: Closure<dyn FnMut(JsValue)>,
}
fn doc() -> web_sys::Document {
    web_sys::window().unwrap().document().unwrap()
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
    if let Some(pending) = s.pending_wallet.as_mut() {
        if pending.record["state"] == "requesting" {
            pending.context_changed = true;
        }
    }
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
fn bind(a: &Rc<RefCell<App>>, id: &str, action: &'static str, event: &str) {
    let state = a.clone();
    let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| dispatch(state.clone(), action));
    el(id)
        .add_event_listener_with_callback(event, cb.as_ref().unchecked_ref())
        .unwrap();
    cb.forget();
}
fn dispatch(a: Rc<RefCell<App>>, action: &'static str) {
    if a.borrow().busy {
        return;
    }
    let navigation_revision = a.borrow().journey.revision;
    let feedback = presentation::task_feedback(action, a.borrow().journey.view);
    {
        let mut s = a.borrow_mut();
        s.journey.notice_view = s.journey.view;
    }
    presentation::busy(&a, true);
    progress::render(&a);
    text("notice", "Working… Wait for this action to finish.");
    text(
        feedback,
        if ["connect", "approve", "submit", "refund"].contains(&action) {
            "Working… Review the open wallet request in wallet."
        } else {
            "Working… Wait for this check to finish."
        },
    );
    if [
        "approve",
        "submit",
        "refund",
        "receipt",
        "history",
        "publication",
    ]
    .contains(&action)
    {
        text(
            feedback,
            "Working… Check the saved request and wallet status below.",
        );
    }
    spawn_local(async move {
        let r = history::coordinated(&a, action).await;
        let succeeded = r.is_ok();
        presentation::busy(&a, false);
        if let Err(e) = r {
            let recovery_action = [
                "approve",
                "submit",
                "refund",
                "receipt",
                "history",
                "savehistory",
                "importhistory",
                "exporthistory",
                "publication",
            ]
            .contains(&action);
            let authoring_action = ["exportdraft", "importdraft"].contains(&action);
            let content_action = [
                "contentfile",
                "applybee",
                "uploadcontent",
                "checkcontent",
                "downloadcontent",
            ]
            .contains(&action);
            let message = if action == "importhistory" && e == "FILE_REQUIRED" {
                "Choose a saved public history JSON file before merging. Existing requests have been kept.\nDetails: FILE_REQUIRED".into()
            } else if ["preparearchive", "verifyarchive", "commitarchive"].contains(&action) {
                presentation::error(e)
            } else if content_action {
                if e == "CONTENT_UPLOAD_UNVERIFIED" {
                    el("content-feedback").text_content().unwrap_or_default()
                } else {
                    content::help(e)
                }
            } else if authoring_action {
                format!("The authoring file could not be saved or loaded. Your current text has been kept. Check the selected file and try saving a draft file again.\nDetails: {e}")
            } else if recovery_action {
                presentation::error(e)
            } else {
                e.to_owned()
            };
            let message = progress::explain(&a, e, &message);
            text("notice", &message);
            text(feedback, &message);
            if a.borrow().journey.revision == navigation_revision {
                validation::action_error(action, e);
            }
            if authoring_action {
                text("authoring-note", &message);
            }
        } else {
            progress::render(&a);
            let local = if action == "funds" && feedback == "setup-feedback" {
                let height = a
                    .borrow()
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
                    el("review-cost").text_content().unwrap_or_default()
                )
            } else if action == "applybee" && feedback == "bee-feedback" {
                "Local Bee settings applied. Inspect content again before reviewing.".into()
            } else if action == "importhistory" {
                el("transaction").text_content().unwrap_or_default()
            } else if action == "exporthistory" {
                "History page download requested. Keep the downloaded file for recovery.".into()
            } else if ["preparearchive", "verifyarchive", "commitarchive"].contains(&action) {
                el("archive-feedback").text_content().unwrap_or_default()
            } else if [
                "contentfile",
                "applybee",
                "uploadcontent",
                "checkcontent",
                "downloadcontent",
            ]
            .contains(&action)
            {
                el("content-feedback").text_content().unwrap_or_default()
            } else if [
                "approve",
                "submit",
                "refund",
                "receipt",
                "approvalreceipt",
                "submissionreceipt",
                "history",
            ]
            .contains(&action)
            {
                el("transaction").text_content().unwrap_or_default()
            } else if el("notice").text_content().as_deref()
                != Some("Working… Wait for this action to finish.")
            {
                el("notice").text_content().unwrap_or_default()
            } else {
                progress::success(action).into()
            };
            text(feedback, &local);
            if el("notice").text_content().as_deref()
                == Some("Working… Wait for this action to finish.")
            {
                text("notice", &local);
            }
            if ["approve", "submit", "refund", "receipt", "history"].contains(&action) {
                text(
                    feedback,
                    &el("transaction").text_content().unwrap_or_default(),
                );
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
        if action == "draft" && same_workspace {
            validation::focus_first();
        }
        if same_workspace && ["preparearchive", "verifyarchive", "commitarchive"].contains(&action)
        {
            let _ = el("archive-feedback")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
        if action == "usemimetype" && same_workspace {
            let _ = input("contenttype").focus();
        }
        journey::after_action(&a, action, succeeded, navigation_revision);
        if same_workspace && succeeded && action == "useprofile" && wallet::needs_selection() {
            let _ = el("wallet-picker")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
        if same_workspace && action == "connect" && matches!(r, Err("WALLET_SELECTION_REQUIRED")) {
            let _ = el("wallet-picker")
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
        if same_workspace
            && (succeeded || action != "applybee")
            && [
                "applybee",
                "funds",
                "history",
                "savehistory",
                "importhistory",
                "exporthistory",
            ]
            .contains(&action)
        {
            journey::open_ancestors(&el(feedback));
            let _ = el(feedback)
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
    });
}
async fn run(a: &Rc<RefCell<App>>, action: &str) -> Result<()> {
    match action {
        "exportdraft" | "importdraft" => authoring::transfer(a, action).await?,
        "minimum" => progress::minimum(a)?,
        "preparearchive" => archive::prepare(a)?,
        "verifyarchive" => archive::verify(a).await?,
        "commitarchive" => archive::commit(a).await?,
        "historyprev" | "historynext" => {
            let page = a.borrow().history_page;
            a.borrow_mut().history_page = if action == "historyprev" {
                page.saturating_sub(1)
            } else {
                page.saturating_add(1)
            };
        }
        "publicationprev" | "publicationnext" => {
            let page = a.borrow().publication_page;
            a.borrow_mut().publication_page = if action == "publicationprev" {
                page.saturating_sub(1)
            } else {
                page.saturating_add(1)
            };
        }
        "usemimetype" => validation::apply_format(a)?,
        "approvalreceipt" => progress::check_latest(a, "approve").await?,
        "submissionreceipt" => progress::check_latest(a, "submit").await?,
        "exporthistory" | "importhistory" | "savehistory" => transfers::transfer(a, action).await?,
        "profile" => setup::load(a, false).await?,
        "fetchprofile" => setup::load(a, true).await?,
        "useprofile" => setup::accept(a)?,
        "contentfile" => content::selected(a),
        "applybee" => content::apply_bee(a)?,
        "uploadcontent" => content::upload(a).await?,
        "checkcontent" => content::check(a).await?,
        "downloadcontent" => content::download(a)?,
        "connect" => {
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
        "funds" => {
            progress::refresh_funds(a).await?;
        }
        "guidelines" => {
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
        "draft" => {
            invalidate_review(a);
            if !validation::check(a, true) {
                return Err("AUTHOR_FIELDS_INVALID");
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
            text("notice","Review normalized topics and exact metadata; load verified guidelines before acknowledging.");
        }
        "upload" => {
            content::require(a)?;
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            let (draft, upload) = {
                let s = a.borrow();
                if !s.guidelines || !input("ack").checked() {
                    return Err("GUIDELINES_ACK_REQUIRED");
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
            text("notice","Uploaded metadata bytes verified. This does not establish persistence or replication.");
        }
        "approve" | "submit" | "refund" => {
            if action != "refund" {
                content::require(a)?;
            }
            a.borrow_mut().funding = None;
            text("funds-feedback","The earlier balance snapshot was cleared for this wallet request. Refresh balances before preparing another payment.");
            if action == "refund" {
                a.borrow_mut().refund_ready = false;
            }
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            let c = io::begin(&p).await?;
            let (to, data) = if action == "refund" {
                let id = positive(&value("caseid"))?;
                let (case, owed, _) = io::case(&p, &c, id).await?;
                if owed == Uint256::ZERO {
                    return Err("NO_REFUND");
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
                        return Err("METADATA_UPLOAD_REQUIRED");
                    }
                    if !s.guidelines || !input("ack").checked() {
                        return Err("GUIDELINES_ACK_REQUIRED");
                    }
                    s.draft.clone().ok_or("DRAFT_REQUIRED")?
                };
                let amount = progress::amount(a)?;
                let (min, balance, allowance) = io::funds(&p, &c, &who).await?;
                if amount < min {
                    return Err("FEE_TOO_LOW");
                }
                if action == "approve" {
                    if allowance >= amount {
                        return Err("APPROVAL_NOT_NEEDED");
                    }
                    (
                        p.deployment.token.address.clone(),
                        encode_approve(&p.deployment.moderation.address, amount)
                            .map_err(|e| e.0)?,
                    )
                } else {
                    if balance < amount {
                        return Err("INSUFFICIENT_BALANCE");
                    }
                    if allowance < amount {
                        return Err("INSUFFICIENT_ALLOWANCE");
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
            let intended = if action == "submit" {
                let s = a.borrow();
                let d = s.draft.as_ref().ok_or("DRAFT_REQUIRED")?;
                Some(
                    json!({"contentHash":d.content_hash,"metaHash":d.meta_hash,"topics":d.topic_keys,"fee":progress::amount(a)?.to_decimal()}),
                )
            } else {
                None
            };
            if history::has_fault(a, &p, &who) {
                return Err("HISTORY_SAVE_REQUIRED");
            }
            let mut records = history::load_current(a, &p, &who)?;
            let intent = intended.clone().unwrap_or(Value::Null);
            let caseid = if action == "refund" {
                value("caseid")
            } else {
                String::new()
            };
            history::guard(&records, action, &intent, &caseid)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            let mut reservation = history::record(&p, &who, action, &to, &data, intent, caseid);
            reservation["anchor"] = json!({"number":c.source["number"],"hash":c.source["hash"]});
            history::ensure_room(a, &p, &who, &reservation)?;
            records.push(reservation);
            if let Err(error) = history::save(a, &p, &who, &records) {
                let reserved = records.pop().ok_or("INVALID_HISTORY")?;
                history::cancel_unsent(a, &p, &who, &reserved);
                return Err(error);
            }
            a.borrow_mut().recovery_target = Some(recovery::identity(records.last().unwrap()));
            a.borrow_mut().pending_wallet = Some(presentation::PendingIntent {
                record: records.last().unwrap().clone(),
                context_changed: false,
                display: p.display.clone(),
            });
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
                    records.last_mut().unwrap()["state"] = json!(if e == "WALLET_REJECTED" {
                        "rejected"
                    } else {
                        "unknown"
                    });
                    let _ = history::save(a, &p, &who, &records);
                    if let Some(pending) = a.borrow_mut().pending_wallet.as_mut() {
                        pending.record = records.last().unwrap().clone();
                    }
                    return Err(e);
                }
            };
            records.last_mut().unwrap()["state"] = json!("unchecked");
            records.last_mut().unwrap()["hash"] = json!(hash);
            let mut journal_saved = history::save(a, &p, &who, &records).is_ok();
            if let Some(pending) = a.borrow_mut().pending_wallet.as_mut() {
                pending.record = records.last().unwrap().clone();
            }
            presentation::pending(a);
            // Preserve public hash even when wallet context changed while the prompt was open.
            input("txhash").set_value(&hash);
            text("transaction",&format!("{action} broadcast: {hash}. Check receipt; do not resend an uncertain transaction."));
            // The hash is already retained. A single optional read captures the actual nonce;
            // never predict or force a nonce before opening the wallet.
            if let Ok(nonce) = recovery::observe(&p, records.last().unwrap()).await {
                records.last_mut().unwrap()["nonce"] = json!(nonce);
                journal_saved &= history::save(a, &p, &who, &records).is_ok();
                if let Some(pending) = a.borrow_mut().pending_wallet.as_mut() {
                    pending.record = records.last().unwrap().clone();
                }
            }
            if !journal_saved {
                text(
                    "notice",
                    "Broadcast hash retained in memory; save public history before another send.",
                );
            }
            if a.borrow().epoch != epoch {
                text(
                    "notice",
                    "Context changed after broadcast. Transaction hash retained.",
                );
            }
        }
        "history" => {
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            let records = history::load_current(a, &p, &who)?;
            text("transaction",&format!("{} retained records for this context. Read the paged recovery cards below; export saves the displayed page.",records.len()));
            presentation::render_history(a)?;
        }
        "owned" => {
            let (p, who, epoch) = context(a)?;
            let cursor = value("cursor")
                .parse::<u64>()
                .map_err(|_| "INVALID_CURSOR")?;
            if cursor == 0 {
                return Err("INVALID_CURSOR");
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
        "case" => publications::read_case(a, positive(&value("caseid"))?, None).await?,
        "publication" => publications::open(a).await?,
        "receipt" => {
            let _ = recovery::check(a).await?;
            progress::after_receipt(a).await;
        }
        _ => return Err("UNKNOWN_ACTION"),
    };
    Ok(())
}
fn positive(s: &str) -> Result<Uint256> {
    let n = Uint256::decimal(s).map_err(|e| e.0)?;
    if n == Uint256::ZERO {
        return Err("INVALID_CASE_ID");
    }
    Ok(n)
}
pub fn start_publisher() -> std::result::Result<(), JsValue> {
    el("app").set_inner_html(include_str!("publisher/view.html"));
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
        ("preparearchive", "preparearchive", "click"),
        ("verifyarchive", "verifyarchive", "click"),
        ("commitarchive", "commitarchive", "click"),
        ("historyprev", "historyprev", "click"),
        ("historynext", "historynext", "click"),
        ("publicationprev", "publicationprev", "click"),
        ("publicationnext", "publicationnext", "click"),
        ("profile", "profile", "change"),
        ("loadprofilefile", "profile", "click"),
        ("fetchprofile", "fetchprofile", "click"),
        ("useprofile", "useprofile", "click"),
        ("contentfile", "contentfile", "change"),
        ("applybee", "applybee", "click"),
        ("uploadcontent", "uploadcontent", "click"),
        ("checkcontent", "checkcontent", "click"),
        ("downloadcontent", "downloadcontent", "click"),
        ("connect", "connect", "click"),
        ("readfunds", "funds", "click"),
        ("paymentfunds", "funds", "click"),
        ("useminimum", "minimum", "click"),
        ("usemimetype", "usemimetype", "click"),
        ("approvalreceipt", "approvalreceipt", "click"),
        ("submissionreceipt", "submissionreceipt", "click"),
        ("draft", "draft", "click"),
        ("loadguidelines", "guidelines", "click"),
        ("upload", "upload", "click"),
        ("approve", "approve", "click"),
        ("submit", "submit", "click"),
        ("readcase", "case", "click"),
        ("loadowned", "owned", "click"),
        ("refund", "refund", "click"),
        ("receipt", "receipt", "click"),
        ("history", "history", "click"),
        ("exportdraft", "exportdraft", "click"),
        ("importdraft", "importdraft", "click"),
        ("exporthistory", "exporthistory", "click"),
        ("savehistory", "savehistory", "click"),
        ("importhistory", "importhistory", "click"),
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
        s.events_bound = false;
    }
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
fn remove_wallet_listener(listener: &WalletListener) -> bool {
    listener
        .remove
        .call2(
            &listener.provider,
            &listener.event.into(),
            listener.handler.as_ref().unchecked_ref(),
        )
        .is_ok()
}
fn cleanup_events(a: &Rc<RefCell<App>>) -> Result<()> {
    let pending = std::mem::take(&mut a.borrow_mut().wallet_listeners);
    let retained = pending
        .into_iter()
        .filter(|listener| !remove_wallet_listener(listener))
        .collect();
    a.borrow_mut().wallet_listeners = retained;
    if a.borrow().wallet_listeners.is_empty() {
        Ok(())
    } else {
        Err("WALLET_EVENT_CLEANUP_FAILED")
    }
}
fn install_events(a: &Rc<RefCell<App>>) -> Result<()> {
    if a.borrow().events_bound {
        return Ok(());
    }
    cleanup_events(a)?;
    let provider = wallet::provider()?;
    let on = js_sys::Reflect::get(&provider, &"on".into())
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?;
    let remove = js_sys::Reflect::get(&provider, &"removeListener".into())
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?;
    let mut handlers = Vec::new();
    for event in ["accountsChanged", "chainChanged", "disconnect"] {
        let weak = Rc::downgrade(a);
        let cb = Closure::<dyn FnMut(JsValue)>::new(move |_| {
            let Some(state) = weak.upgrade() else {
                return;
            };
            invalidate(&state);
            state.borrow_mut().account = None;
            text("wallet", "Wallet context changed. Connect again.");
            progress::render(&state);
        });
        handlers.push(WalletListener {
            provider: provider.clone(),
            remove: remove.clone(),
            event,
            handler: cb,
        });
    }
    match crate::registration::install_handlers(
        handlers,
        |listener| {
            on.call2(
                &provider,
                &listener.event.into(),
                listener.handler.as_ref().unchecked_ref(),
            )
            .is_ok()
        },
        remove_wallet_listener,
    ) {
        Ok(handlers) => {
            let mut state = a.borrow_mut();
            state.wallet_listeners = handlers;
            state.events_bound = true;
            Ok(())
        }
        Err(retained) => {
            a.borrow_mut().wallet_listeners = retained;
            Err("WALLET_EVENT_REGISTRATION_FAILED")
        }
    }
}
