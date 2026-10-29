//! Reader presentation. Result controls stay mounted during per-item checks.
use super::*;
pub(super) fn text(app: &Shared, id: &str, value: &str) {
    element(app, id).set_text_content(Some(value));
}
pub(super) fn hidden(app: &Shared, id: &str, hide: bool) {
    let e = element(app, id);
    if hide {
        let _ = e.set_attribute("hidden", "");
    } else {
        let _ = e.remove_attribute("hidden");
    }
}
pub(super) fn set_open(app: &Shared, id: &str, open: bool) {
    let e = element(app, id);
    if open {
        let _ = e.set_attribute("open", "");
    } else {
        let _ = e.remove_attribute("open");
    }
}
pub(super) fn focus(app: &Shared, id: &str) {
    let _ = element(app, id)
        .unchecked_into::<web_sys::HtmlElement>()
        .focus();
}
fn disabled(app: &Shared, id: &str, value: bool) {
    let e = element(app, id);
    if value {
        let _ = e.set_attribute("disabled", "");
    } else {
        let _ = e.remove_attribute("disabled");
    }
}
pub(super) fn collecting(s: &Session) -> bool {
    !s.binding_limit
        && !s.row_limit
        && ((s.next_scan < s.next_case && s.counts.values().any(|n| *n != Uint256::ZERO))
            || (s.category && !s.done))
}
pub(super) fn message(code: &str) -> String {
    let meaning=match code {
        "INVALID_TOPIC"=>"Enter a complete topic of 1–64 characters.",
        "LOAD_SEARCH_PROFILE"=>"Choose and review a search source first.",
        "SELECT_FILE"=>"Choose a JSON file first.",
        "FILE_TOO_LARGE"|"CONFIG_TOO_LARGE"=>"Use a profile or category file no larger than 64 KiB.",
        "INVALID_SEARCH_PROFILE"=>"This is not a supported search profile. Ask the deployment operator for the reader profile.",
        "PROFILE_FINGERPRINT_REQUIRED"=>"Enter the expected profile fingerprint from your trusted source.",
        "PROFILE_FINGERPRINT_MISMATCH"=>"The profile does not match that fingerprint. It was not applied. Check the URL and fingerprint with your source.",
        "PUBLIC_PROFILE_URL_REQUIRED"|"PUBLIC_PROFILE_CONTAINS_ACCESS_SETTINGS"=>"Use a public profile URL and public endpoints without query credentials. Private endpoint files can be selected locally.",
        "LOAD_CATEGORY_GRAPH"=>"Choose a category graph first.",
        "INVALID_CATEGORY_TERMS"=>"Choose one to five category groups.",
        "CATEGORY_QUERY_TOPIC_LIMIT"=>"This selection expands beyond 16 topic keys. Choose fewer groups or exclude descendants.",
        "ENTRY_NO_LONGER_LISTED"|"CATEGORY_MEMBERSHIP_CHANGED"=>"This item no longer matches the current listing. No content link is available. Run a fresh search for updated results.",
        "SWARM_REFERENCE_MISMATCH"=>"The metadata bytes do not match their recorded reference. No content link is available. Check the gateway or retry later.",
        "SOURCE_BLOCK_CHANGED"=>"The search source block was replaced. These results are retained for context; run the applied query again at a fresh block.",
        "SOURCE_CHAIN_CHANGED"=>"The RPC now reports a different chain. Check your source before searching again.",
        "RESOURCE_UNAVAILABLE"|"RESOURCE_READ_FAILED"|"RPC_READ_FAILED"=>"The source or gateway could not be read. Completed results are retained. Retry the affected action when it is available.",
        "INCOMPLETE_SEARCH_RESULT"=>"Collection is incomplete. Continue collecting before checking content.",
        "UNUSABLE_REFERENCES"=>"The recorded content or metadata reference cannot be used. No content action is available.",
        _=>"This read could not be verified. The affected evidence was not accepted. Check the details and retry or choose a fresh search.",
    };
    format!("{meaning} ({code})")
}
pub(super) fn show_failure(app: &Shared, task: Task, code: &'static str) {
    let source_changed = matches!(
        code,
        "SOURCE_BLOCK_CHANGED"
            | "SOURCE_CHAIN_CHANGED"
            | "DEPLOYMENT_MISMATCH_RUNTIME"
            | "DEPLOYMENT_MISMATCH_LINK"
            | "DEPLOYMENT_MISMATCH_GUIDELINES"
    );
    if source_changed {
        if let Some(s) = &mut app.borrow_mut().session {
            s.blocked = true;
            for r in &mut s.rows {
                r.link = None;
                r.checked = None;
            }
        }
    }
    match task {
        Task::Source => text(app, "source-feedback", &message(code)),
        Task::Graph => text(app, "category-feedback", &message(code)),
        Task::Row(i) if !source_changed => {
            if let Some(row) = app
                .borrow_mut()
                .session
                .as_mut()
                .and_then(|s| s.rows.get_mut(i))
            {
                row.error = Some(code);
                row.link = None;
                row.checked = None;
            }
            update_row(app, i);
        }
        _ => text(app, "search-error", &message(code)),
    }
}
pub(super) fn refresh(app: &Shared) {
    let a = app.borrow();
    let busy = a.busy.is_some();
    let task = a.busy;
    let profile = a.profile.is_some();
    disabled(app, "load-profile-url", busy);
    disabled(app, "profile", busy);
    for id in ["profile-url", "profile-pin", "trust-profile"] {
        disabled(app, id, busy);
    }
    disabled(app, "graph", busy);
    disabled(
        app,
        "use-profile",
        busy || a.candidate.is_none() || !input(app, "trust-profile").checked(),
    );
    disabled(app, "search", busy || !profile);
    disabled(app, "category-search", busy || !profile);
    hidden(app, "cancel", !busy);
    if let Some(s) = &a.session {
        let collecting = collecting(s);
        let blocked = s.blocked;
        text(app, "applied-query", &s.query.label);
        text(
            app,
            "read-context",
            &format!(
                "Chain {} · index {}…{} · source block {} · block time {}",
                s.profile.access.deployment.chain_id,
                &s.profile.access.deployment.index.address[..8],
                &s.profile.access.deployment.index.address[38..],
                s.ctx.source.number,
                time(s.ctx.source.timestamp as f64 * 1000.0)
            ),
        );
        let lo = if s.category {
            s.page * s.profile.page_size
        } else {
            0
        };
        let hi = (lo + s.profile.page_size).min(s.rows.len());
        let count = hi.saturating_sub(lo);
        let start = s.page * s.profile.page_size + 1;
        text(
            app,
            "range",
            &if count == 0 {
                "0 items".into()
            } else if collecting {
                format!("{count} provisional rows")
            } else if s.category {
                format!(
                    "{}–{} of {} collected items",
                    start,
                    start + count - 1,
                    s.rows.len()
                )
            } else {
                format!(
                    "{}–{} of {} listings at source block",
                    start,
                    start + count - 1,
                    s.counts[&s.plan.topics[0]]
                )
            },
        );
        let summary = if blocked {
            "Source changed. Run a fresh search before opening content.".into()
        } else if s.binding_limit {
            format!("Stopped at the {MAX_BINDINGS}-binding provenance limit. Results are incomplete and cannot open content.")
        } else if s.row_limit {
            format!("Stopped at the {MAX_CATEGORY_ROWS}-row category limit. Results are incomplete and cannot open content.")
        } else if s.next_scan < s.next_case && s.counts.values().any(|n| *n != Uint256::ZERO) {
            format!("Checking historical LIST cases: next {} of {}. Continue collecting; provisional rows cannot open content.",s.next_scan,s.next_case)
        } else if s.category && !s.done {
            format!(
                "Collecting category topic {} of {}. Continue collecting before using results.",
                s.topic_index + 1,
                s.plan.topics.len()
            )
        } else if s.rows.is_empty() {
            format!("No matches for {}. Collection complete. Topics match complete normalized labels, not title words.",s.query.label)
        } else if s.done {
            "Collection complete.".into()
        } else {
            "This page is ready. More listings are available at the same source block.".into()
        };
        text(
            app,
            "notice",
            if busy {
                match task {
                    Some(Task::Row(_)) => "Checking the selected item at a fresh block…",
                    Some(Task::Page) => "Reading this page at the original source block…",
                    Some(Task::Metadata) => "Retrying metadata on this page…",
                    _ => "Reading and verifying…",
                }
            } else {
                &summary
            },
        );
        hidden(app, "continue", !collecting || blocked);
        disabled(app, "continue", busy);
        hidden(app, "previous", collecting || s.page == 0 || blocked);
        disabled(app, "previous", busy);
        let next = if s.category {
            !collecting && (s.page + 1) * s.profile.page_size < s.rows.len()
        } else {
            !collecting && !s.done
        };
        hidden(app, "next", !next || blocked);
        disabled(app, "next", busy);
        hidden(
            app,
            "retry",
            collecting
                || blocked
                || !s.rows.iter().skip(lo).take(count).any(|r| {
                    r.metadata.is_none()
                        && r.error.is_some()
                        && matches!(r.resolution, Resolution::Resolved(_))
                }),
        );
        disabled(app, "retry", busy);
        hidden(
            app,
            "fresh",
            busy || (!blocked
                && element(app, "search-error")
                    .text_content()
                    .unwrap_or_default()
                    .is_empty()
                && !s.rows.iter().any(|r| r.error.is_some())),
        );
        disabled(app, "fresh", busy);
        let changed = a.editing_category != s.category
            || query(app, s.category)
                .map(|q| q.signature != s.query.signature)
                .unwrap_or(true);
        text(
            app,
            "pending-query",
            if changed {
                "Query edits are not applied. Results still use the query shown below."
            } else {
                ""
            },
        );
        for i in lo..hi {
            update_row(app, i);
        }
    } else {
        text(app, "range", "");
        text(app, "read-context", "");
        text(app, "pending-query", "");
        for id in ["continue", "previous", "next", "retry"] {
            hidden(app, id, true);
        }
        hidden(app, "fresh", busy || a.last_query.is_none());
        text(
            app,
            "notice",
            if busy {
                "Reading and verifying…"
            } else if profile {
                "Enter a topic to find listed content."
            } else {
                "Choose a source to start. No wallet is needed."
            },
        );
    }
}
fn time(ms: f64) -> String {
    js_sys::Date::new(&JsValue::from_f64(ms))
        .to_iso_string()
        .as_string()
        .unwrap_or_default()
        .replace('T', " ")
        .trim_end_matches('Z')
        .to_owned()
        + " UTC"
}
pub(super) fn category_preview(app: &Shared) {
    match query(app, true) {
        Ok(q) => {
            let a = app.borrow();
            let g = a.graph.as_ref().unwrap();
            let mut groups = Vec::new();
            for term in &q.plan.terms {
                let labels = term
                    .iter()
                    .map(|key| {
                        let c = g
                            .categories
                            .iter()
                            .find(|c| c.topic_key.eq_ignore_ascii_case(key))
                            .unwrap();
                        format!("{} ({})", c.label, c.id)
                    })
                    .collect::<Vec<_>>();
                groups.push(format!("Any topic in [{}]", labels.join(", ")));
            }
            text(
                app,
                "category-preview",
                &format!(
                    "{}\n{} explicit topic keys. {}",
                    groups.join(if q.plan.all { " AND " } else { " OR " }),
                    q.plan.topics.len(),
                    if q.plan.all {
                        "A result must match each selected group."
                    } else {
                        "A result can match any selected group."
                    }
                ),
            );
            text(app, "category-keys", &q.plan.topics.join("\n"));
            text(app, "category-feedback", "");
        }
        Err(e) => {
            let no_choices = app
                .borrow()
                .category_choices
                .iter()
                .all(|(_, c)| !c.checked());
            let explanation = if no_choices {
                "Choose one to five groups to preview this query.".to_owned()
            } else {
                message(e)
            };
            text(app, "category-preview", &explanation);
            text(app, "category-keys", "");
        }
    }
}
pub(super) fn render_rows(app: &Shared) {
    let Some(s) = app.borrow().session.clone() else {
        return;
    };
    let root = element(app, "results");
    root.set_text_content(None);
    app.borrow_mut().row_callbacks.clear();
    let lo = if s.category {
        s.page * s.profile.page_size
    } else {
        0
    };
    let hi = (lo + s.profile.page_size).min(s.rows.len());
    for i in lo..hi {
        let article = app.borrow().document.create_element("article").unwrap();
        article.set_id(&format!("result-{i}"));
        article
            .set_attribute("aria-labelledby", &format!("title-{i}"))
            .unwrap();
        // Only this static template is HTML. Every fetched value is inserted as text.
        article.set_inner_html(&format!(r#"<h3 id="title-{i}"></h3><p id="description-{i}" class="description"></p><p id="attributes-{i}" class="attributes"></p><p id="publisher-source-{i}" class="hint"></p><div class="row-actions"><button id="check-{i}" class="secondary">Check current listing</button><a id="open-{i}" class="open-content" target="_blank" rel="noopener noreferrer" hidden>Open content separately</a></div><p id="row-status-{i}" class="row-status" role="status" aria-live="polite"></p><details class="evidence"><summary>Listing evidence</summary><pre id="evidence-{i}"></pre></details>"#));
        root.append_child(&article).unwrap();
        let a = app.clone();
        let cb = Closure::<dyn FnMut()>::new(move || {
            if a.borrow().session.as_ref().is_some_and(|s| !s.blocked) {
                start_work(a.clone(), Task::Row(i), move |a| open(a, i));
            }
        });
        element(app, &format!("check-{i}"))
            .add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
            .unwrap();
        app.borrow_mut().row_callbacks.push(cb);
        update_row(app, i);
    }
    refresh(app);
}
pub(super) fn update_row(app: &Shared, i: usize) {
    let a = app.borrow();
    let Some(s) = &a.session else {
        return;
    };
    let Some(r) = s.rows.get(i) else {
        return;
    };
    if a.document
        .get_element_by_id(&format!("title-{i}"))
        .is_none()
    {
        return;
    }
    let position = s.page * s.profile.page_size
        + if s.category {
            i - s.page * s.profile.page_size
        } else {
            i
        }
        + 1;
    let title = r
        .metadata
        .as_ref()
        .map(|m| m.title.as_str())
        .unwrap_or("Metadata not verified");
    text(app, &format!("title-{i}"), title);
    if let Some(m) = &r.metadata {
        text(
            app,
            &format!("description-{i}"),
            m.description
                .as_deref()
                .unwrap_or("No description supplied."),
        );
        text(
            app,
            &format!("attributes-{i}"),
            &format!(
                "{} · {} · {} · {}",
                m.entry_type,
                m.language.as_deref().unwrap_or("Language not supplied"),
                m.content_type,
                m.topics.join(", ")
            ),
        );
        text(
            app,
            &format!("publisher-source-{i}"),
            &m.source
                .as_ref()
                .map(|v| format!("Publisher-supplied source: {v}"))
                .unwrap_or_default(),
        );
    } else {
        for key in ["description", "attributes", "publisher-source"] {
            text(app, &format!("{key}-{i}"), "");
        }
    }
    let action = element(app, &format!("check-{i}"));
    action
        .set_attribute(
            "aria-label",
            &format!("Check current listing for {title}, result {position}"),
        )
        .unwrap();
    let actionable =
        r.metadata.is_some() && !s.blocked && !collecting(s) && !s.binding_limit && !s.row_limit;
    hidden(app, &format!("check-{i}"), !actionable);
    // aria-disabled preserves the focused button while its asynchronous read runs.
    action
        .set_attribute(
            "aria-disabled",
            if a.busy.is_some() { "true" } else { "false" },
        )
        .unwrap();
    let busy = a.busy == Some(Task::Row(i));
    let status = if busy {
        "Checking current listing…".into()
    } else if let Some(e) = r.error {
        message(e)
    } else if let Some((block, at)) = &r.checked {
        format!(
            "Listed at block {} · checked {}. Opens in another tab.",
            block.number,
            time(*at)
        )
    } else if collecting(s) || s.binding_limit || s.row_limit {
        "Collection incomplete; content is unavailable.".into()
    } else {
        match &r.resolution{Resolution::Unresolved=>"No unique finalized LIST record found; content is unavailable.",Resolution::Ambiguous=>"Conflicting LIST records; content is unavailable.",Resolution::Resolved(_) if r.metadata.is_some()=>"Metadata authenticated · historical LIST provenance · current listing not rechecked.",_=>"Historical LIST record found; metadata is not verified."}.into()
    };
    text(app, &format!("row-status-{i}"), &status);
    let link = element(app, &format!("open-{i}"));
    hidden(app, &format!("open-{i}"), r.link.is_none() || !actionable);
    if let Some(url) = &r.link {
        link.set_attribute("href", url).unwrap();
        link.set_attribute(
            "aria-label",
            &format!("Open {title} separately, result {position}"),
        )
        .unwrap();
    } else {
        let _ = link.remove_attribute("href");
    }
    let binding = match &r.resolution {
        Resolution::Resolved(b) => format!(
            "Finalized LIST case {}\nClaim {}\nContent {}\nMetadata {}",
            b.case_id, b.claim, b.content, b.metadata
        ),
        _ => "No usable unique LIST binding".into(),
    };
    let checked = r
        .checked
        .as_ref()
        .map(|(b, _)| {
            format!(
                "\nCurrent membership block {}\nCurrent block hash {}",
                b.number, b.hash
            )
        })
        .unwrap_or_default();
    text(app,&format!("evidence-{i}"),&format!("Result {position}\nSource chain {}\nIndex {}\nSource block {}\nSource block hash {}\nEntry {}\nTopic key {}\n{binding}{checked}",s.profile.access.deployment.chain_id,s.profile.access.deployment.index.address,s.ctx.source.number,s.ctx.source.hash,r.entry,r.topic));
}
