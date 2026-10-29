//! Public source acquisition is staged for explicit review, never silently applied.
use super::*;
pub(super) struct Candidate {
    pub profile: SearchProfile,
    pub summary: String,
}
fn endpoint(url: &str) -> String {
    match url.split_once('?') {
        Some((base, _)) => format!("{base} (query withheld)"),
        None => url.to_owned(),
    }
}
fn summary(p: &SearchProfile, fingerprint: &str) -> String {
    let d = &p.access.deployment;
    format!("Chain {}\nModeration {}\n  Runtime {}\nIndex {}\n  Runtime {}\nStakes {}\n  Runtime {}\nToken {}\n  Runtime {}\nGuidelines v{} · {}\nRPC {}\nMetadata gateway {} · {}\nContent gateway {} · {}\nFingerprint {}",d.chain_id,d.moderation.address,d.moderation.code_hash,d.index.address,d.index.code_hash,d.stakes.address,d.stakes.code_hash,d.token.address,d.token.code_hash,d.guidelines.version,d.guidelines.hash,endpoint(&p.access.rpc_url),endpoint(&p.access.gateway_url),p.access.metadata_path,endpoint(&p.content_gateway),p.access.content_path,fingerprint)
}
pub(super) async fn load(app: Shared, remote: bool) -> Result<()> {
    app.borrow_mut().candidate = None;
    hidden(&app, "candidate", true);
    input(&app, "trust-profile").set_checked(false);
    text(&app, "source-feedback", "Reading profile for review…");
    let epoch = app.borrow().generation.get();
    let pin = input(&app, "profile-pin").value();
    if remote && swarm_core::publisher::normalize_reference(pin.trim()).is_err() {
        return Err("PROFILE_FINGERPRINT_REQUIRED");
    }
    let raw = if remote {
        let url =
            swarm_core::access_url(input(&app, "profile-url").value().trim()).map_err(|e| e.0)?;
        if url.contains('?') {
            return Err("PUBLIC_PROFILE_URL_REQUIRED");
        }
        fetch(&url, &RequestInit::new(), 65536).await?
    } else {
        file_bytes(&app, "profile").await?
    };
    if epoch != app.borrow().generation.get() {
        return Err("CANCELLED");
    }
    let fingerprint = swarm_core::keccak256_hex(&raw);
    if remote || !pin.trim().is_empty() {
        let pin = swarm_core::publisher::normalize_reference(pin.trim())
            .map_err(|_| "PROFILE_FINGERPRINT_REQUIRED")?;
        if pin != fingerprint {
            return Err("PROFILE_FINGERPRINT_MISMATCH");
        }
    }
    let raw = std::str::from_utf8(&raw).map_err(|_| "INVALID_SEARCH_PROFILE")?;
    let profile = parse_profile(raw.trim_start_matches('\u{feff}')).map_err(|e| e.0)?;
    if remote
        && [
            &profile.access.rpc_url,
            &profile.access.gateway_url,
            &profile.content_gateway,
        ]
        .iter()
        .any(|u| u.contains('?'))
    {
        return Err("PUBLIC_PROFILE_CONTAINS_ACCESS_SETTINGS");
    }
    let candidate = Candidate {
        summary: summary(&profile, &fingerprint),
        profile,
    };
    let p = &candidate.profile;
    text(
        &app,
        "profile-review",
        &format!(
            "Chain {}\nModeration {}\nIndex {}\nRPC {}\nMetadata gateway {}\nContent gateway {}",
            p.access.deployment.chain_id,
            p.access.deployment.moderation.address,
            p.access.deployment.index.address,
            endpoint(&p.access.rpc_url),
            endpoint(&p.access.gateway_url),
            endpoint(&p.content_gateway)
        ),
    );
    text(&app, "profile-pins", &candidate.summary);
    app.borrow_mut().candidate = Some(candidate);
    hidden(&app, "candidate", false);
    text(
        &app,
        "source-feedback",
        "Profile read. Review its identity before using it. Active results have not changed.",
    );
    Ok(())
}
pub(super) fn accept(app: Shared) {
    if app.borrow().busy.is_some() || !input(&app, "trust-profile").checked() {
        return;
    }
    let Some(c) = app.borrow_mut().candidate.take() else {
        return;
    };
    invalidate(&app);
    app.borrow_mut().last_query = None;
    text(&app, "active-profile", &c.summary);
    text(
        &app,
        "source-summary",
        &format!(
            "Chain {} · index {}…{}",
            c.profile.access.deployment.chain_id,
            &c.profile.access.deployment.index.address[..8],
            &c.profile.access.deployment.index.address[38..]
        ),
    );
    app.borrow_mut().active_summary = c.summary;
    app.borrow_mut().profile = Some(c.profile);
    hidden(&app, "candidate", true);
    hidden(&app, "active-details", false);
    set_open(&app, "source-settings", false);
    text(&app, "source-state", "· active in this tab");
    text(&app, "source-feedback", "");
    text(&app, "applied-query", "");
    refresh(&app);
    focus(&app, "topic");
}
pub(super) fn from_link(app: &Shared) {
    let Some(window) = web_sys::window() else {
        return;
    };
    let fragment = window.location().hash().unwrap_or_default();
    if let Ok(params) = web_sys::UrlSearchParams::new_with_str(fragment.trim_start_matches('#')) {
        if let Some(url) = params.get("profile") {
            input(app, "profile-url").set_value(&url);
            text(app,"source-feedback","This link supplied a profile URL. Check its source and fingerprint before reading it.");
        }
        if let Some(pin) = params.get("fingerprint") {
            input(app, "profile-pin").set_value(&pin);
        }
    }
}
pub(super) async fn load_graph(app: Shared) -> Result<()> {
    let epoch = app.borrow().generation.get();
    let raw = file_bytes(&app, "graph").await?;
    if epoch != app.borrow().generation.get() {
        return Err("CANCELLED");
    }
    let graph = Graph::parse(&raw).map_err(|e| e.0)?;
    let root = element(&app, "categories");
    root.set_text_content(None);
    let document = app.borrow().document.clone();
    let mut choices = Vec::new();
    let mut callbacks = Vec::new();
    for (i, c) in graph.categories.iter().enumerate() {
        let label = document
            .create_element("label")
            .map_err(|_| "RENDER_FAILED")?;
        label.set_class_name("check");
        let choice = document
            .create_element("input")
            .map_err(|_| "RENDER_FAILED")?
            .unchecked_into::<HtmlInputElement>();
        choice.set_type("checkbox");
        choice.set_id(&format!("category-choice-{i}"));
        let words = document
            .create_element("span")
            .map_err(|_| "RENDER_FAILED")?;
        words.set_text_content(Some(&format!("{} ({})", c.label, c.id)));
        if !c.parents.is_empty() {
            let parents = c
                .parents
                .iter()
                .map(|id| {
                    graph
                        .categories
                        .iter()
                        .find(|p| &p.id == id)
                        .unwrap()
                        .label
                        .as_str()
                })
                .collect::<Vec<_>>();
            let path = document
                .create_element("span")
                .map_err(|_| "RENDER_FAILED")?;
            path.set_class_name("category-path");
            path.set_text_content(Some(&format!("Under: {}", parents.join(", "))));
            words.append_child(&path).map_err(|_| "RENDER_FAILED")?;
        }
        label.append_child(&choice).map_err(|_| "RENDER_FAILED")?;
        label.append_child(&words).map_err(|_| "RENDER_FAILED")?;
        root.append_child(&label).map_err(|_| "RENDER_FAILED")?;
        let a = app.clone();
        let cb = Closure::<dyn FnMut()>::new(move || {
            a.borrow_mut().editing_category = true;
            category_preview(&a);
            refresh(&a);
        });
        choice
            .add_event_listener_with_callback("change", cb.as_ref().unchecked_ref())
            .map_err(|_| "RENDER_FAILED")?;
        callbacks.push(cb);
        choices.push((c.id.clone(), choice));
    }
    let mut a = app.borrow_mut();
    a.graph = Some(graph);
    a.editing_category = true;
    a.graph_fingerprint = swarm_core::keccak256_hex(&raw);
    a.category_choices = choices;
    a.category_callbacks = callbacks;
    drop(a);
    text(&app,"category-feedback","Graph loaded. Choose up to five groups. Expansion is limited to 16 topic keys and 500 collected registry rows.");
    category_preview(&app);
    Ok(())
}
