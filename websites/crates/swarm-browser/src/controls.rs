//! Moderator UI bindings. Remote documents are always text, never HTML.
use super::{busy, document, element, text, App};
fn notice(value: &str) {
    text("notice", value);
}
use crate::{
    evidence::{self, CaseEvidence, ModeratorEvidence},
    moderator_view as view,
    workflow::{self, Broadcast, Session},
    BrowserResult as Result,
};
use js_sys::Array;
use std::{cell::RefCell, collections::BTreeSet, rc::Rc};
use swarm_core::{
    moderator::*,
    recovery::{VoteContext, VoteRecord},
    ModeratorProfile,
};
use wasm_bindgen::{closure::Closure, JsCast};
use wasm_bindgen_futures::{spawn_local, JsFuture};
use web_sys::{HtmlAnchorElement, HtmlInputElement};
#[path = "moderator/journey.rs"]
mod journey;
pub(super) fn install_journey(app: Rc<RefCell<App>>) {
    journey::install(app);
}
pub(super) fn show_notice(value: &str) {
    journey::show_notice(value);
}
pub(super) fn focus_source(id: &str) {
    journey::focus(id);
}

#[derive(Default)]
pub(super) struct State {
    selected: Option<CaseEvidence>,
    case_current: bool,
    moderator: Option<ModeratorEvidence>,
    next: Option<Uint256>,
    review: Option<ReviewBinding>,
    last_transaction: Option<TransactionReturn>,
    work_ids: Vec<Uint256>,
    work_next: usize,
    pending: Option<PendingReview>,
    changing: Option<VoteRecord>,
    journey: journey::State,
    work: Vec<(Uint256, Result<CaseEvidence>)>,
}
struct TransactionReturn {
    hash: String,
    voter: String,
    profile: ModeratorProfile,
    context: String,
    stake: bool,
    case_id: Option<Uint256>,
}
struct PendingReview {
    command: Command,
    wallet_epoch: u64,
    vault_generation: u64,
    case_id: Option<Uint256>,
    challenge_intent: Option<(u8, u8)>,
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
    pub(super) fn journey_cancelled(&mut self) {
        self.journey.operation = None;
        self.journey.operation_case = None;
    }
    pub(super) fn clear_context(&mut self) {
        self.selected = None;
        self.case_current = false;
        self.work.clear();
        self.journey.observed_at = None;
        self.journey.follow_case = None;
        self.moderator = None;
        self.next = None;
        self.review = None;
        self.work_ids.clear();
        self.work_next = 0;
        self.pending = None;
        self.changing = None;
    }
}
const IDS: &[&str] = &[
    "my-work",
    "more-work",
    "check-reveal",
    "refresh-vote-time",
    "refresh-action-time",
    "load-cases",
    "next-cases",
    "read-case",
    "case-id",
    "load-review",
    "guidelines-read",
    "content-read",
    "draft-approve",
    "draft-reject",
    "change-choice",
    "change-approve",
    "change-reject",
    "save-change",
    "cancel-change",
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
    "cache-outcome",
    "expire-outcome",
    "challenge",
    "finalize",
    "claim",
    "refund",
    "resume-request",
    "receipt",
    "receipt-hash",
];
const ACTIONS: &[(&str, Action)] = &[
    ("close-a", Action::CloseCommitA),
    ("close-b", Action::CloseCommitB),
    ("close-reveal", Action::CloseReveal),
    ("draw", Action::Draw),
    ("cache-outcome", Action::CacheOutcome),
    ("expire-outcome", Action::ExpireOutcome),
    ("challenge", Action::Challenge),
    ("finalize", Action::CloseChallenge),
    ("claim", Action::Claim),
    ("refund", Action::WithdrawRefund),
];

