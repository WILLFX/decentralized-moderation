//! Moderator UI bindings. Remote documents are always text, never HTML.
use super::{busy, document, element, notice, text, App};
use crate::{
    evidence::{self, CaseEvidence, ModeratorEvidence},
    workflow::{self, Broadcast, Session},
    BrowserResult as Result,
};
use js_sys::Array;
use std::{cell::RefCell, rc::Rc};
use swarm_core::{
    moderator::*,
    recovery::{VoteContext, VoteRecord},
    ModeratorProfile,
};
use wasm_bindgen::{closure::Closure, JsCast};
use wasm_bindgen_futures::{spawn_local, JsFuture};
use web_sys::{HtmlAnchorElement, HtmlInputElement};

#[derive(Default)]
pub(super) struct State {
    selected: Option<CaseEvidence>,
    moderator: Option<ModeratorEvidence>,
    next: Option<Uint256>,
    review: Option<ReviewBinding>,
    last_transaction: Option<(String, ModeratorProfile)>,
}
struct ReviewBinding {
    case_id: Uint256,
    meta_hash: String,
    content_hash: String,
    round: u8,
    guidelines_hash: String,
    metadata_valid: bool,
    guidelines_valid: bool,
}
impl State {
    pub(super) fn clear_context(&mut self) {
        self.selected = None;
        self.moderator = None;
        self.next = None;
        self.review = None;
    }
}
const IDS: &[&str] = &[
    "load-cases",
    "next-cases",
    "read-case",
    "case-id",
    "load-review",
    "guidelines-read",
    "content-read",
    "draft-approve",
    "draft-reject",
    "commit-vote",
    "reveal-vote",
    "unlock-vault",
    "vault-password",
    "backup-file",
    "backup-password",
    "export-vault",
    "verify-backup",
    "import-backup",
    "approve-stake",
    "stake",
    "withdraw-stake",
    "refresh-stake",
    "close-a",
    "close-b",
    "close-reveal",
    "draw",
    "challenge",
    "finalize",
    "claim",
    "refund",
    "receipt",
    "receipt-hash",
];
const ACTIONS: &[(&str, Action)] = &[
    ("close-a", Action::CloseCommitA),
    ("close-b", Action::CloseCommitB),
    ("close-reveal", Action::CloseReveal),
    ("draw", Action::Draw),
    ("challenge", Action::Challenge),
    ("finalize", Action::CloseChallenge),
    ("claim", Action::Claim),
    ("refund", Action::WithdrawRefund),
];

