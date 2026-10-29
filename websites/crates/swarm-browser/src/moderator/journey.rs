//! Workspaces and elapsed-time hints. None of this state authorizes disclosure.
use super::*;
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum View {
    #[default]
    Work,
    Browse,
    Case,
    Recovery,
    Stake,
    Source,
    Records,
}
impl View {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Work => "work",
            Self::Browse => "browse",
            Self::Case => "case",
            Self::Recovery => "recovery",
            Self::Stake => "stake",
            Self::Source => "source",
            Self::Records => "records",
        }
    }
    fn heading(self) -> &'static str {
        match self {
            Self::Work => "work-heading",
            Self::Browse => "browse-heading",
            Self::Case => "case-title",
            Self::Recovery => "recovery-heading",
            Self::Stake => "stake-heading",
            Self::Source => "source-heading",
            Self::Records => "records-heading",
        }
    }
    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "work" => Self::Work,
            "browse" => Self::Browse,
            "case" => Self::Case,
            "recovery" => Self::Recovery,
            "stake" => Self::Stake,
            "source" => Self::Source,
            "records" => Self::Records,
            _ => return None,
        })
    }
}
#[derive(Default)]
pub(super) struct State {
    pub view: View,
    pub revision: u64,
    pub observed_at: Option<f64>,
    pub returned: bool,
    pub follow_case: Option<Uint256>,
    pub operation: Option<String>,
    pub operation_case: Option<Uint256>,
}
pub(super) fn hidden(id: &str, yes: bool) {
    if yes {
        let _ = element(id).set_attribute("hidden", "");
    } else {
        let _ = element(id).remove_attribute("hidden");
    }
}
pub(super) fn focus(id: &str) {
    let e = element(id);
    let mut parent = e.parent_element();
    while let Some(node) = parent {
        if node.tag_name() == "DETAILS" {
            let _ = node.set_attribute("open", "");
        }
        parent = node.parent_element();
    }
    // Native controls keep their normal Tab position after receiving focus.
    // Headings and status text need a programmatic target only.
    if !e
        .matches("a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]:not([contenteditable=\"false\"])")
        .unwrap_or(false)
    {
        let _ = e.set_attribute("tabindex", "-1");
    }
    let _ = e.dyn_into::<web_sys::HtmlElement>().unwrap().focus();
}
pub(super) fn focus_current(app: &App) {
    focus(app.controls.journey.view.heading());
}
pub(super) fn show_notice(value: &str) {
    // Source callbacks may complete while another workspace is selected.
    // Their result remains owned by Source, rather than appearing in that task.
    text("notice-source", value);
}
pub(super) fn show(app: &Rc<RefCell<App>>, view: View, user: bool) {
    {
        let mut a = app.borrow_mut();
        a.controls.journey.view = view;
        if user {
            a.controls.journey.revision = a.controls.journey.revision.wrapping_add(1);
        }
    }
    render(&app.borrow());
    focus(view.heading());
}
pub(super) fn now() -> Option<f64> {
    web_sys::window()?
        .performance()
        .map(|p| p.now())
        .filter(|n| n.is_finite())
}
pub(super) fn render(app: &App) {
    let j = &app.controls.journey;
    let _ = element("moderator-skip").set_attribute("href", &format!("#{}", j.view.heading()));
    let nodes = element("app").query_selector_all("[data-view]").unwrap();
    for i in 0..nodes.length() {
        if let Some(node) = nodes
            .item(i)
            .and_then(|n| n.dyn_into::<web_sys::Element>().ok())
        {
            if node.get_attribute("data-view").as_deref() == Some(j.view.name()) {
                let _ = node.remove_attribute("hidden");
            } else {
                let _ = node.set_attribute("hidden", "");
            }
        }
    }
    let nodes = element("app")
        .query_selector_all("[data-view-link]")
        .unwrap();
    for i in 0..nodes.length() {
        if let Some(node) = nodes
            .item(i)
            .and_then(|n| n.dyn_into::<web_sys::Element>().ok())
        {
            if node.get_attribute("data-view-link").as_deref() == Some(j.view.name()) {
                let _ = node.set_attribute("aria-current", "page");
            } else {
                let _ = node.remove_attribute("aria-current");
            }
        }
    }
    hidden("notice", true);
    text(
        "activity",
        if app.busy {
            "An action is in progress. You can look at another workspace; action controls stay locked until it finishes."
        } else {
            ""
        },
    );
    hidden("activity", !app.busy);
    text("pending-context", j.operation.as_deref().unwrap_or(""));
    hidden("pending-context", j.operation.is_none() || !app.busy);
    let context = app
        .profile
        .as_ref()
        .map(|p| {
            format!(
                "Chain {} · Account {} · Moderation {}",
                p.deployment.chain_id,
                app.wallet.account.as_deref().unwrap_or("not connected"),
                p.deployment.moderation.address
            )
        })
        .unwrap_or_else(|| {
            "Choose a source and connect your intended account to read work.".into()
        });
    text("case-context", &context);
    text(
        "moderator-context",
        &app.profile
            .as_ref()
            .map(|p| {
                format!(
                    "Chain {} · Deployment {}…{} · Account {}",
                    p.deployment.chain_id,
                    &p.deployment.moderation.address[..8],
                    &p.deployment.moderation.address[38..],
                    app.wallet
                        .account
                        .as_ref()
                        .filter(|_| app.wallet.connected)
                        .map(|a| format!("{}…{}", &a[..8], &a[a.len() - 6..]))
                        .unwrap_or_else(|| "not connected".into())
                )
            })
            .unwrap_or_else(|| "Choose a source and connect your account.".into()),
    );
    hidden("work-setup", app.wallet.connected);
    let tx = app
        .controls
        .last_transaction
        .as_ref()
        .filter(|tx| tx.hash.eq_ignore_ascii_case(&input("receipt-hash").value()));
    hidden("receipt-return-stake", !tx.is_some_and(|tx| tx.stake));
    let same_deployment = tx.is_some_and(|tx| {
        app.profile.as_ref().is_some_and(|p| {
            p.deployment.chain_id == tx.profile.deployment.chain_id
                && p.deployment
                    .moderation
                    .address
                    .eq_ignore_ascii_case(&tx.profile.deployment.moderation.address)
        })
    });
    hidden(
        "receipt-return-case",
        !same_deployment
            || tx.is_none_or(|tx| tx.stake || tx.case_id.is_none())
            || !app.wallet.connected,
    );
    let e = app.controls.selected.as_ref();
    hidden("challenge-section", e.is_none());
    hidden("case-content", e.is_none());
    hidden("case-empty", e.is_some());
    hidden(
        "resume-case",
        j.follow_case.is_none() || !app.wallet.connected,
    );
    text(
        "case-title",
        &e.map(|e| format!("Case {}", e.snapshot.case_id))
            .or_else(|| j.follow_case.map(|id| format!("Case {id} · follow-up")))
            .unwrap_or_else(|| "Case workspace".into()),
    );
    if let Some(e) = e {
        let s = &e.snapshot;
        let actions = case_actions(s, e.eligibility);
        hidden("challenge-section", s.case.phase != 4);
        hidden("challenge-limit", e.challenge_bound);
        text(
            "challenge",
            &if [1, 2].contains(&s.case.preliminary) {
                format!(
                    "Challenge: {}",
                    view::choice(
                        s.case.action_type,
                        if s.case.preliminary == 1 { 2 } else { 1 }
                    )
                )
            } else {
                "Challenge outcome".into()
            },
        );
        let recorded = Uint256::hex(&s.vote.commitment).is_ok_and(|n| n != Uint256::ZERO);
        text("case-question", &view::question(&s.case));
        text(
            "case-state",
            &format!("{} · round {}", actions.state, s.case.challenges),
        );
        let timing = if s.case.phase == 3 && s.outcome_recovery.as_ref().is_some_and(|r| r.cached())
        {
            format!(
                "Original hash saved · no draw expiry · observed block {}",
                s.source.number
            )
        } else if view::draw_window(s) != view::DrawWindow::Unarmed {
            format!(
                "Draw blocks {}–{} · observed {}",
                s.case.outcome_seed_block.saturating_add(1),
                s.outcome_recovery
                    .as_ref()
                    .map_or(s.case.outcome_seed_block.saturating_add(250), |r| r
                        .recover_until),
                s.source.number
            )
        } else {
            view::deadline(s)
                .map(|(label, n)| format!("{label}: {} (at this read)", moment(n)))
                .unwrap_or_else(|| "No current phase deadline.".into())
        };
        text("case-timing", &timing);
        let draw_note = view::draw_phase_note(s);
        text("draw-phase-note", draw_note.as_deref().unwrap_or(""));
        hidden("draw-guidance", draw_note.is_none());
        hidden(
            "draw-progress-link",
            view::draw_window(s) != view::DrawWindow::Open,
        );
        let participation = view::participation_block(s, e.eligibility);
        // Avoid an irrelevant unlock prompt, but retain a matching saved choice.
        // Recorded votes return no participation block and retain this panel too.
        hidden(
            "saved-vote-section",
            (participation.is_some()
                || s.case.phase == 4 && !recorded
                || s.case.phase == 3 && s.case.outcome_seed_block != 0 && !recorded
                || recorded && s.vote.committee == 0)
                && local_record(app, e).is_err(),
        );
        let stake_route = matches!(
            participation,
            Some(view::ParticipationBlock::InactiveStake | view::ParticipationBlock::FrozenStake)
        );
        hidden(
            "participation-links",
            participation.is_none() || !app.controls.case_current,
        );
        hidden("participation-stake", !stake_route);
        hidden("participation-browse", stake_route);
        let prepare = !recorded && actions.allowed(Action::Commit);
        let saved = local_record(app, e);
        let editing = app.controls.changing.as_ref().is_some_and(|old| {
            saved.as_ref().is_ok_and(|v| v == old) && app.vault.can_correct(old)
        });
        hidden("prepare-controls", !prepare || saved.is_ok());
        hidden("commit-controls", !prepare || editing);
        hidden(
            "reveal-controls",
            !recorded
                || s.vote.settled
                || s.vote.revealed != 0
                || s.vote.round != s.case.challenges
                || ![1, 2].contains(&s.vote.committee),
        );
        hidden(
            "settlement-controls",
            !actions.allowed(Action::Claim) && !actions.allowed(Action::WithdrawRefund),
        );
        for (id, action) in ACTIONS {
            if *action != Action::Challenge {
                hidden(id, !actions.allowed(*action));
            }
        }
        hidden(
            "progress-controls",
            ![
                Action::CloseCommitA,
                Action::CloseCommitB,
                Action::CloseReveal,
                Action::Draw,
                Action::CacheOutcome,
                Action::ExpireOutcome,
                Action::CloseChallenge,
            ]
            .iter()
            .any(|a| actions.allowed(*a))
                && view::draw_window(s) == view::DrawWindow::Unarmed,
        );
        // Choice preparation is local. Corrections retain earlier encrypted secrets.
        text(
            "commit-duty",
            if recorded {
                view::own_duty(s, e.eligibility)
            } else {
                "After commitment: return to reveal on time, then settle. Missing reveal can add frozen time. Keep your recovery file and password."
            },
        );
        text(
            "settlement-summary",
            &if s.refund_owed != Uint256::ZERO {
                format!(
                    "Refund owed to this account: {}. Check the receipt, then refresh this case.",
                    crate::token_amounts::describe(
                        s.refund_owed,
                        app.profile.as_ref().and_then(|p| p.display.as_ref())
                    )
                )
            } else {
                "Check the receipt, then refresh the case to confirm settlement.".into()
            },
        );

        if !app.controls.case_current {
            text("next-step", "Fresh case evidence is unavailable. Refresh before continuing; your reviewed documents and saved recovery are retained.");
        }
        elapsed(app);
    } else {
        text("evidence-age", "");
        text("return-note", "");
    }
}
pub(super) fn elapsed(app: &App) {
    let j = &app.controls.journey;
    let Some(e) = app.controls.selected.as_ref() else {
        return;
    };
    let elapsed = j
        .observed_at
        .zip(now())
        .map(|(then, now)| ((now - then).max(0.0) / 1000.0) as u64);
    let age = elapsed
        .map(|n| {
            format!(
                "Read {} ago · source block {}. Local elapsed time is an estimate.",
                format!("{} min {} sec", n / 60, n % 60),
                e.snapshot.source.number
            )
        })
        .unwrap_or_else(|| "Elapsed time unavailable. Refresh case evidence.".into());
    text("evidence-age", &age);
    text(
        "return-note",
        if j.returned {
            "You returned to this tab. Refresh case evidence before continuing; the saved choice and review are retained."
        } else {
            ""
        },
    );
    hidden("return-note", !j.returned);
    // This is deliberately not a remaining-time or reveal-readiness countdown.
    // Source deadlines and the repeated disclosure guards remain authoritative.
}
pub(super) fn work_rows(app: &App) -> Result<()> {
    let mut rows = app.controls.work.iter().collect::<Vec<_>>();
    rows.sort_by_key(|(id, result)| {
        result
            .as_ref()
            .map(|e| (view::work_order(&e.snapshot, e.eligibility), *id))
            .unwrap_or(((1, 0), *id))
    });
    let list = element("work-list");
    list.set_text_content(None);
    let mut group = None;
    for (id, result) in rows {
        let rank = result
            .as_ref()
            .map(|e| view::work_order(&e.snapshot, e.eligibility).0)
            .unwrap_or(1);
        if group != Some(rank) {
            let h = document()
                .create_element("h3")
                .map_err(|_| "DOM_UNAVAILABLE")?;
            h.set_text_content(Some(match rank {
                0 => "Your actions due",
                1 => "Blocked or could not be checked",
                2 => "Waiting for case progress",
                3 => "Preparation · no recorded vote",
                4 => "Other known cases",
                _ => "Settled votes",
            }));
            list.append_child(&h).unwrap();
            group = Some(rank);
        }
        let article = document()
            .create_element("article")
            .map_err(|_| "DOM_UNAVAILABLE")?;
        article.set_class_name("work-card");
        let h = document().create_element("h3").unwrap();
        h.set_text_content(Some(&format!("Case {id}")));
        article.append_child(&h).unwrap();
        let p = document().create_element("p").unwrap();
        p.set_class_name("status");
        p.set_text_content(Some(&match result {
            Ok(e) => format!(
                "{}\n{}{}\nChecked at block {}.",
                view::question(&e.snapshot.case),
                view::own_duty(&e.snapshot, e.eligibility),
                view::deadline(&e.snapshot)
                    .map(|(label, n)| format!("\n{label}: {}", moment(n)))
                    .unwrap_or_default(),
                e.snapshot.source.number
            ),
            Err(code) => format!(
                "Could not check this case; its duty is unknown. {}",
                view::error(code)
            ),
        }));
        article.append_child(&p).unwrap();
        let button = document().create_element("button").unwrap();
        button.set_attribute("type", "button").unwrap();
        button
            .set_attribute("data-work-case", &id.to_decimal())
            .unwrap();
        if app.busy {
            button.set_attribute("disabled", "").unwrap();
        }
        button.set_text_content(Some(&format!("Open Case {id}")));
        article.append_child(&button).unwrap();
        list.append_child(&article).unwrap();
    }
    Ok(())
}
pub(super) fn browse_rows(cases: &[CaseEvidence]) {
    let list = element("browse-list");
    list.set_text_content(None);
    for e in cases {
        let article = document().create_element("article").unwrap();
        article.set_class_name("work-card");
        let p = document().create_element("p").unwrap();
        p.set_text_content(Some(&format!(
            "Case {} · {}\n{}",
            e.snapshot.case_id,
            case_actions(&e.snapshot, e.eligibility).state,
            view::question(&e.snapshot.case)
        )));
        article.append_child(&p).unwrap();
        let button = document().create_element("button").unwrap();
        button
            .set_attribute("data-work-case", &e.snapshot.case_id.to_decimal())
            .unwrap();
        button.set_attribute("disabled", "").unwrap();
        button.set_text_content(Some(&format!("Open Case {}", e.snapshot.case_id)));
        article.append_child(&button).unwrap();
        list.append_child(&article).unwrap();
    }
}
pub(super) fn install(app: Rc<RefCell<App>>) {
    let copy = app.clone();
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |event: web_sys::Event| {
        let Some(target) = event
            .target()
            .and_then(|n| n.dyn_into::<web_sys::Element>().ok())
        else {
            return;
        };
        let Some(link) = target.closest("[data-view-link]").ok().flatten() else {
            return;
        };
        let Some(view) = link
            .get_attribute("data-view-link")
            .as_deref()
            .and_then(View::parse)
        else {
            return;
        };
        event.prevent_default();
        show(&copy, view, true);
    });
    element("app")
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
    let copy = app.clone();
    let back = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if document().hidden() {
            return;
        }
        copy.borrow_mut().controls.journey.returned = true;
        elapsed(&copy.borrow());
        text("reveal-result","Previous readiness is a past observation. Check again after returning; Reveal repeats both guards.");
    });
    document()
        .add_event_listener_with_callback("visibilitychange", back.as_ref().unchecked_ref())
        .unwrap();
    back.forget();
    let copy = app.clone();
    let tick = Closure::<dyn FnMut()>::new(move || elapsed(&copy.borrow()));
    web_sys::window()
        .unwrap()
        .set_interval_with_callback_and_timeout_and_arguments_0(tick.as_ref().unchecked_ref(), 5000)
        .unwrap();
    tick.forget();
    let copy = app.clone();
    let resume = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        let id = copy.borrow().controls.journey.follow_case;
        if let Some(id) = id {
            dispatch(copy.clone(), Command::Open(id));
        }
    });
    element("resume-case")
        .add_event_listener_with_callback("click", resume.as_ref().unchecked_ref())
        .unwrap();
    resume.forget();
    let copy = app.clone();
    let receipt_input = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| render(&copy.borrow()));
    element("receipt-hash")
        .add_event_listener_with_callback("input", receipt_input.as_ref().unchecked_ref())
        .unwrap();
    receipt_input.forget();
    let copy = app.clone();
    let return_case = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        let id = copy
            .borrow()
            .controls
            .last_transaction
            .as_ref()
            .filter(|tx| !tx.stake && tx.hash.eq_ignore_ascii_case(&input("receipt-hash").value()))
            .and_then(|tx| tx.case_id);
        if let Some(id) = id {
            dispatch(copy.clone(), Command::Open(id));
        }
    });
    element("receipt-return-case")
        .add_event_listener_with_callback("click", return_case.as_ref().unchecked_ref())
        .unwrap();
    return_case.forget();
    render(&app.borrow());
}