pub(super) fn mount(app: Rc<RefCell<App>>) {
    let confirm_app = app.clone();
    let confirm = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if confirm_app.borrow().busy {
            return;
        }
        let pending = confirm_app.borrow_mut().controls.pending.take();
        confirm_app.borrow_mut().controls.journey.operation = None;
        let Some(pending) = pending else {
            return;
        };
        element("action-review")
            .set_attribute("hidden", "")
            .unwrap();
        let valid = {
            let a = confirm_app.borrow();
            a.wallet.epoch == pending.wallet_epoch
                && a.vault.generation() == pending.vault_generation
                && a.controls.selected.as_ref().map(|e| e.snapshot.case_id) == pending.case_id
                && pending.challenge_intent.is_none_or(|intent| {
                    a.controls.selected.as_ref().is_some_and(|e| {
                        (e.snapshot.case.challenges, e.snapshot.case.preliminary) == intent
                    })
                })
        };
        busy(&confirm_app, false);
        if valid {
            perform(confirm_app.clone(), pending.command);
        } else {
            notice("The account, private storage or case changed. Review the current evidence and choose the action again. No wallet request was made by this confirmation.");
        }
    });
    element("confirm-action")
        .add_event_listener_with_callback("click", confirm.as_ref().unchecked_ref())
        .unwrap();
    confirm.forget();
    let cancel_app = app.clone();
    let cancel = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if cancel_app.borrow().busy {
            return;
        }
        let pending = cancel_app.borrow_mut().controls.pending.take();
        cancel_app.borrow_mut().controls.journey.operation = None;
        if let Some(pending) = pending {
            element("action-review")
                .set_attribute("hidden", "")
                .unwrap();
            text(
                feedback_id(pending.command),
                "Action cancelled. No wallet request was made.",
            );
            busy(&cancel_app, false);
            let owner = element(feedback_id(pending.command))
                .closest("[data-view]")
                .ok()
                .flatten()
                .and_then(|e| e.get_attribute("data-view"));
            if owner.as_deref() == Some(cancel_app.borrow().controls.journey.view.name()) {
                focus_note(feedback_id(pending.command));
            } else {
                journey::focus_current(&cancel_app.borrow());
            }
        } else {
            busy(&cancel_app, false);
        }
    });
    element("cancel-action")
        .add_event_listener_with_callback("click", cancel.as_ref().unchecked_ref())
        .unwrap();
    cancel.forget();
    bind(app.clone(), "my-work", Command::Work(false));
    bind(app.clone(), "more-work", Command::Work(true));
    bind(app.clone(), "load-cases", Command::Page(false));
    bind(app.clone(), "next-cases", Command::Page(true));
    bind(app.clone(), "read-case", Command::Read);
    bind(app.clone(), "refresh-vote-time", Command::RefreshSelected);
    bind(app.clone(), "refresh-action-time", Command::RefreshSelected);
    bind(app.clone(), "refresh-stake", Command::ReadStake);
    bind(app.clone(), "load-review", Command::Review);
    bind(app.clone(), "unlock-vault", Command::Unlock);
    bind(app.clone(), "export-vault", Command::Export);
    bind(app.clone(), "verify-backup", Command::Verify);
    bind(app.clone(), "import-backup", Command::Import);
    bind(app.clone(), "draft-approve", Command::Draft(1));
    bind(app.clone(), "draft-reject", Command::Draft(2));
    for (id, editing) in [("change-choice", true), ("cancel-change", false)] {
        let a = app.clone();
        let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            if a.borrow().busy || a.borrow().controls.pending.is_some() {
                return;
            }
            let record = if editing {
                selected(&a.borrow())
                    .and_then(|e| local_record(&a.borrow(), e))
                    .ok()
            } else {
                None
            };
            if record
                .as_ref()
                .is_some_and(|v| !a.borrow().vault.can_correct(v))
            {
                return;
            }
            if let Some(v) = &record {
                input("change-approve").set_checked(v.vote == 1);
                input("change-reject").set_checked(v.vote == 2);
            }
            a.borrow_mut().controls.changing = record;
            text(
                "vote-note",
                if editing {
                    ""
                } else {
                    "Change cancelled. Your saved choice is unchanged."
                },
            );
            render(&a.borrow());
            journey::focus(if editing {
                "change-approve"
            } else {
                "choice-heading"
            });
        });
        element(id)
            .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
            .unwrap();
        handler.forget();
    }
    let a = app.clone();
    let save = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        dispatch(
            a.clone(),
            Command::Change(if input("change-approve").checked() {
                1
            } else {
                2
            }),
        );
    });
    element("save-change")
        .add_event_listener_with_callback("click", save.as_ref().unchecked_ref())
        .unwrap();
    save.forget();
    for id in ["change-approve", "change-reject"] {
        let a = app.clone();
        let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| render(&a.borrow()));
        element(id)
            .add_event_listener_with_callback("change", handler.as_ref().unchecked_ref())
            .unwrap();
        handler.forget();
    }
    bind(app.clone(), "commit-vote", Command::Commit);
    bind(app.clone(), "reveal-vote", Command::Reveal);
    bind(app.clone(), "check-reveal", Command::CheckReveal);
    let work_app = app.clone();
    let open_work = Closure::<dyn FnMut(web_sys::Event)>::new(move |event: web_sys::Event| {
        let Some(target) = event
            .target()
            .and_then(|t| t.dyn_into::<web_sys::Element>().ok())
        else {
            return;
        };
        let Some(id) = target.get_attribute("data-work-case") else {
            return;
        };
        if let Ok(id) = Uint256::decimal(&id) {
            dispatch(work_app.clone(), Command::Open(id));
        }
    });
    for id in ["work-list", "browse-list"] {
        element(id)
            .add_event_listener_with_callback("click", open_work.as_ref().unchecked_ref())
            .unwrap();
    }
    open_work.forget();
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
    bind(app.clone(), "resume-request", Command::ResumeRequest);
    let copy = app.clone();
    let lock = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        copy.borrow().vault.lock();
        copy.borrow_mut().controls.pending = None;
        if !copy.borrow().busy {
            copy.borrow_mut().controls.journey.operation = None;
        }
        element("action-review")
            .set_attribute("hidden", "")
            .unwrap();
        copy.borrow_mut().controls.work.clear();
        copy.borrow_mut().controls.work_ids.clear();
        copy.borrow_mut().controls.work_next = 0;
        element("work-list").set_text_content(None);
        text(
            "work-note",
            "Private storage locked. Refresh My work after unlocking to include saved votes.",
        );
        text("vault-password", "");
        input("vault-password").set_value("");
        input("backup-password").set_value("");
        let was_busy = copy.borrow().busy;
        if !was_busy {
            busy(&copy, false);
        }
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
    let selection_app = app.clone();
    let changed = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        selection_app.borrow_mut().controls.selected = None;
        selection_app.borrow_mut().controls.journey.follow_case = None;
        selection_app.borrow_mut().controls.case_current = false;
        selection_app.borrow_mut().controls.review = None;
        for (id, message) in [
            (
                "case-facts",
                "Case selection changed. Read the case to load its verified evidence.",
            ),
            ("metadata", "Not loaded for this case."),
            ("guidelines", "Not loaded for this case."),
            ("case-note", "Read the entered case to verify its evidence."),
            (
                "reveal-status",
                "Case selection changed. Readiness has not been checked for the new case.",
            ),
            (
                "saved-vote",
                "Read a case to see its matching saved choice.",
            ),
        ] {
            text(id, message);
        }
        input("guidelines-read").set_checked(false);
        input("content-read").set_checked(false);
        element("content-link").remove_attribute("href").unwrap();
        render(&selection_app.borrow());
    });
    element("case-id")
        .add_event_listener_with_callback("input", changed.as_ref().unchecked_ref())
        .unwrap();
    changed.forget();
    let copy = app.clone();
    let enter =
        Closure::<dyn FnMut(web_sys::KeyboardEvent)>::new(move |event: web_sys::KeyboardEvent| {
            if event.key() == "Enter" {
                event.prevent_default();
                dispatch(copy.clone(), Command::Read);
            }
        });
    element("case-id")
        .add_event_listener_with_callback("keydown", enter.as_ref().unchecked_ref())
        .unwrap();
    enter.forget();
    render(&app.borrow());
}
pub(super) fn clear_dom() {
    element("action-review")
        .set_attribute("hidden", "")
        .unwrap();
    for (id, message) in [
        ("cases", "Evidence cleared after context changed."),
        ("case-facts", "No selected case."),
        ("metadata", "Not loaded."),
        ("guidelines", "Not loaded."),
        (
            "saved-vote",
            "Open a case to see its matching private choice.",
        ),
        ("stake-status", "Not checked for this wallet."),
        ("action-status", "No current evidence."),
        ("phase-timing", "Read a case for its timing and next step."),
        ("public-history", "Connect to load public history."),
        (
            "next-step",
            "Connect the intended account, then refresh My work or choose a case.",
        ),
        (
            "work-note",
            "Refresh My work after reconnecting. Unlock storage to include private saved votes.",
        ),
        (
            "reveal-status",
            "Readiness has not been checked. Revealing always repeats the full guard.",
        ),
    ] {
        text(id, message);
    }
    element("work-list").set_text_content(None);
    element("browse-list").set_text_content(None);
    for id in [
        "case-note",
        "review-note",
        "vault-note",
        "vote-note",
        "stake-note",
        "actions-note",
    ] {
        text(id, "");
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
    for list in ["work-list", "browse-list"] {
        let buttons = element(list).get_elements_by_tag_name("button");
        for i in 0..buttons.length() {
            if let Some(button) = buttons.item(i) {
                if value {
                    button.set_attribute("disabled", "").unwrap();
                } else {
                    button.remove_attribute("disabled").unwrap();
                }
            }
        }
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
        request_boundary: None,
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
    if !app.controls.case_current {
        return Err("CASE_EVIDENCE_REQUIRED: refresh the case before continuing.");
    }
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
        && e.snapshot.case.action_type <= 1
        && (vote == 2 || e.snapshot.case.action_type == 1 || r.metadata_valid)
}
pub(super) fn wallet_selection_locked(app: &App) -> bool {
    app.busy || app.controls.pending.is_some()
}
pub(super) fn render(app: &App) {
    crate::wallet::render_picker("wallet-picker", wallet_selection_locked(app));
    journey::render(app);
    disabled("resume-case", app.busy);
    disabled("use-profile", app.busy || app.candidate.is_none());
    disabled("connect", app.busy || app.profile.is_none());
    disabled("refresh", app.busy || !app.wallet.connected);
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
    if app.controls.pending.is_some() {
        set_busy(true);
        return;
    }
    let current = app.wallet.connected;
    if app.controls.selected.is_none() {
        text(
            "next-step",
            if current && app.vault.is_unlocked() {
                "Refresh my work to find saved votes, or choose a case from the review queue. New moderators can check Stake first."
            } else if current {
                "To resume, unlock private storage and Refresh my work. To start reviewing, choose a case from the review queue. New moderators can check Stake first."
            } else if app.profile.is_some() {
                "Connect your intended account. Then unlock private storage to resume saved work, or choose a case to review."
            } else {
                "Load the deployment profile supplied by your operator, then connect your intended account."
            },
        );
    }
    for id in ["load-cases", "read-case", "load-review", "refresh-stake"] {
        disabled(id, !current);
    }
    disabled("next-cases", !current || app.controls.next.is_none());
    disabled("my-work", !current);
    disabled(
        "more-work",
        !current || app.controls.work_next >= app.controls.work_ids.len(),
    );
    disabled("receipt", app.profile.is_none());
    let pending = match (&app.profile, &app.wallet.account) {
        (Some(p), Some(v)) => crate::moderator_requests::summary(p, v).unwrap_or_else(|_| {
            Some(
                "Saved requests could not be read. Sending is blocked; keep this site's data."
                    .into(),
            )
        }),
        _ => None,
    };
    text("unfinished-request-text", pending.as_deref().unwrap_or(""));
    journey::hidden("unfinished-request", pending.is_none());
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
    journey::hidden("change-choice", true);
    journey::hidden("change-editor", true);
    disabled("export-vault", !app.vault.is_unlocked());
    disabled("verify-backup", !app.vault.is_unlocked());
    for id in [
        "draft-approve",
        "draft-reject",
        "commit-vote",
        "reveal-vote",
        "check-reveal",
        "approve-stake",
        "stake",
        "withdraw-stake",
    ] {
        disabled(id, true);
    }
    for (id, _) in ACTIONS {
        disabled(id, true);
    }
    disabled(
        "refresh-vote-time",
        !current || app.controls.selected.is_none(),
    );
    disabled(
        "refresh-action-time",
        !current || app.controls.selected.is_none(),
    );
    if !current {
        return;
    }
    if let Some(e) = &app.controls.moderator {
        let m = &e.moderator;
        let display = app.profile.as_ref().and_then(|p| p.display.as_ref());
        text("stake-status", &format!("Checked at block {}\nStaked: {} · open votes: {}\nFrozen until: {}\nStake: {}\nBalance: {}\nAllowance to the pinned stake registry: {}", e.source.number, m.staked, m.open_votes, if m.frozen_until == 0 { "No frozen time recorded".into() } else { moment(m.frozen_until) }, crate::token_amounts::describe(e.funds.stake_amount, display), crate::token_amounts::describe(e.funds.balance, display), crate::token_amounts::describe(e.funds.allowance, display)));
        let a = staking_actions(
            m,
            e.source.timestamp,
            e.funds.stake_amount,
            e.funds.balance,
            e.funds.allowance,
        );
        disabled("approve-stake", pending.is_some() || !a.approve_stake);
        disabled("stake", pending.is_some() || !a.stake);
        disabled("withdraw-stake", pending.is_some() || !a.withdraw);
    }
    let Ok(e) = selected(app) else {
        return;
    };
    let actions = case_actions(&e.snapshot, e.eligibility);
    let c = &e.snapshot.case;
    text(
        "draft-approve",
        &format!("Save private choice: {}", view::choice(c.action_type, 1)),
    );
    text(
        "draft-reject",
        &format!("Save private choice: {}", view::choice(c.action_type, 2)),
    );
    text("case-facts", &case_summary(e));
    text(
        "phase-timing",
        &format!(
            "{}\n{}",
            case_time(e),
            view::next_step(&e.snapshot, e.eligibility)
        ),
    );
    text(
        "action-status",
        &actions
            .actions
            .iter()
            .map(|a| {
                format!(
                    "{}: {}",
                    a.action.signature(),
                    if a.action == Action::Challenge && !e.challenge_bound {
                        "Bound challenge support has not been verified for this deployment"
                    } else if a.action == Action::Draw {
                        view::draw_action_label(&e.snapshot)
                    } else if a.allowed {
                        "Available at this read"
                    } else {
                        a.reason
                    }
                )
            })
            .collect::<Vec<_>>()
            .join("\n"),
    );
    for (id, action) in ACTIONS {
        disabled(
            id,
            pending.is_some()
                || !actions.allowed(*action)
                || *action == Action::Challenge && !e.challenge_bound
                || [Action::Draw, Action::CacheOutcome].contains(action)
                    && view::draw_request_hold(&e.snapshot).is_some(),
        );
    }
    journey::hidden(
        "cache-outcome",
        !actions.allowed(Action::CacheOutcome) || view::draw_request_hold(&e.snapshot).is_some(),
    );
    journey::hidden("expire-outcome", !actions.allowed(Action::ExpireOutcome));
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
    let correctable = pending.is_none()
        && actions.allowed(Action::Commit)
        && saved.as_ref().is_ok_and(|v| app.vault.can_correct(v));
    let editing = correctable
        && app
            .controls
            .changing
            .as_ref()
            .is_some_and(|v| saved.as_ref().is_ok_and(|current| current == v));
    let participation_note = view::participation_block(&e.snapshot, e.eligibility)
        .map(|block| view::participation_note(block, &moment(e.snapshot.moderator.frozen_until)));
    text(
        "next-step",
        if pending.is_some() {
            "Check the unfinished transaction before another send."
        } else if editing {
            "Choose the correction, then Save change. Cancel keeps your saved choice."
        } else if actions.allowed(Action::Commit) {
            view::preparation_step(
                review_allowed(app, e, 2),
                unlocked,
                saved.is_ok(),
                saved
                    .as_ref()
                    .is_ok_and(|v| app.vault.is_backed_up(&v.context()).unwrap_or(false)),
            )
        } else if actions.allowed(Action::Reveal) {
            "Check readiness, then reveal. Both guards run again before disclosure."
        } else if let Some(note) = participation_note.as_deref() {
            note
        } else {
            view::own_duty(&e.snapshot, e.eligibility)
        },
    );
    journey::hidden("change-choice", !correctable || editing);
    journey::hidden("change-editor", !editing);
    journey::hidden(
        "prepare-controls",
        saved.is_ok() || !actions.allowed(Action::Commit),
    );
    journey::hidden(
        "commit-controls",
        editing || !actions.allowed(Action::Commit),
    );
    disabled("change-choice", !correctable);
    disabled(
        "save-change",
        !editing
            || saved
                .as_ref()
                .is_ok_and(|v| (v.vote == 1) == input("change-approve").checked())
            || !review_allowed(
                app,
                e,
                if input("change-approve").checked() {
                    1
                } else {
                    2
                },
            ),
    );
    text("change-approve-label", view::choice(c.action_type, 1));
    text("change-reject-label", view::choice(c.action_type, 2));
    if saved.is_ok() {
        disabled("draft-approve", true);
        disabled("draft-reject", true);
    }
    disabled(
        "reveal-vote",
        pending.is_some() || !unlocked || saved.is_err() || !actions.allowed(Action::Reveal),
    );
    disabled(
        "check-reveal",
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
        text("saved-vote", "Private storage is locked. Unlock the existing vault to find this vote. For a recovery file, read the safe restoration instructions in Private vote storage and recovery.");
        return;
    }
    if let Ok(v) = &saved {
        let covered = app.vault.is_backed_up(&v.context()).unwrap_or(false);
        text(
            "saved-vote",
            &if [1, 2].contains(&e.snapshot.vote.committee) {
                format!(
                    "Saved choice: {}. Keep recovery until settlement.",
                    view::choice(c.action_type, v.vote)
                )
            } else {
                format!(
                    "Private choice: {}.\n{}",
                    view::choice(c.action_type, v.vote),
                    if covered {
                        "Recovery verified."
                    } else {
                        "Save and verify recovery before committing."
                    }
                )
            },
        );
        disabled(
            "commit-vote",
            pending.is_some()
                || !actions.allowed(Action::Commit)
                || !covered
                || !review_allowed(app, e, v.vote),
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
    Work(bool),
    Open(Uint256),
    Page(bool),
    Read,
    RefreshSelected,
    ReadStake,
    Review,
    Unlock,
    Export,
    Verify,
    Import,
    Draft(u8),
    Change(u8),
    Commit,
    Reveal,
    CheckReveal,
    Action(Action),
    Stake(&'static str),
    Receipt,
    ResumeRequest,
}
fn confirmation(app: &App, command: Command) -> Option<String> {
    if matches!(command, Command::Stake(_)) {
        return Some(format!(
            "{}\n\nContinue to wallet to review and confirm?",
            action_context(app, command)
        ));
    }
    let context = app.controls.selected.as_ref();
    let identity = format!(
        "Account: {}\nChain: {}",
        app.wallet.account.as_deref().unwrap_or("not connected"),
        app.profile
            .as_ref()
            .map(|p| p.deployment.chain_id.to_string())
            .unwrap_or_default()
    );
    let case = context
        .map(|e| {
            format!(
                "Case {} · round {}\n{}",
                e.snapshot.case_id,
                e.snapshot.case.challenges,
                view::question(&e.snapshot.case)
            )
        })
        .unwrap_or_default();
    let message = match command {
        Command::Draft(vote) => format!("Save this private choice?\n{}\nNo transaction is sent.", context.map(|e|view::choice(e.snapshot.case.action_type,vote)).unwrap_or("No case selected")),
        Command::Change(vote) => format!("Change the saved choice to: {}?\nNo transaction is sent. Save and verify new recovery before committing.", context.map(|e|view::choice(e.snapshot.case.action_type,vote)).unwrap_or("No case selected")),
        Command::Commit => format!("Commit the saved choice: {}?\nYou must return to reveal before the deadline, then settle after the case ends. Missing reveal can add frozen time. Keep your verified recovery file and password.", context.and_then(|e|local_record(app,e).ok().map(|v|view::choice(e.snapshot.case.action_type,v.vote))).unwrap_or("No matching choice")),
        Command::Reveal => "Reveal the saved choice and salt publicly? The full finalized-state and inclusion-time guard must pass before disclosure, even after an earlier readiness check.".into(),
        Command::Action(Action::Challenge) => format!("Challenge this outcome? This records a PUBLIC vote for: {}. It creates a vote you must settle and can add frozen time if incoherent with the final result. Your stake is not slashed.",context.map(|e|view::choice(e.snapshot.case.action_type, match e.snapshot.case.preliminary {1=>2,2=>1,_=>0})).unwrap_or("No outcome selected")),
        Command::Action(Action::CacheOutcome) => "Save the original draw hash on chain. This does not draw an outcome or move the fee.".into(),
        Command::Action(Action::ExpireOutcome) => {
            match app.controls.selected.as_ref().map(|e| e.snapshot.case.challenges) {
                Some(0) => "End this expired initial draw as unresolved. The submitter can recover the fee; revealers get no reward or outcome freeze. Non-reveal penalties remain.".into(),
                _ => app.controls.selected.as_ref().map(|e| format!(
                    "Finalize the last completed outcome: {}. Ordinary rewards and freezes apply to all votes, including the challenger. This fallback does not prove responsibility for the failed draw.",
                    view::choice(e.snapshot.case.action_type, e.snapshot.case.preliminary)
                )).unwrap_or_else(|| "Refresh the selected case first.".into()),
            }
        }
        Command::Action(Action::Claim) => "Settle this vote? Depending on the verified final result, settlement may pay a reward, pay nothing, or add frozen time. It closes the vote obligation.".into(),
        Command::Action(_) | Command::Stake(_) => "Prepare this contract transaction for explicit confirmation in wallet? Read its destination and amounts in the wallet.".into(),
        _ => return None,
    };
    Some(format!("{case}\n{message}\n\n{identity}"))
}
fn bind(app: Rc<RefCell<App>>, id: &str, command: Command) {
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        dispatch(app.clone(), command);
    });
    element(id)
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
}
fn feedback_id(command: Command) -> &'static str {
    match command {
        Command::Work(_) => "work-note",
        Command::Page(_) | Command::Read | Command::RefreshSelected | Command::Open(_) => {
            "case-note"
        }
        Command::Review => "review-note",
        Command::Unlock | Command::Export | Command::Import | Command::Verify => "vault-note",
        Command::Draft(_)
        | Command::Change(_)
        | Command::Commit
        | Command::Reveal
        | Command::CheckReveal => "vote-note",
        Command::ReadStake | Command::Stake(_) => "stake-note",
        Command::Action(Action::Challenge) => "challenge-note",
        Command::Action(_) => "actions-note",
        Command::Receipt | Command::ResumeRequest => "transaction-note",
    }
}
fn focus_note(id: &str) {
    journey::focus(id);
}

fn dispatch(app: Rc<RefCell<App>>, command: Command) {
    if matches!(command, Command::Action(Action::Challenge))
        && !selected(&app.borrow()).is_ok_and(|e| e.challenge_bound)
    {
        notice("Bound challenges are unavailable for this deployment. Refresh the case to check support.");
        return;
    }
    if app.borrow().busy || app.borrow().controls.pending.is_some() {
        return;
    }
    let message = confirmation(&app.borrow(), command);
    if let Some(message) = message {
        text("action-review-text", &message);
        element("action-review").remove_attribute("hidden").unwrap();
        let mut a = app.borrow_mut();
        a.controls.journey.operation = Some(action_context(&a, command));
        a.controls.pending = Some(PendingReview {
            command,
            wallet_epoch: a.wallet.epoch,
            vault_generation: a.vault.generation(),
            case_id: a.controls.selected.as_ref().map(|e| e.snapshot.case_id),
            challenge_intent: if matches!(command, Command::Action(Action::Challenge)) {
                a.controls
                    .selected
                    .as_ref()
                    .map(|e| (e.snapshot.case.challenges, e.snapshot.case.preliminary))
            } else {
                None
            },
        });
        render(&a);
        drop(a);
        let _ = element("action-review")
            .dyn_into::<web_sys::HtmlElement>()
            .unwrap()
            .focus();
        return;
    }
    perform(app, command);
}
fn command_name(command: Command) -> &'static str {
    match command {
        Command::Draft(_) => "Save private choice",
        Command::Change(_) => "Change private choice",
        Command::Commit => "Commit saved vote",
        Command::Reveal => "Reveal saved vote",
        Command::Action(Action::Challenge) => "Challenge outcome",
        Command::Action(Action::Claim) => "Settle vote",
        Command::Action(Action::WithdrawRefund) => "Withdraw refund",
        Command::Action(Action::CacheOutcome) => "Save original draw hash",
        Command::Action(Action::ExpireOutcome) => "Complete expired draw",
        Command::Action(_) => "Advance case",
        Command::Stake("approveStake") => "Approve exact stake amount",
        Command::Stake("stake") => "Stake",
        Command::Stake("withdraw") => "Withdraw stake",
        Command::Stake(_) => "Stake action",
        _ => "Read or update local evidence",
    }
}
fn action_context(app: &App, command: Command) -> String {
    if let Command::Stake(action) = command {
        let Some(p) = &app.profile else {
            return "Choose a deployment profile first.".into();
        };
        let d = &p.deployment;
        let amount = app
            .controls
            .moderator
            .as_ref()
            .map(|e| crate::token_amounts::describe(e.funds.stake_amount, p.display.as_ref()))
            .unwrap_or_else(|| "Refresh Stake to read the amount.".into());
        let destination = if action == "approveStake" {
            format!(
                "Token contract: {}\nSpender: {}",
                d.token.address, d.stakes.address
            )
        } else {
            format!(
                "Stake registry: {}\nToken: {}",
                d.stakes.address, d.token.address
            )
        };
        let effect = match action {
            "approveStake" => "Sets the registry's exact token allowance; does not stake yet.",
            "stake" => "Deposits tokens in the stake registry.",
            "withdraw" => "Returns the stake to your account; ends eligibility for new votes.",
            _ => "",
        };
        return format!(
            "{} · {}\n{}\nAccount: {}\nChain: {}\n{}\nNavigation does not cancel a wallet request.",
            command_name(command),
            amount,
            effect,
            app.wallet.account.as_deref().unwrap_or("not connected"),
            d.chain_id,
            destination
        );
    }

    let name = if matches!(command, Command::Action(Action::Challenge)) {
        app.controls
            .selected
            .as_ref()
            .map(|e| {
                format!(
                    "Challenge outcome: {}",
                    view::choice(
                        e.snapshot.case.action_type,
                        if e.snapshot.case.preliminary == 1 {
                            2
                        } else {
                            1
                        }
                    )
                )
            })
            .unwrap_or_else(|| "Challenge outcome".into())
    } else {
        command_name(command).into()
    };
    format!("{} · {}\nAccount: {}\nChain: {} · Moderation: {}\nNavigation does not cancel a wallet request.",name, app.controls.selected.as_ref().map(|e|format!("Case {} · round {}", e.snapshot.case_id,e.snapshot.case.challenges)).unwrap_or_else(||"Stake / account action".into()), app.wallet.account.as_deref().unwrap_or("not connected"), app.profile.as_ref().map(|p|p.deployment.chain_id.to_string()).unwrap_or_default(),app.profile.as_ref().map(|p|p.deployment.moderation.address.as_str()).unwrap_or("not configured"))
}
fn perform(app: Rc<RefCell<App>>, command: Command) {
    let (revision, owner) = {
        let a = app.borrow();
        (a.controls.journey.revision, a.controls.journey.view)
    };
    let is_send = matches!(
        command,
        Command::Commit | Command::Reveal | Command::Action(_) | Command::Stake(_)
    );
    if is_send {
        let context = action_context(&app.borrow(), command);
        let id = app
            .borrow()
            .controls
            .selected
            .as_ref()
            .map(|e| e.snapshot.case_id);
        app.borrow_mut().controls.journey.operation_case = if matches!(command, Command::Stake(_)) {
            None
        } else {
            id
        };
        app.borrow_mut().controls.journey.operation = Some(context);
    }
    text(
        feedback_id(command),
        if is_send {
            "Checking current evidence, then waiting for your wallet. No automatic retries."
        } else {
            "Working…"
        },
    );
    text("notice", "Action finished. Read its result below.");
    text(&format!("notice-{}", owner.name()), "");
    busy(&app, true);
    spawn_local(async move {
        let result = coordinated(&app, command).await;
        if let Err(code) = result {
            notice(&view::error(code));
            if matches!(command, Command::Reveal) {
                text(
                    "reveal-result",
                    if code == "REQUEST_UNRESOLVED" {
                        "Transaction outcome unknown. Check this transaction before another send."
                    } else {
                        "Reveal not completed. Read the result above before another attempt."
                    },
                );
            }
        }
        let message = element("notice").text_content().unwrap_or_default();
        text(feedback_id(command), &message);
        let feedback_owner = element(feedback_id(command))
            .closest("[data-view]")
            .ok()
            .flatten()
            .and_then(|e| e.get_attribute("data-view"));
        text(
            &format!("notice-{}", owner.name()),
            if feedback_owner.as_deref() == Some(owner.name())
                && element(feedback_id(command))
                    .closest("[hidden]")
                    .ok()
                    .flatten()
                    .is_none()
            {
                ""
            } else {
                &message
            },
        );
        if is_send {
            app.borrow_mut().controls.journey.operation = None;
            app.borrow_mut().controls.journey.operation_case = None;
        }
        busy(&app, false);
        let unchanged = app.borrow().controls.journey.revision == revision;
        if unchanged {
            if result.is_ok() && matches!(command, Command::Open(_) | Command::Read) {
                journey::show(&app, journey::View::Case, false);
            } else if result.is_ok() && matches!(command, Command::Draft(_) | Command::Change(_)) {
                journey::focus("choice-heading");
            } else if result.is_ok() && is_send {
                journey::show(&app, journey::View::Records, false);
            } else if matches!(command, Command::CheckReveal) && result.is_ok() {
                focus_note("reveal-result");
            } else if feedback_owner.as_deref() == Some(owner.name())
                && element(feedback_id(command))
                    .closest("[hidden]")
                    .ok()
                    .flatten()
                    .is_none()
            {
                focus_note(feedback_id(command));
            } else {
                focus_note(&format!("notice-{}", owner.name()));
            }
        }
        // This explicit return action targets an enabled input, after generic
        // result focus has run, including when already in Transactions.
        if matches!(command, Command::ResumeRequest)
            && app.borrow().controls.journey.view == journey::View::Records
        {
            journey::focus("receipt-hash");
        }
    });
}

fn moment(seconds: u64) -> String {
    format!(
        "{} (UTC)",
        String::from(js_sys::Date::new(&((seconds as f64) * 1000.0).into()).to_iso_string())
    )
}
fn case_time(e: &CaseEvidence) -> String {
    let s = &e.snapshot;
    let mut time = view::deadline(s)
        .map(|(label, deadline)| {
            format!(
                "{label}: {}\n{} (as of this read)",
                moment(deadline),
                if deadline > s.source.timestamp {
                    format!(
                        "Time remaining: {}",
                        view::duration(deadline - s.source.timestamp)
                    )
                } else {
                    "Deadline reached".into()
                }
            )
        })
        .unwrap_or_default();
    if let Some(draw) = view::draw_guidance(s) {
        time = draw;
    }
    time
}
fn case_summary(e: &CaseEvidence) -> String {
    let s = &e.snapshot;
    let c = &s.case;
    let time = case_time(e);
    format!("Case {} · {}\n{}\nContent: {}\nMetadata: {}\nSource: block {}, {}\n{}\n{} verdict: {}\nReveals A / B: {} / {} · round {}\nYour vote settled: {}\nRefresh this case for current time and action availability.",
        s.case_id,case_actions(s,e.eligibility).state,view::question(c),c.content_hash,c.meta_hash,s.source.number,moment(s.source.timestamp),time,
        if c.phase == 5 {"Final"} else {"Preliminary"}, if c.preliminary == 0 {"Not drawn"} else {view::choice(c.action_type,c.preliminary)},c.reveals_a,c.reveals_b,c.challenges,if s.vote.settled {"Yes"} else {"No"})
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
    let keep = app.borrow().controls.review.as_ref().is_some_and(|r| {
        r.case_id == e.snapshot.case_id
            && r.meta_hash == e.snapshot.case.meta_hash
            && r.content_hash == e.snapshot.case.content_hash
            && r.round == e.snapshot.case.challenges
            && app
                .borrow()
                .profile
                .as_ref()
                .is_some_and(|p| p.deployment.guidelines.hash == r.guidelines_hash)
    });
    let changed = app
        .borrow()
        .controls
        .selected
        .as_ref()
        .is_none_or(|old| old.snapshot.case_id != e.snapshot.case_id);
    let preparing = case_actions(&e.snapshot, e.eligibility).allowed(Action::Commit);
    {
        let mut a = app.borrow_mut();
        a.controls.moderator = Some(ModeratorEvidence {
            source: e.snapshot.source.clone(),
            moderator: e.snapshot.moderator.clone(),
            funds: e.funds.clone(),
        });
        a.controls.journey.observed_at = journey::now();
        a.controls.journey.returned = false;
        a.controls.journey.follow_case = Some(e.snapshot.case_id);
        a.controls.selected = Some(e);
        a.controls.case_current = true;
        if !keep {
            a.controls.review = None;
            a.controls.changing = None;
        }
    }
    if !keep {
        input("guidelines-read").set_checked(false);
        input("content-read").set_checked(false);
        text(
            "metadata",
            "Load the authenticated review documents for this case.",
        );
        text("guidelines", "Not loaded for this case.");
        element("content-link").remove_attribute("href").unwrap();
    }
    if changed {
        if preparing {
            element("review-documents")
                .set_attribute("open", "")
                .unwrap();
        } else {
            element("review-documents")
                .remove_attribute("open")
                .unwrap();
        }
    }
    for id in ["vote-note", "actions-note", "challenge-note", "review-note"] {
        text(id, "");
    }
    text(
        "reveal-result",
        "Readiness has not been checked for this evidence.",
    );
    text(
        "reveal-status",
        "Reveal repeats both finalized-state and time guards before disclosure.",
    );
}

async fn show_case(app: &Rc<RefCell<App>>, s: &Session, id: Uint256) -> Result<()> {
    app.borrow_mut().controls.case_current = false;
    text(
        "reveal-result",
        "Refreshing case evidence. Previous readiness must not be reused.",
    );
    let e = s.read(id, "latest").await?;
    s.current()?;
    choose(app, e);
    render(&app.borrow());
    Ok(())
}
fn broadcast_result(app: &Rc<RefCell<App>>, s: &Session, result: Broadcast, stake: bool) {
    // A broadcast is not a receipt. Remove action availability from the old
    // snapshot, forcing an explicit fresh read before another transaction.
    let follow = app.borrow().controls.journey.operation_case;
    let original = app
        .borrow()
        .controls
        .journey
        .operation
        .clone()
        .unwrap_or_default();
    app.borrow_mut().controls.clear_context();
    app.borrow_mut().controls.journey.follow_case = follow;
    clear_dom();
    text(
        "verification",
        if stake {
            "Transaction broadcast. Check its receipt, then return to Stake and refresh."
        } else {
            "Transaction broadcast. Refresh verified case state after checking its receipt."
        },
    );
    text(
        "transaction-note",
        if result.warning.is_some() {
            "The wallet returned a hash. Keep it and check its receipt before another send."
        } else {
            "Transaction broadcast. Check its receipt before another send."
        },
    );
    input("receipt-hash").set_value(&result.hash);
    text(
        "transaction",
        &format!(
            "Broadcast hash: {}\n{}\n{}\nUse Refresh transaction receipt before any retry.",
            result.hash,
            original,
            result
                .warning
                .unwrap_or("Wallet returned a broadcast hash; confirmation is not yet checked.")
        ),
    );
    app.borrow_mut().controls.last_transaction = Some(TransactionReturn {
        hash: result.hash,
        voter: s.voter.clone(),
        profile: s.profile.clone(),
        context: original,
        stake,
        case_id: follow,
    });
    notice(if stake {
        "Transaction hash saved. Check its receipt, then refresh Stake before any retry."
    } else {
        "Transaction hash saved. Refresh its receipt and case before any retry."
    });
}
async fn execute(app: &Rc<RefCell<App>>, command: Command) -> Result<()> {
    // Vault operations do not require wallet access and never call a provider.
    let vault = app.borrow().vault.clone();
    match command {
        Command::Unlock => {
            let p = take_password("vault-password");
            let n = vault.unlock(&p).await?;
            notice(&format!("Private storage unlocked: {n} saved votes. Connect the intended account, then Refresh my work to find this deployment's cases."));
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
            let current_covered = {
                let a = app.borrow();
                selected(&a)
                    .ok()
                    .filter(|e| case_actions(&e.snapshot, e.eligibility).allowed(Action::Commit))
                    .and_then(|e| local_record(&a, e).ok())
                    .map(|v| vault.is_backed_up(&v.context()).unwrap_or(false))
            };
            notice(&match current_covered {
                Some(true) => "Recovery for your current saved choice is verified.".into(),
                Some(false) => {
                    "This file does not cover your current choice. Export and verify new recovery."
                        .into()
                }
                None => format!("Recovery checked: {n} exact choice records covered."),
            });
            return Ok(());
        }
        Command::ResumeRequest => {
            let (profile, voter) = {
                let a = app.borrow();
                (
                    a.profile.clone().ok_or("PROFILE_REQUIRED")?,
                    a.wallet.account.clone().ok_or("WALLET_NOT_CONNECTED")?,
                )
            };
            let row = crate::moderator_requests::load(&profile, &voter)?
                .into_iter()
                .find(|r| !r.settled)
                .ok_or("REQUEST_NOT_FOUND")?;
            let context = format!(
                "{} · {}\nAccount: {}\nChain: {} · Moderation: {}\nDestination: {}",
                crate::moderator_requests::label(&row.action),
                row.case_id
                    .as_ref()
                    .map(|id| format!("Case {id}"))
                    .unwrap_or_else(|| "Stake / account action".into()),
                row.voter,
                row.chain,
                row.contract,
                row.to
            );
            let hash = row.hash.unwrap_or_default();
            input("receipt-hash").set_value(&hash);
            text("transaction", &context);
            app.borrow_mut().controls.last_transaction = Some(TransactionReturn {
                hash,
                voter: row.voter.clone(),
                profile,
                context,
                stake: row.case_id.is_none(),
                case_id: row
                    .case_id
                    .as_deref()
                    .and_then(|id| Uint256::decimal(id).ok()),
            });
            journey::show(app, journey::View::Records, false);
            notice("Check this saved request. If its hash is missing, copy it from your wallet activity. Nothing will be resent.");
            journey::focus("receipt-hash");
            return Ok(());
        }
        Command::Receipt => {
            let hash = input("receipt-hash").value();
            let profile = {
                let state = app.borrow();
                match state.controls.last_transaction.as_ref() {
                    Some(tx) if tx.hash.eq_ignore_ascii_case(&hash) => tx.profile.clone(),
                    _ => state.profile.clone().ok_or("PROFILE_REQUIRED")?,
                }
            };
            let status = workflow::receipt(&profile, &hash).await?;
            if let Some(tx) = app.borrow_mut().controls.last_transaction.as_mut() {
                if crate::moderator_requests::load(&tx.profile, &tx.voter)?
                    .iter()
                    .any(|r| {
                        r.settled
                            && r.resolved_hash.as_deref() == Some(&hash)
                            && r.case_id.as_deref()
                                == tx.case_id.map(|id| id.to_decimal()).as_deref()
                            && (r.hash.as_deref() == Some(tx.hash.as_str())
                                || tx.hash.is_empty() && r.hash.is_none())
                    })
                {
                    tx.hash = hash.clone();
                }
            }
            let (context, stake) = app
                .borrow()
                .controls
                .last_transaction
                .as_ref()
                .filter(|tx| tx.hash.eq_ignore_ascii_case(&hash))
                .map(|tx| (tx.context.clone(), tx.stake))
                .unwrap_or_default();
            let status = if stake
                && status == "Transaction confirmed. Refresh the case to read updated state."
            {
                "Transaction confirmed. Return to Stake and refresh its balance and allowance."
            } else if context.is_empty()
                && status == "Transaction confirmed. Refresh the case to read updated state."
            {
                "Transaction confirmed. Refresh current evidence before another action."
            } else {
                status
            };
            text("transaction", &format!("{hash}\n{context}\n{status}"));
            notice(status);
            return Ok(());
        }
        _ => {}
    }
    let mut s = session(app)?;
    if matches!(
        command,
        Command::Commit | Command::Reveal | Command::Action(_) | Command::Stake(_)
    ) {
        s.request_boundary = Some(crate::moderator_requests::boundary(&s.profile, &s.voter).await?);
        s.current()?;
    }
    match command {
        Command::ReadStake => {
            let evidence = evidence::read_moderator(&s.profile, &s.voter).await?;
            s.current()?;
            app.borrow_mut().controls.moderator = Some(evidence);
            notice("Stake and balance refreshed at a verified source block.");
        }
        Command::Work(next) => {
            let vault_generation = vault.generation();
            if !next {
                let mut ids = BTreeSet::new();
                if vault.is_unlocked() {
                    for vote in vault.list_votes()? {
                        if vote.chain_id == s.profile.deployment.chain_id.to_string()
                            && vote
                                .contract
                                .eq_ignore_ascii_case(&s.profile.deployment.moderation.address)
                            && vote.voter.eq_ignore_ascii_case(&s.voter)
                        {
                            ids.insert(Uint256::decimal(&vote.case_id).map_err(|e| e.0)?);
                        }
                    }
                }
                // History is public, but does not contain vote choices or salts.
                for id in workflow::public_case_ids(&s.profile, &s.voter)? {
                    ids.insert(id);
                }
                let mut app = app.borrow_mut();
                app.controls.work_ids = ids.into_iter().collect();
                app.controls.work_next = 0;
                app.controls.work.clear();
                element("work-list").set_text_content(None);
            }
            let (ids, end, total) = {
                let a = app.borrow();
                let start = a.controls.work_next.min(a.controls.work_ids.len());
                let end = (start + 10).min(a.controls.work_ids.len());
                (
                    a.controls.work_ids[start..end].to_vec(),
                    end,
                    a.controls.work_ids.len(),
                )
            };
            let mut checked = Vec::new();
            for id in ids {
                text("work-note", &format!("Checking Case {id}…"));
                let result = s.read(id, "latest").await;
                s.current()?;
                if vault.generation() != vault_generation {
                    return Err("VAULT_LOCKED");
                }
                checked.push((id, result));
            }
            app.borrow_mut().controls.work.extend(checked);
            journey::work_rows(&app.borrow())?;
            app.borrow_mut().controls.work_next = end;
            notice(&if total == 0 {
                "No case IDs were found in this account's available saved votes or public history. This does not prove there are no on-chain obligations. Unlock or import recovery, or inspect wallet activity if a vote is missing.".into()
            } else {
                format!(
                    "Checked {end} of {total} known cases; {} unchecked, {} failed reads. Priority covers checked rows only. {}",
                    total-end, app.borrow().controls.work.iter().filter(|(_,e)|e.is_err()).count(),
                    if vault.is_unlocked() {
                        "Open a case to read current evidence and continue."
                    } else {
                        "Unlock private storage and refresh again to include encrypted saved votes."
                    }
                )
            });
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
            journey::browse_rows(&page.cases);
            app.borrow_mut().controls.next = page.next_cursor;
            notice("Case page verified at one canonical source block.");
        }
        Command::Read | Command::RefreshSelected | Command::Open(_) => {
            let id = match command {
                Command::Open(id) => id,
                Command::RefreshSelected => {
                    app.borrow()
                        .controls
                        .selected
                        .as_ref()
                        .ok_or("SELECT_CASE_FIRST")?
                        .snapshot
                        .case_id
                }
                _ => Uint256::decimal(&input("case-id").value()).map_err(|e| e.0)?,
            };
            input("case-id").set_value(&id.to_decimal());
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
                &r.metadata.as_ref().map(view::metadata).unwrap_or_else(|| {
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
        Command::Change(vote) => {
            let e = selected(&app.borrow())?.clone();
            let original = app
                .borrow()
                .controls
                .changing
                .clone()
                .ok_or("CHOICE_PROTECTED")?;
            if local_record(&app.borrow(), &e)? != original
                || !review_allowed(&app.borrow(), &e, vote)
            {
                return Err("REVIEW_REQUIRED");
            }
            s.change_choice(&original, vote).await?;
            app.borrow_mut().controls.changing = None;
            notice("Choice changed. Save and verify new recovery before committing.");
        }
        Command::Commit => {
            let e = selected(&app.borrow())?.clone();
            let v = local_record(&app.borrow(), &e)?;
            if !review_allowed(&app.borrow(), &e, v.vote) {
                return Err("REVIEW_REQUIRED");
            }
            let result = s.commit(&v).await?;
            broadcast_result(app, &s, result, false);
        }
        Command::Reveal => {
            let id = selected(&app.borrow())?.snapshot.case_id;
            let result = s.reveal(id).await?;
            broadcast_result(app, &s, result, false);
        }
        Command::CheckReveal => {
            let id = selected(&app.borrow())?.snapshot.case_id;
            text("reveal-status", "Checking latest and finalized evidence and remaining inclusion time. No transaction is requested.");
            let report = match s.check_reveal(id).await {
                Ok(report) => report,
                Err(code) => {
                    text(
                        "reveal-result",
                        "Readiness unavailable. An earlier pass must not be reused.",
                    );
                    text("reveal-status",&format!("No fresh readiness result is available. An earlier pass must not be reused. {}",view::error(code)));
                    return Err(code);
                }
            };
            text("reveal-status",&format!("Last read-only check: {}.\nLatest source: block {}, {}.\nFinalized source: block {}, {}.\nReveal deadline: {}. Measured read duration: {} ms.\n{}",moment(report.checked_wall_ms/1000),report.latest.number,moment(report.latest.timestamp),report.finalized.number,moment(report.finalized.timestamp),moment(report.deadline),report.elapsed_ms,view::reveal_decision_text(report.ready,report.reason,report.remaining_seconds,report.budget,report.clock_error)));
            text(
                "reveal-result",
                &format!(
                    "{}\nChecked {}.",
                    view::reveal_summary(report.ready, report.reason),
                    moment(report.checked_wall_ms / 1000)
                ),
            );
            notice("");
        }
        Command::Action(action) => {
            let e = selected(&app.borrow())?.clone();
            let c = &e.snapshot.case;
            let result = s
                .action(e.snapshot.case_id, action, c.challenges, c.preliminary)
                .await?;
            broadcast_result(app, &s, result, false);
        }
        Command::Stake(action) => {
            let result = s.stake_action(action).await?;
            broadcast_result(app, &s, result, true);
        }
        _ => return Err("INVALID_ACTION"),
    }
    Ok(())
}

// Refuse simultaneous sends across tabs instead of queuing a stale action.
async fn coordinated(a: &Rc<RefCell<App>>, command: Command) -> Result<()> {
    if !matches!(
        command,
        Command::Draft(_)
            | Command::Change(_)
            | Command::Commit
            | Command::Reveal
            | Command::Action(_)
            | Command::Stake(_)
            | Command::Receipt
    ) {
        return execute(a, command).await;
    }
    let epoch = a.borrow().wallet.epoch;
    let navigator = js_sys::Reflect::get(web_sys::window().unwrap().as_ref(), &"navigator".into())
        .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?;
    let locks = js_sys::Reflect::get(&navigator, &"locks".into())
        .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?;
    let request = js_sys::Reflect::get(&locks, &"request".into())
        .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?
        .dyn_into::<js_sys::Function>()
        .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?;
    let result = Rc::new(RefCell::new(None));
    let output = result.clone();
    let state = a.clone();
    let callback = Closure::<dyn FnMut(wasm_bindgen::JsValue) -> js_sys::Promise>::new(
        move |lock: wasm_bindgen::JsValue| {
            let output = output.clone();
            let state = state.clone();
            wasm_bindgen_futures::future_to_promise(async move {
                let r = if lock.is_null() {
                    Err("REQUEST_BUSY_IN_ANOTHER_TAB")
                } else if state.borrow().wallet.epoch != epoch {
                    Err("CONTEXT_CHANGED")
                } else {
                    execute(&state, command).await
                };
                *output.borrow_mut() = Some(r);
                Ok(wasm_bindgen::JsValue::UNDEFINED)
            })
        },
    );
    let options = js_sys::Object::new();
    js_sys::Reflect::set(
        &options,
        &"ifAvailable".into(),
        &wasm_bindgen::JsValue::TRUE,
    )
    .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?;
    let promise = request
        .call3(
            &locks,
            &"swarm-moderator-requests-v1".into(),
            &options,
            callback.as_ref(),
        )
        .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?
        .dyn_into::<js_sys::Promise>()
        .map_err(|_| "REQUEST_COORDINATION_UNAVAILABLE")?;
    JsFuture::from(promise)
        .await
        .map_err(|_| "REQUEST_COORDINATION_FAILED")?;
    let r = result
        .borrow_mut()
        .take()
        .ok_or("REQUEST_COORDINATION_FAILED")?;
    r
}