pub(super) fn mount(app: Rc<RefCell<App>>) {
    let sections = document().create_element("div").unwrap();
    sections.set_inner_html(r#"
      <section><h2>Review queue</h2><button id="load-cases">Load first 10 cases</button>
      <button id="next-cases">Next page</button><pre id="cases">No cases loaded.</pre>
      <label for="case-id">Case ID</label><input id="case-id" value="2" inputmode="numeric">
      <button id="read-case">Read selected case</button><pre id="case-facts">No selected case.</pre></section>
      <section><h2>Content and pinned guidelines</h2><button id="load-review">Load and verify review documents</button>
      <pre id="metadata">No metadata loaded.</pre><details><summary>Pinned guidelines</summary><pre id="guidelines">Not loaded.</pre></details>
      <p><a id="content-link" target="_blank" rel="noopener noreferrer">Open content separately</a></p>
      <label><input type="checkbox" id="guidelines-read"> I have read the verified guidelines.</label>
      <label><input type="checkbox" id="content-read"> I have reviewed the submitted content.</label></section>
      <section><h2>Private vote storage and recovery</h2><p>Keep the encrypted recovery file and its password until settlement.</p>
      <label for="vault-password">Local vault password</label><input id="vault-password" type="password" autocomplete="off">
      <button id="unlock-vault">Unlock or create encrypted storage</button><button id="lock-vault">Lock private storage</button>
      <pre id="vault-status">Locked.</pre><button id="export-vault">Export encrypted recovery</button>
      <label for="backup-file">Saved encrypted recovery file</label><input id="backup-file" type="file" accept=".json,application/json">
      <label for="backup-password">Recovery file password (leave empty to use the unlocked key)</label>
      <input id="backup-password" type="password" autocomplete="off">
      <button id="verify-backup">Verify saved recovery file</button><button id="import-backup">Import recovery</button></section>
      <section><h2>Saved vote</h2><p id="saved-vote">Unlock storage and select a case.</p>
      <button id="draft-approve">Prepare approval vote</button><button id="draft-reject">Prepare rejection vote</button>
      <button id="commit-vote">Commit saved vote</button><button id="reveal-vote">Reveal saved vote</button></section>
      <section><h2>Stake</h2><button id="refresh-stake">Refresh stake and balance</button><pre id="stake-status">Refresh stake information.</pre>
      <button id="approve-stake">Approve exact stake amount</button><button id="stake">Stake</button>
      <button id="withdraw-stake">Withdraw stake</button></section>
      <section><h2>Available case actions</h2><pre id="action-status">Read a case first.</pre>
      <button id="close-a">Close first committee</button><button id="close-b">Close second committee</button>
      <button id="close-reveal">Open outcome draw</button><button id="draw">Draw outcome</button>
      <button id="challenge">Challenge outcome</button><button id="finalize">Finalize outcome</button>
      <button id="claim">Claim / settle vote</button><button id="refund">Withdraw submission refund</button></section>
      <section><h2>Transaction result</h2><pre id="transaction">No transaction sent in this page session.</pre>
      <p>Saved transaction hashes for this account and deployment:</p><pre id="public-history">Connect to load public history.</pre>
      <label for="receipt-hash">Transaction hash to check (use the matching deployment profile)</label><input id="receipt-hash">
      <button id="receipt">Refresh transaction receipt</button></section>
    "#);
    element("app").append_child(&sections).unwrap();
    bind(app.clone(), "load-cases", Command::Page(false));
    bind(app.clone(), "next-cases", Command::Page(true));
    bind(app.clone(), "read-case", Command::Read);
    bind(app.clone(), "refresh-stake", Command::ReadStake);
    bind(app.clone(), "load-review", Command::Review);
    bind(app.clone(), "unlock-vault", Command::Unlock);
    bind(app.clone(), "export-vault", Command::Export);
    bind(app.clone(), "verify-backup", Command::Verify);
    bind(app.clone(), "import-backup", Command::Import);
    bind(app.clone(), "draft-approve", Command::Draft(1));
    bind(app.clone(), "draft-reject", Command::Draft(2));
    bind(app.clone(), "commit-vote", Command::Commit);
    bind(app.clone(), "reveal-vote", Command::Reveal);
    for (id, action) in ACTIONS {
        bind(app.clone(), id, Command::Action(*action));
    }
    for (id, action) in [
        ("approve-stake", "approveStake"),
        ("stake", "stake"),
        ("withdraw-stake", "withdraw"),
    ] {
        bind(app.clone(), id, Command::Stake(action));
    }
    bind(app.clone(), "receipt", Command::Receipt);
    let copy = app.clone();
    let lock = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        copy.borrow().vault.lock();
        text("vault-password", "");
        input("vault-password").set_value("");
        input("backup-password").set_value("");
        render(&copy.borrow());
        notice("Private storage locked. Pending secret operations are cancelled.");
    });
    element("lock-vault")
        .add_event_listener_with_callback("click", lock.as_ref().unchecked_ref())
        .unwrap();
    lock.forget();
    for id in ["guidelines-read", "content-read"] {
        let copy = app.clone();
        let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| render(&copy.borrow()));
        element(id)
            .add_event_listener_with_callback("change", handler.as_ref().unchecked_ref())
            .unwrap();
        handler.forget();
    }
    render(&app.borrow());
}
pub(super) fn clear_dom() {
    for (id, message) in [
        ("cases", "Evidence cleared after context changed."),
        ("case-facts", "No selected case."),
        ("metadata", "Not loaded."),
        ("guidelines", "Not loaded."),
        ("saved-vote", "Private storage locked."),
        ("stake-status", "Not checked for this wallet."),
        ("action-status", "No current evidence."),
        ("public-history", "Connect to load public history."),
    ] {
        text(id, message);
    }
    input("guidelines-read").set_checked(false);
    input("content-read").set_checked(false);
    element("content-link").remove_attribute("href").unwrap();
    input("vault-password").set_value("");
    input("backup-password").set_value("");
}
fn input(id: &str) -> HtmlInputElement {
    element(id).dyn_into().unwrap()
}
fn disabled(id: &str, value: bool) {
    if value {
        element(id).set_attribute("disabled", "").unwrap();
    } else {
        element(id).remove_attribute("disabled").unwrap();
    }
}
pub(super) fn set_busy(value: bool) {
    for id in IDS {
        disabled(id, value);
    }
}
fn session(app: &Rc<RefCell<App>>) -> Result<Session> {
    let s = app.borrow();
    if !s.wallet.connected {
        return Err("WALLET_NOT_CONNECTED");
    }
    let epoch = s.wallet.epoch;
    let weak = Rc::downgrade(app);
    Ok(Session {
        profile: s.profile.clone().ok_or("PROFILE_REQUIRED")?,
        voter: s.wallet.account.clone().ok_or("WALLET_NOT_CONNECTED")?,
        vault: s.vault.clone(),
        active: Rc::new(move || {
            weak.upgrade().is_some_and(|a| {
                let s = a.borrow();
                s.wallet.connected && s.wallet.epoch == epoch
            })
        }),
    })
}
fn selected(app: &App) -> Result<&CaseEvidence> {
    app.controls.selected.as_ref().ok_or("SELECT_CASE_FIRST")
}
fn local_record(app: &App, e: &CaseEvidence) -> Result<VoteRecord> {
    let p = app.profile.as_ref().ok_or("PROFILE_REQUIRED")?;
    let committed = [1, 2].contains(&e.snapshot.vote.committee);
    let committee = if committed {
        e.snapshot.vote.committee
    } else {
        case_actions(&e.snapshot, e.eligibility)
            .committee
            .ok_or("COMMIT_WINDOW_CLOSED")?
    };
    let context = VoteContext {
        chain_id: p.deployment.chain_id.to_string(),
        contract: p.deployment.moderation.address.clone(),
        voter: app.wallet.account.clone().ok_or("WALLET_NOT_CONNECTED")?,
        case_id: e.snapshot.case_id.to_decimal(),
        round: e.snapshot.case.challenges,
        committee,
    };
    if committed {
        return crate::saved_vote::matching_record(
            &context,
            &e.snapshot.vote.commitment,
            &app.vault.list_votes()?,
        );
    }
    app.vault.get_vote(&context)?.ok_or("SECRET_NOT_FOUND")
}
fn review_allowed(app: &App, e: &CaseEvidence, vote: u8) -> bool {
    let Some(r) = app.controls.review.as_ref() else {
        return false;
    };
    r.case_id == e.snapshot.case_id
        && r.meta_hash == e.snapshot.case.meta_hash
        && r.content_hash == e.snapshot.case.content_hash
        && r.round == e.snapshot.case.challenges
        && app
            .profile
            .as_ref()
            .is_some_and(|p| r.guidelines_hash == p.deployment.guidelines.hash)
        && r.guidelines_valid
        && input("guidelines-read").checked()
        && input("content-read").checked()
        && (vote == 2 || e.snapshot.case.action_type == 1 || r.metadata_valid)
}
pub(super) fn render(app: &App) {
    text(
        "vault-status",
        if app.vault.is_unlocked() {
            "Unlocked. Passwords are held only for this operation; the derived key stays in memory until locked."
        } else {
            "Locked."
        },
    );
    if app.busy {
        set_busy(true);
        return;
    }
    set_busy(false);
    let current = app.wallet.connected;
    for id in ["load-cases", "read-case", "load-review", "refresh-stake"] {
        disabled(id, !current);
    }
    disabled("next-cases", !current || app.controls.next.is_none());
    disabled("receipt", app.profile.is_none());
    if let (Some(profile), Some(voter)) = (&app.profile, &app.wallet.account) {
        if current {
            text(
                "public-history",
                &workflow::public_history(profile, voter)
                    .map(|rows| {
                        if rows.is_empty() {
                            "No saved transactions for this context.".into()
                        } else {
                            rows.join("\n")
                        }
                    })
                    .unwrap_or_else(|e| e.into()),
            );
        }
    }
    disabled("export-vault", !app.vault.is_unlocked());
    disabled("verify-backup", !app.vault.is_unlocked());
    for id in [
        "draft-approve",
        "draft-reject",
        "commit-vote",
        "reveal-vote",
        "approve-stake",
        "stake",
        "withdraw-stake",
    ] {
        disabled(id, true);
    }
    for (id, _) in ACTIONS {
        disabled(id, true);
    }
    if !current {
        return;
    }
    if let Some(e) = &app.controls.moderator {
        let m = &e.moderator;
        text("stake-status",&format!("Checked at block {}\nStaked: {}\nFrozen until: {}\nOpen votes: {}\nStake amount (base units): {}\nToken balance (base units): {}\nAllowance (base units): {}",e.source.number,m.staked,m.frozen_until,m.open_votes,e.funds.stake_amount,e.funds.balance,e.funds.allowance));
        let a = staking_actions(
            m,
            e.source.timestamp,
            e.funds.stake_amount,
            e.funds.balance,
            e.funds.allowance,
        );
        disabled("approve-stake", !a.approve_stake);
        disabled("stake", !a.stake);
        disabled("withdraw-stake", !a.withdraw);
    }
    let Ok(e) = selected(app) else {
        return;
    };
    let actions = case_actions(&e.snapshot, e.eligibility);
    let c = &e.snapshot.case;
    text("case-facts",&format!("Case {} · {}\nSource block {}\nFinal / preliminary verdict: {}\nReveals first / second: {} / {}\nVote settled: {}\nRound {} · phase deadline {} (chain seconds)",
        e.snapshot.case_id,actions.state,e.snapshot.source.number,
        match c.preliminary{1=>"Approve",2=>"Reject",_=>"Not drawn"},c.reveals_a,c.reveals_b,e.snapshot.vote.settled,c.challenges,c.phase_deadline));
    text(
        "action-status",
        &actions
            .actions
            .iter()
            .map(|a| {
                format!(
                    "{}: {}",
                    a.action.signature(),
                    if a.allowed { "Available" } else { a.reason }
                )
            })
            .collect::<Vec<_>>()
            .join("\n"),
    );
    for (id, action) in ACTIONS {
        disabled(id, !actions.allowed(*action));
    }
    let unlocked = app.vault.is_unlocked();
    disabled(
        "draft-approve",
        !unlocked || !actions.allowed(Action::Commit) || !review_allowed(app, e, 1),
    );
    disabled(
        "draft-reject",
        !unlocked || !actions.allowed(Action::Commit) || !review_allowed(app, e, 2),
    );
    let saved = local_record(app, e);
    disabled(
        "reveal-vote",
        !unlocked || saved.is_err() || !actions.allowed(Action::Reveal),
    );
    if e.snapshot.vote.settled {
        text(
            "saved-vote",
            "Your vote is settled. No further vote transaction is required for this case.",
        );
        return;
    }
    if !unlocked {
        text("saved-vote", "Private storage is locked. Unlock it to check the saved vote, or import your encrypted recovery file.");
        return;
    }
    if let Ok(v) = &saved {
        let covered = app.vault.is_backed_up(&v.context()).unwrap_or(false);
        text(
            "saved-vote",
            &format!(
                "{} vote saved privately. Recovery verified: {}.",
                if v.vote == 1 { "Approve" } else { "Reject" },
                covered
            ),
        );
        disabled(
            "commit-vote",
            !actions.allowed(Action::Commit) || !covered || !review_allowed(app, e, v.vote),
        );
    } else {
        text(
            "saved-vote",
            if saved.as_ref().err() == Some(&"SECRET_MISMATCH") {
                "The saved vote does not match your on-chain commitment. Import the matching recovery file."
            } else if [1, 2].contains(&e.snapshot.vote.committee) {
                "No saved secret matches your committed vote. Import the recovery file made for this vote."
            } else {
                "No saved draft for this case, round and committee. Prepare a vote when commit is available, or import an existing recovery file."
            },
        );
    }
}
#[derive(Clone, Copy)]
enum Command {
    Page(bool),
    Read,
    ReadStake,
    Review,
    Unlock,
    Export,
    Verify,
    Import,
    Draft(u8),
    Commit,
    Reveal,
    Action(Action),
    Stake(&'static str),
    Receipt,
}
fn confirmation(command: Command) -> Option<&'static str> {
    match command{
    Command::Commit=>Some("Commit the saved vote? This sends its commitment to the contract. Keep your verified recovery file and password."),
    Command::Reveal=>Some("Reveal the saved vote now? Its choice and salt will be sent to MetaMask, the RPC and the public chain. The finalized reveal guard must pass before disclosure."),
    Command::Action(_)|Command::Stake(_)=>Some("Prepare this contract transaction for confirmation in MetaMask?"),_=>None}
}
fn bind(app: Rc<RefCell<App>>, id: &str, command: Command) {
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if app.borrow().busy {
            return;
        }
        if let Some(message) = confirmation(command) {
            if !web_sys::window()
                .unwrap()
                .confirm_with_message(message)
                .unwrap_or(false)
            {
                return;
            }
        }
        let app = app.clone();
        busy(&app, true);
        spawn_local(async move {
            let result = execute(&app, command).await;
            if let Err(code) = result {
                notice(code);
            }
            busy(&app, false);
            render(&app.borrow());
        });
    });
    element(id)
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
}
async fn backup_text() -> Result<String> {
    let f = input("backup-file")
        .files()
        .and_then(|v| v.get(0))
        .ok_or("SELECT_RECOVERY_FILE")?;
    if f.size() > swarm_core::recovery::MAX_FILE_BYTES as f64 {
        return Err("BACKUP_TOO_LARGE");
    }
    JsFuture::from(f.text())
        .await
        .map_err(|_| "BACKUP_READ_FAILED")?
        .as_string()
        .ok_or("BACKUP_READ_FAILED")
}
fn take_password(id: &str) -> String {
    let f = input(id);
    let p = f.value();
    f.set_value("");
    p
}
fn download(text: &str) -> Result<()> {
    let parts = Array::of1(&text.into());
    let options = web_sys::BlobPropertyBag::new();
    options.set_type("application/json");
    let blob = web_sys::Blob::new_with_str_sequence_and_options(&parts, &options)
        .map_err(|_| "DOWNLOAD_FAILED")?;
    let url = web_sys::Url::create_object_url_with_blob(&blob).map_err(|_| "DOWNLOAD_FAILED")?;
    let anchor = document()
        .create_element("a")
        .map_err(|_| "DOWNLOAD_FAILED")?
        .dyn_into::<HtmlAnchorElement>()
        .map_err(|_| "DOWNLOAD_FAILED")?;
    anchor.set_href(&url);
    anchor.set_download(&format!(
        "swarm-review-recovery-{}.json",
        js_sys::Date::now() as u64
    ));
    anchor.click();
    // Keep the URL alive until the browser has started the asynchronous save.
    let cleanup = Closure::once_into_js(move || {
        let _ = web_sys::Url::revoke_object_url(&url);
    });
    web_sys::window()
        .unwrap()
        .set_timeout_with_callback_and_timeout_and_arguments_0(cleanup.unchecked_ref(), 1000)
        .map_err(|_| "DOWNLOAD_FAILED")?;
    Ok(())
}
fn choose(app: &Rc<RefCell<App>>, e: CaseEvidence) {
    app.borrow_mut().controls.moderator = Some(ModeratorEvidence {
        source: e.snapshot.source.clone(),
        moderator: e.snapshot.moderator.clone(),
        funds: e.funds.clone(),
    });
    app.borrow_mut().controls.review = None;
    app.borrow_mut().controls.selected = Some(e);
    input("guidelines-read").set_checked(false);
    input("content-read").set_checked(false);
    text("metadata", "Not loaded for this case.");
    text("guidelines", "Not loaded for this case.");
    element("content-link").remove_attribute("href").unwrap();
}
async fn show_case(app: &Rc<RefCell<App>>, s: &Session, id: Uint256) -> Result<()> {
    let e = s.read(id, "latest").await?;
    s.current()?;
    choose(app, e);
    render(&app.borrow());
    Ok(())
}
fn broadcast_result(app: &Rc<RefCell<App>>, s: &Session, result: Broadcast) {
    // A broadcast is not a receipt. Remove action availability from the old
    // snapshot, forcing an explicit fresh read before another transaction.
    app.borrow_mut().controls.clear_context();
    clear_dom();
    text(
        "verification",
        "Transaction broadcast. Refresh verified case state after checking its receipt.",
    );
    input("receipt-hash").set_value(&result.hash);
    text(
        "transaction",
        &format!(
            "Broadcast hash: {}\n{}\nUse Refresh transaction receipt before any retry.",
            result.hash,
            result
                .warning
                .unwrap_or("Wallet returned a broadcast hash; confirmation is not yet checked.")
        ),
    );
    app.borrow_mut().controls.last_transaction = Some((result.hash, s.profile.clone()));
    notice("Transaction hash saved. Refresh its receipt and case before any retry.");
}
async fn execute(app: &Rc<RefCell<App>>, command: Command) -> Result<()> {
    // Vault operations do not require wallet access and never call a provider.
    let vault = app.borrow().vault.clone();
    match command {
        Command::Unlock => {
            let p = take_password("vault-password");
            let n = vault.unlock(&p).await?;
            notice(&format!("Private storage unlocked: {n} saved votes."));
            return Ok(());
        }
        Command::Export => {
            let raw = vault.export_backup().await?;
            download(&raw)?;
            notice(
                "Recovery export prepared. Select the saved file and verify it before committing.",
            );
            return Ok(());
        }
        Command::Import | Command::Verify => {
            let epoch = app.borrow().wallet.epoch;
            let vault_generation = vault.generation();
            let p = take_password("backup-password");
            let raw = backup_text().await?;
            if app.borrow().wallet.epoch != epoch || vault.generation() != vault_generation {
                return Err("CONTEXT_CHANGED");
            }
            let p = if p.is_empty() { None } else { Some(p.as_str()) };
            let n = if matches!(command, Command::Import) {
                vault.import_backup(&raw, p).await?
            } else {
                vault.verify_backup(&raw, p).await?
            };
            notice(&format!("Recovery checked: {n} exact saved votes covered."));
            return Ok(());
        }
        Command::Receipt => {
            let hash = input("receipt-hash").value();
            let profile = {
                let state = app.borrow();
                match state.controls.last_transaction.as_ref() {
                    Some((old, p)) if old.eq_ignore_ascii_case(&hash) => p.clone(),
                    _ => state.profile.clone().ok_or("PROFILE_REQUIRED")?,
                }
            };
            let status = workflow::receipt(&profile, &hash).await?;
            text("transaction", &format!("{hash}\n{status}"));
            notice(status);
            return Ok(());
        }
        _ => {}
    }
    let s = session(app)?;
    match command {
        Command::ReadStake => {
            let evidence = evidence::read_moderator(&s.profile, &s.voter).await?;
            s.current()?;
            app.borrow_mut().controls.moderator = Some(evidence);
            notice("Stake and balance refreshed at a verified source block.");
        }
        Command::Page(next) => {
            let cursor = if next {
                app.borrow().controls.next.ok_or("NO_NEXT_PAGE")?
            } else {
                Uint256::from_u64(1)
            };
            let page = evidence::list_cases(&s.profile, &s.voter, cursor, 10).await?;
            s.current()?;
            text(
                "cases",
                &format!(
                    "Checked at block {}\n{}",
                    page.source.number,
                    page.cases
                        .iter()
                        .map(|e| format!(
                            "Case {} · {}",
                            e.snapshot.case_id,
                            case_actions(&e.snapshot, e.eligibility).state
                        ))
                        .collect::<Vec<_>>()
                        .join("\n")
                ),
            );
            app.borrow_mut().controls.next = page.next_cursor;
            notice("Case page verified at one canonical source block.");
        }
        Command::Read => {
            let id = Uint256::decimal(&input("case-id").value()).map_err(|e| e.0)?;
            show_case(app, &s, id).await?;
            notice("Selected case refreshed from verified evidence.");
        }
        Command::Review => {
            let e = selected(&app.borrow())?.clone();
            app.borrow_mut().controls.review = None;
            input("guidelines-read").set_checked(false);
            input("content-read").set_checked(false);
            let r =
                evidence::load_review(&s.profile, &e.snapshot.case.meta_hash, &e.topics).await?;
            s.current()?;
            let valid = r.metadata.is_some();
            let guidelines = r.guidelines_text.is_some();
            text(
                "metadata",
                &r.metadata
                    .as_ref()
                    .map(|m| {
                        format!(
                            "{}\n{}\nTopics: {}",
                            m.title,
                            m.description.as_deref().unwrap_or(""),
                            m.topics.join(", ")
                        )
                    })
                    .unwrap_or_else(|| {
                        format!(
                            "Metadata is invalid or unavailable: {}",
                            r.metadata_error.unwrap_or("UNKNOWN")
                        )
                    }),
            );
            text(
                "guidelines",
                &r.guidelines_text.clone().unwrap_or_else(|| {
                    format!(
                        "Pinned guideline content could not be verified: {}",
                        r.guidelines_error.unwrap_or("UNKNOWN")
                    )
                }),
            );
            if let Ok(url) = evidence::content_url(&s.profile, &e.snapshot.case.content_hash) {
                element("content-link")
                    .set_attribute("href", &url)
                    .map_err(|_| "INVALID_CONTENT_URL")?;
            }
            app.borrow_mut().controls.review = Some(ReviewBinding {
                case_id: e.snapshot.case_id,
                meta_hash: e.snapshot.case.meta_hash,
                content_hash: e.snapshot.case.content_hash,
                round: e.snapshot.case.challenges,
                guidelines_hash: s.profile.deployment.guidelines.hash.clone(),
                metadata_valid: valid,
                guidelines_valid: guidelines,
            });
            notice(if guidelines {
                "Review documents loaded. Read the guidelines and content before preparing a vote."
            } else {
                "Guidelines could not be authenticated. Vote preparation is blocked."
            });
        }
        Command::Draft(vote) => {
            let e = selected(&app.borrow())?.clone();
            if !review_allowed(&app.borrow(), &e, vote) {
                return Err("REVIEW_REQUIRED");
            }
            s.draft(e.snapshot.case_id, vote).await?;
            notice("Vote saved in encrypted local storage. Export and verify the recovery file before commit.");
        }
        Command::Commit => {
            let e = selected(&app.borrow())?.clone();
            let v = local_record(&app.borrow(), &e)?;
            if !review_allowed(&app.borrow(), &e, v.vote) {
                return Err("REVIEW_REQUIRED");
            }
            let result = s.commit(&v).await?;
            broadcast_result(app, &s, result);
        }
        Command::Reveal => {
            let id = selected(&app.borrow())?.snapshot.case_id;
            let result = s.reveal(id).await?;
            broadcast_result(app, &s, result);
        }
        Command::Action(action) => {
            let e = selected(&app.borrow())?.clone();
            let c = &e.snapshot.case;
            let result = s
                .action(e.snapshot.case_id, action, c.challenges, c.preliminary)
                .await?;
            broadcast_result(app, &s, result);
        }
        Command::Stake(action) => {
            let result = s.stake_action(action).await?;
            broadcast_result(app, &s, result);
        }
        _ => return Err("INVALID_ACTION"),
    }
    Ok(())
}
