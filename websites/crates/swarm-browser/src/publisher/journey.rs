//! Focused workspaces. This state controls presentation, never send authorization.
use super::*;
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub(super) enum View {
    #[default]
    Editor,
    Review,
    Publications,
    Source,
    Records,
}
impl View {
    fn name(self) -> &'static str {
        match self {
            Self::Editor => "editor",
            Self::Review => "review",
            Self::Publications => "publications",
            Self::Source => "source",
            Self::Records => "records",
        }
    }
    fn heading(self) -> &'static str {
        match self {
            Self::Editor => "editor-heading",
            Self::Review => "review-heading",
            Self::Publications => "publications-heading",
            Self::Source => "source-heading",
            Self::Records => "records-heading",
        }
    }
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "editor" => Self::Editor,
            "review" => Self::Review,
            "publications" => Self::Publications,
            "source" => Self::Source,
            "records" => Self::Records,
            _ => return None,
        })
    }
}
#[derive(Default, Clone, Copy)]
pub(super) struct ReviewState {
    pub approve: bool,
    pub submit: bool,
    pub approval_open: bool,
    pub submission_open: bool,
    pub submitted: bool,
    pub journal: bool,
}
#[derive(Default)]
pub(super) struct State {
    pub view: View,
    pub notice_view: View,
    pub revision: u64,
    pub reference_route: bool,
    pub readiness: ReviewState,
    pub publication: Option<Publication>,
}
pub(super) struct Publication {
    pub key: Option<String>,
    pub id: String,
    pub phase: String,
    pub membership: String,
    pub next: String,
    pub source: String,
    pub refund: bool,
}
pub(super) fn hidden(id: &str, yes: bool) {
    if yes {
        let _ = el(id).set_attribute("hidden", "");
    } else {
        let _ = el(id).remove_attribute("hidden");
    }
}
pub(super) fn open_ancestors(node: &Element) {
    let mut parent = node.parent_element();
    while let Some(e) = parent {
        if e.tag_name() == "DETAILS" {
            let _ = e.set_attribute("open", "");
        }
        parent = e.parent_element();
    }
}
fn focus(id: &str) {
    open_ancestors(&el(id));
    let _ = el(id).dyn_into::<web_sys::HtmlElement>().unwrap().focus();
}
fn show(a: &Rc<RefCell<App>>, view: View, user: bool) {
    let mut s = a.borrow_mut();
    s.journey.view = view;
    if user {
        s.journey.revision = s.journey.revision.wrapping_add(1);
    }
    drop(s);
    if matches!(view, View::Records | View::Publications) && context(a).is_ok() {
        if let Err(e) = presentation::render_history(a) {
            text("request-list-note", &presentation::error(e));
        }
        if let Err(e) = publications::render(a) {
            text("publication-list-note", &presentation::error(e));
        }
        archive::render(a);
    }
    render(a);
    focus(view.heading());
}
pub(super) fn open_records(a: &Rc<RefCell<App>>) {
    show(a, View::Records, true);
}
pub(super) fn clear_publication(a: &Rc<RefCell<App>>) {
    text("case-feedback", "");
    a.borrow_mut().journey.publication = None;
    hidden("publication-current", true);
}
fn short_amount(n: Uint256, p: Option<&swarm_core::Display>) -> String {
    match p {
        Some(d) => format!(
            "{} {}",
            crate::token_amounts::decimal(n, d.decimals),
            d.symbol
        ),
        None => format!("{n} token base units"),
    }
}
// Match the next rendered workspace, even before its hidden attribute is updated.
fn feedback_visible(id: &str, view: View) -> bool {
    let mut node = Some(el(id));
    while let Some(e) = node {
        if let Some(owner) = e.get_attribute("data-view") {
            return owner == view.name();
        }
        if e.has_attribute("hidden") || (e.tag_name() == "DETAILS" && !e.has_attribute("open")) {
            return false;
        }
        node = e.parent_element();
    }
    true
}
pub(super) fn render(a: &Rc<RefCell<App>>) {
    let s = a.borrow();
    let view = s.journey.view;
    let notice = el("notice").text_content().unwrap_or_default();
    let duplicates = [
        "setup-feedback",
        "bee-feedback",
        "history-feedback",
        "content-feedback",
        "draft-feedback",
        "funds-feedback",
        "transaction-feedback",
        "publication-feedback",
        "recovery-feedback",
        "archive-feedback",
        "case-feedback",
        "authoring-note",
    ]
    .iter()
    .any(|id| {
        feedback_visible(id, view) && el(id).text_content().as_deref() == Some(notice.as_str())
    });
    hidden(
        "notice",
        s.journey.notice_view != view
            || duplicates
            || notice.starts_with("Working…")
            || notice == "Action finished. Read its result below."
            || (notice.contains("AUTHOR_FIELDS_INVALID")
                && el("field-summary")
                    .text_content()
                    .unwrap_or_default()
                    .is_empty()),
    );
    let waiting_wallet = s
        .pending_wallet
        .as_ref()
        .is_some_and(|p| p.record["state"] == "requesting");
    text(
        "publisher-activity",
        if s.busy && s.journey.notice_view != view && !waiting_wallet {
            match s.journey.notice_view {
                View::Editor => "Working in the editor…",
                View::Review => "Working in Review & submit…",
                View::Source => "Working in Source & wallet…",
                View::Publications => "Refreshing publication status…",
                View::Records => "Checking saved request history…",
            }
        } else {
            ""
        },
    );
    hidden("history-attention", s.history_faults.is_empty());
    hidden("source-funding-details", s.funding.is_none());
    hidden("publication-connect", s.account.is_some());
    hidden("profile-candidate-controls", s.setup_candidate.is_none());
    text(
        "active-pins",
        &s.profile
            .as_ref()
            .and_then(|p| serde_json::to_string_pretty(&p.deployment).ok())
            .unwrap_or_default(),
    );

    let _ = el("publisher-skip").set_attribute("href", &format!("#{}", view.heading()));
    let panels = doc().query_selector_all("[data-view]").unwrap();
    for i in 0..panels.length() {
        let panel = panels.item(i).unwrap().unchecked_into::<Element>();
        let is_visible = panel.get_attribute("data-view").as_deref() == Some(view.name());
        if is_visible {
            let _ = panel.remove_attribute("hidden");
        } else {
            let _ = panel.set_attribute("hidden", "");
        }
    }
    let links = doc().query_selector_all("[data-view-link]").unwrap();
    for i in 0..links.length() {
        let e = links.item(i).unwrap().unchecked_into::<Element>();
        if e.get_attribute("data-view-link").as_deref() == Some(view.name()) {
            let _ = e.set_attribute("aria-current", "page");
        } else {
            let _ = e.remove_attribute("aria-current");
        }
    }
    hidden("file-route", s.journey.reference_route);
    hidden("reference-route", !s.journey.reference_route);
    for (id, on) in [
        ("choose-file", !s.journey.reference_route),
        ("choose-reference", s.journey.reference_route),
    ] {
        let _ = el(id).set_attribute("aria-pressed", if on { "true" } else { "false" });
    }
    let p = s.profile.as_ref();
    text(
        "publisher-context",
        &p.map(|p| {
            format!(
                "{} · Deployment {}…{} · Account {}",
                progress::network(p.deployment.chain_id),
                &p.deployment.moderation.address[..8],
                &p.deployment.moderation.address[38..],
                s.account
                    .as_ref()
                    .map(|v| format!("{}…{}", &v[..8], &v[v.len() - 4..]))
                    .unwrap_or_else(|| "not connected".into())
            )
        })
        .unwrap_or_else(|| "No source selected · draft editing is available".into()),
    );
    text(
        "upload-prerequisite",
        if p.is_none() {
            "Choose a source and Bee settings before uploading. You can write the description now."
        } else if s.upload.is_none() {
            "Apply Bee upload settings under Source & wallet."
        } else {
            "Upload is public and uses the applied Bee settings. Inspect the exact content before reviewing."
        },
    );
    text("wallet-capability","Use a compatible Ethereum browser wallet for signing. If it is unavailable here, save your draft file before continuing in another browser.");
    text(
        "source-candidate",
        &s.setup_candidate
            .as_ref()
            .map(|c| {
                format!(
                    "Candidate: {} · moderation {} · token {}",
                    progress::network(c.profile.deployment.chain_id),
                    c.profile.deployment.moderation.address,
                    c.profile.deployment.token.address
                )
            })
            .unwrap_or_default(),
    );
    hidden("publication-review", s.draft.is_none());
    hidden("review-empty", s.draft.is_some());
    if let Some(d) = &s.draft {
        text("review-changes", &d.changes.join("; "));
        if let Ok(m) = serde_json::from_slice::<Value>(&d.bytes) {
            text("review-title", m["title"].as_str().unwrap_or("Publication"));
            text(
                "review-description",
                m["description"]
                    .as_str()
                    .unwrap_or("No description supplied."),
            );
            text(
                "review-attributes",
                &format!(
                    "{} · {} · {} · {}",
                    m["type"].as_str().unwrap_or(""),
                    m["language"].as_str().unwrap_or("Language not supplied"),
                    m["contentType"].as_str().unwrap_or(""),
                    m["topics"]
                        .as_array()
                        .map(|t| t
                            .iter()
                            .filter_map(|v| v.as_str())
                            .collect::<Vec<_>>()
                            .join(", "))
                        .unwrap_or_default()
                ),
            );
            text(
                "review-source",
                &m["source"]
                    .as_str()
                    .map(|v| format!("Declared source: {v}"))
                    .unwrap_or_default(),
            );
        }
        text(
            "review-content-state",
            if content::ready(a) {
                "Exact content inspection acknowledged."
            } else {
                "Content inspection is required. Return to the editor before uploading metadata or paying."
            },
        );
    }
    text(
        "review-account",
        &p.map(|p| {
            format!(
                "{}\nAccount {}\nToken {}\nSpender {}",
                progress::network(p.deployment.chain_id),
                s.account.as_deref().unwrap_or("Not connected"),
                p.deployment.token.address,
                p.deployment.moderation.address
            )
        })
        .unwrap_or_else(|| "Choose a source and the account that will pay.".into()),
    );
    text(
        "review-cost",
        &p.zip(s.funding.as_ref())
            .map(|(p, f)| {
                format!(
                    "Minimum {} · Balance {} · Allowance {}",
                    short_amount(f.minimum, p.display.as_ref()),
                    short_amount(f.balance, p.display.as_ref()),
                    short_amount(f.allowance, p.display.as_ref())
                )
            })
            .unwrap_or_else(|| {
                "Fee, balance and allowance have not been read for this context.".into()
            }),
    );
    hidden("review-setup", p.is_some() && s.account.is_some());
    hidden("review-inspect", content::ready(a));
    hidden("loadguidelines", s.draft.is_none() || s.guidelines);
    hidden("metadata-ack", s.draft.is_none() || !s.guidelines);
    hidden("upload", s.uploaded || s.draft.is_none());
    hidden("metadata-upload-effect", s.uploaded || s.draft.is_none());
    let r = s.journey.readiness;
    let capacity_blocked = s.profile.is_some() && s.account.is_some() && !r.journal;
    hidden("records-limit-note", !capacity_blocked);

    hidden("approve", !r.approve);
    hidden("submit", !r.submit);
    hidden("approvalreceipt", !r.approval_open);
    hidden("submissionreceipt", !r.submission_open);
    hidden("resubmit-label", !r.submitted);
    hidden("approval-note", !(r.approve || r.approval_open || r.submit));
    hidden(
        "submission-note",
        !(r.submit || r.submission_open || r.submitted),
    );
    hidden("payment-next", true);
    hidden("publication-current", s.journey.publication.is_none());
    if let Some(v) = &s.journey.publication {
        text("publication-current-heading", &format!("Case {}", v.id));
        text("publication-current-state", &v.phase);
        text("publication-current-membership", &v.membership);
        text("publication-current-next", &v.next);
        text("publication-current-source", &v.source);
        hidden("refund", !v.refund || !s.refund_ready);
    }
    if let Some(pending) = &s.pending_wallet {
        text(
            "recover-pending",
            if s.busy {
                "View saved requests"
            } else {
                "Check this saved request"
            },
        );
        let r = &pending.record;
        let _ = el("recover-pending").set_attribute("data-request", &recovery::identity(r));
        text(
            "wallet-short",
            &request_summary(r, pending.display.as_ref()),
        );
    }
}
pub(super) fn request_summary(r: &Value, display: Option<&swarm_core::Display>) -> String {
    let action = r["action"].as_str().unwrap_or("request");
    let amount = if action == "approve" {
        r["data"]
            .as_str()
            .and_then(|v| v.get(74..138))
            .and_then(|v| Uint256::hex(&format!("0x{v}")).ok())
    } else {
        r["intent"]["fee"]
            .as_str()
            .and_then(|v| Uint256::decimal(v).ok())
    };
    let effect = match action {
        "approve" => format!(
            "Approve exactly {} · permission only",
            amount
                .map(|v| short_amount(v, display))
                .unwrap_or_else(|| "unavailable amount".into())
        ),
        "submit" => format!(
            "Pay {} and submit for moderation",
            amount
                .map(|v| short_amount(v, display))
                .unwrap_or_else(|| "unavailable amount".into())
        ),
        "refund" => format!(
            "Withdraw existing refund for Case {} to the original submitter",
            r["caseId"].as_str().unwrap_or("")
        ),
        _ => "Inspect the full saved request.".into(),
    };
    format!(
        "{effect}\nAccount {} · chain {}\nDestination {}\nState {} · native value 0, gas separate",
        r["publisher"].as_str().unwrap_or(""),
        r["chainId"],
        r["to"].as_str().unwrap_or(""),
        r["state"].as_str().unwrap_or("")
    )
}
pub(super) fn after_action(a: &Rc<RefCell<App>>, action: &str, ok: bool, revision: u64) {
    render(a);
    if a.borrow().journey.revision != revision {
        return;
    }
    if ok {
        match action {
            "profile" | "fetchprofile" if a.borrow().journey.view == View::Source => {
                focus("source-candidate")
            }
            "useprofile" if a.borrow().journey.view == View::Source => focus("connect"),
            "connect" if a.borrow().journey.view == View::Source => focus("source-return"),
            "draft" => show(a, View::Review, false),
            "importdraft" => show(a, View::Editor, false),
            "uploadcontent" | "checkcontent" => {
                let _ = el("inspection-tools").set_attribute("open", "");
            }
            "publication" | "case" => {
                show(a, View::Publications, false);
                if a.borrow().journey.publication.is_some() {
                    focus("publication-current-heading");
                }
            }
            "submissionreceipt" | "receipt" => {
                if let Ok((p, who, _)) = context(a) {
                    if let Ok(records) = history::load_current(a, &p, &who) {
                        if records.iter().any(|r| {
                            r["action"] == "submit"
                                && r["state"] == "confirmed"
                                && (r["hash"] == value("txhash")
                                    || r["resolution"]["hash"] == value("txhash"))
                        }) {
                            show(a, View::Publications, false);
                        }
                    }
                }
            }
            _ => {}
        }
    } else if action == "draft" {
        show(a, View::Editor, false);
        validation::focus_first();
    }
    if ["approve", "submit", "approvalreceipt", "submissionreceipt"].contains(&action)
        && a.borrow().journey.view == View::Review
    {
        focus("transaction-feedback");
    }
}
pub(super) fn bind(a: &Rc<RefCell<App>>) -> std::result::Result<(), JsValue> {
    let state = a.clone();
    let refresh = Closure::<dyn FnMut()>::new(move || {
        let selected = state
            .borrow()
            .journey
            .publication
            .as_ref()
            .map(|v| (v.id.clone(), v.key.clone()));
        if let Some((id, key)) = selected {
            if let Some(key) = key {
                state.borrow_mut().publication_target = Some(key);
                dispatch(state.clone(), "publication");
            } else {
                input("caseid").set_value(&id);
                dispatch(state.clone(), "case");
            }
        }
    });
    el("refresh-publication")
        .add_event_listener_with_callback("click", refresh.as_ref().unchecked_ref())?;
    refresh.forget();
    let state = a.clone();
    let navigation = Closure::<dyn FnMut(web_sys::Event)>::new(move |e: web_sys::Event| {
        let target = e.target().and_then(|v| v.dyn_into::<Element>().ok());
        let Some(link) = target.and_then(|v| v.closest("[data-view-link]").ok().flatten()) else {
            return;
        };
        let Some(view) = link
            .get_attribute("data-view-link")
            .and_then(|v| View::parse(&v))
        else {
            return;
        };
        e.prevent_default();
        show(&state, view, true);
    });
    el("app").add_event_listener_with_callback("click", navigation.as_ref().unchecked_ref())?;
    navigation.forget();
    for (id, reference) in [("choose-file", false), ("choose-reference", true)] {
        let state = a.clone();
        let change = Closure::<dyn FnMut()>::new(move || {
            if !state.borrow().busy {
                state.borrow_mut().journey.reference_route = reference;
                render(&state);
            }
        });
        el(id).add_event_listener_with_callback("click", change.as_ref().unchecked_ref())?;
        change.forget();
    }
    let hash = web_sys::window()
        .unwrap()
        .location()
        .hash()
        .unwrap_or_default();
    let initial_view = match hash.as_str() {
        "#my-publications" => View::Publications,
        "#transaction-recovery" => View::Records,
        "#setup-task" => View::Source,
        "#review" => View::Review,
        _ => a.borrow().journey.view,
    };
    a.borrow_mut().journey.view = initial_view;
    a.borrow_mut().journey.reference_route = !value("reference").is_empty();
    render(a);
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_known_workspace_names_are_accepted() {
        assert_eq!(View::parse("review"), Some(View::Review));
        assert!(View::parse("submit").is_none());
        assert!(View::parse("javascript:send").is_none());
    }
    #[test]
    fn editing_is_the_default_without_restoring_transaction_readiness() {
        let s = State::default();
        assert_eq!(s.view, View::Editor);
        assert!(!s.readiness.approve);
        assert!(!s.readiness.submit);
        assert!(s.publication.is_none());
    }
}
