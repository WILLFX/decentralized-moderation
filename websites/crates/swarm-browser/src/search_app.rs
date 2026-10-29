//! Read-only reader journey. No wallet, transaction or private storage API.
#[path = "search/reader.rs"]
mod reader;
#[path = "search/setup.rs"]
mod setup;
#[path = "search/view.rs"]
mod view;
use crate::{transport::fetch, BrowserResult as Result};
use reader::{Context, Reader};
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
};
use swarm_core::{
    moderator::{decode_bool, decode_case, decode_topics, SourceBlock, Uint256},
    review::{parse_metadata, resource_url, separate_content_url, Metadata, MAX_REVIEW_BYTES},
    search::*,
};
use view::*;
use wasm_bindgen::{closure::Closure, prelude::*, JsCast};
use wasm_bindgen_futures::{spawn_local, JsFuture};
use web_sys::{Document, HtmlInputElement, RequestInit};
#[derive(Clone)]
struct Row {
    entry: String,
    topic: String,
    resolution: Resolution,
    metadata: Option<Metadata>,
    error: Option<&'static str>,
    link: Option<String>,
    checked: Option<(SourceBlock, f64)>,
}
#[derive(Clone)]
struct Query {
    plan: CategoryPlan,
    category: bool,
    label: String,
    signature: String,
}
#[derive(Clone)]
struct Session {
    profile: SearchProfile,
    reader: Reader,
    ctx: Context,
    plan: CategoryPlan,
    category: bool,
    query: Query,
    next_case: Uint256,
    next_scan: Uint256,
    bindings: Vec<Binding>,
    binding_limit: bool,
    row_limit: bool,
    blocked: bool,
    topic_index: usize,
    offset: Uint256,
    rows: Vec<Row>,
    page: usize,
    done: bool,
    seen: BTreeSet<String>,
    counts: BTreeMap<String, Uint256>,
}
#[derive(Clone, Copy, PartialEq)]
enum Task {
    Source,
    Graph,
    Search,
    Collect,
    Page,
    Metadata,
    Row(usize),
}
struct App {
    document: Document,
    generation: Rc<Cell<u64>>,
    focus_revision: Rc<Cell<u64>>,
    profile: Option<SearchProfile>,
    candidate: Option<setup::Candidate>,
    active_summary: String,
    graph: Option<Graph>,
    graph_fingerprint: String,
    category_choices: Vec<(String, HtmlInputElement)>,
    category_callbacks: Vec<Closure<dyn FnMut()>>,
    session: Option<Session>,
    last_query: Option<Query>,
    editing_category: bool,
    busy: Option<Task>,
    row_callbacks: Vec<Closure<dyn FnMut()>>,
}
type Shared = Rc<RefCell<App>>;
fn element(app: &Shared, id: &str) -> web_sys::Element {
    app.borrow()
        .document
        .get_element_by_id(id)
        .expect("static search element")
}
fn input(app: &Shared, id: &str) -> HtmlInputElement {
    element(app, id).unchecked_into()
}
fn invalidate(app: &Shared) {
    let mut a = app.borrow_mut();
    a.generation.set(a.generation.get().wrapping_add(1));
    a.session = None;
    a.busy = None;
    drop(a);
    element(app, "results").set_text_content(None);
    text(app, "search-error", "");
    refresh(app);
}
fn cancel(app: &Shared) {
    let mut a = app.borrow_mut();
    let task = a.busy;
    let next = a.generation.get().wrapping_add(1);
    a.generation.set(next);
    a.busy = None;
    if let Some(s) = &mut a.session {
        s.reader.expected = next;
    }
    drop(a);
    refresh(app);
    match task {
        Some(Task::Source) => text(
            app,
            "source-feedback",
            "Profile read cancelled. The active source has not changed.",
        ),
        Some(Task::Graph) => text(
            app,
            "category-feedback",
            "Graph read cancelled. The active graph has not changed.",
        ),
        _ => {
            text(app,"search-error","Read cancelled. Previously completed results remain at their stated block. Continue or retry when ready.");
            focus(app, "results-heading");
        }
    }
}
fn event<F>(app: &Shared, id: &str, name: &str, run: F) -> std::result::Result<(), JsValue>
where
    F: Fn(Shared) + 'static,
{
    let a = app.clone();
    let c = Closure::<dyn FnMut()>::new(move || run(a.clone()));
    element(app, id).add_event_listener_with_callback(name, c.as_ref().unchecked_ref())?;
    c.forget();
    Ok(())
}
fn button<F>(app: &Shared, id: &str, run: F) -> std::result::Result<(), JsValue>
where
    F: Fn(Shared) + 'static,
{
    event(app, id, "click", run)
}
// User activity revokes an asynchronous action's permission to move focus.
// Capture listeners run before Enter launches a query from the topic field.
fn bind_focus_intent(app: &Shared) -> std::result::Result<(), JsValue> {
    for name in [
        "focusin",
        "input",
        "change",
        "pointerdown",
        "keydown",
        "visibilitychange",
    ] {
        let revision = app.borrow().focus_revision.clone();
        let changed = Closure::<dyn FnMut()>::new(move || {
            revision.set(revision.get().wrapping_add(1));
        });
        app.borrow()
            .document
            .add_event_listener_with_callback_and_bool(
                name,
                changed.as_ref().unchecked_ref(),
                true,
            )?;
        changed.forget();
    }
    let revision = app.borrow().focus_revision.clone();
    let blurred = Closure::<dyn FnMut()>::new(move || {
        revision.set(revision.get().wrapping_add(1));
    });
    web_sys::window()
        .unwrap()
        .add_event_listener_with_callback("blur", blurred.as_ref().unchecked_ref())?;
    blurred.forget();
    Ok(())
}
fn start_work<F, Fut>(app: Shared, task: Task, work: F)
where
    F: FnOnce(Shared) -> Fut + 'static,
    Fut: std::future::Future<Output = Result<()>> + 'static,
{
    if app.borrow().busy.is_some() {
        return;
    }
    let focus_revision = app.borrow().focus_revision.get();
    app.borrow_mut().busy = Some(task);
    let generation = app.borrow().generation.get();
    if let Task::Row(i) = task {
        if let Some(row) = app
            .borrow_mut()
            .session
            .as_mut()
            .and_then(|s| s.rows.get_mut(i))
        {
            row.link = None;
            row.checked = None;
            row.error = None;
        }
        update_row(&app, i);
    }
    text(&app, "search-error", "");
    refresh(&app);
    spawn_local(async move {
        if generation != app.borrow().generation.get() {
            return;
        }
        let result = work(app.clone()).await;
        let succeeded = result.is_ok();
        if generation != app.borrow().generation.get() {
            return;
        }
        app.borrow_mut().busy = None;
        if let Err(code) = result {
            show_failure(&app, task, code);
        }
        refresh(&app);
        let still_owns_focus = app.borrow().focus_revision.get() == focus_revision;
        if still_owns_focus
            && ((succeeded && matches!(task, Task::Search | Task::Page))
                || matches!(task, Task::Collect | Task::Metadata)
                || app.borrow().session.as_ref().is_some_and(|s| s.blocked))
        {
            focus(&app, "results-heading");
        }
    });
}
async fn file_bytes(app: &Shared, id: &str) -> Result<Vec<u8>> {
    let f = input(app, id)
        .files()
        .and_then(|f| f.get(0))
        .ok_or("SELECT_FILE")?;
    if f.size() > 65536.0 {
        return Err("FILE_TOO_LARGE");
    }
    let data = JsFuture::from(f.array_buffer())
        .await
        .map_err(|_| "FILE_READ_FAILED")?;
    let bytes = js_sys::Uint8Array::new(&data).to_vec();
    if bytes.len() > 65536 {
        return Err("FILE_TOO_LARGE");
    }
    Ok(bytes)
}
fn query(app: &Shared, category: bool) -> Result<Query> {
    if category {
        let a = app.borrow();
        let ids = a
            .category_choices
            .iter()
            .filter(|(_, c)| c.checked())
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        let graph = a.graph.as_ref().ok_or("LOAD_CATEGORY_GRAPH")?;
        let expanded = input(app, "expanded").checked();
        let all = input(app, "all").checked();
        let plan = graph.plan(&ids, expanded, all).map_err(|e| e.0)?;
        let names = ids
            .iter()
            .map(|id| {
                graph
                    .categories
                    .iter()
                    .find(|c| &c.id == id)
                    .unwrap()
                    .label
                    .clone()
            })
            .collect::<Vec<_>>();
        let label = format!(
            "{} groups: {} · descendants {}",
            if all { "All" } else { "Any" },
            names.join(", "),
            if expanded { "included" } else { "excluded" }
        );
        let signature = serde_json::json!([ids, expanded, all, a.graph_fingerprint]).to_string();
        Ok(Query {
            plan,
            category,
            label,
            signature,
        })
    } else {
        let (topic, key) = normalize_topic(&input(app, "topic").value()).map_err(|e| e.0)?;
        Ok(Query {
            plan: CategoryPlan {
                terms: vec![vec![key.clone()]],
                topics: vec![key],
                all: true,
            },
            category,
            label: format!("Topic “{topic}”"),
            signature: topic,
        })
    }
}
fn launch_query(app: Shared, category: bool) {
    if app.borrow().busy.is_some() {
        return;
    }
    if app.borrow().profile.is_none() {
        text(&app, "topic-feedback", "Choose a search source first.");
        set_open(&app, "source-settings", true);
        focus(&app, "profile-url");
        return;
    }
    let q = match query(&app, category) {
        Ok(q) => q,
        Err(e) => {
            if !category {
                let _ = element(&app, "topic").set_attribute("aria-invalid", "true");
            }
            text(
                &app,
                if category {
                    "category-feedback"
                } else {
                    "topic-feedback"
                },
                &message(e),
            );
            return;
        }
    };
    app.borrow_mut().editing_category = category;
    if !category {
        input(&app, "topic").set_value(&q.signature);
    }
    text(&app, "topic-feedback", "");
    text(&app, "category-feedback", "");
    launch_spec(app, q);
}
fn launch_spec(app: Shared, q: Query) {
    invalidate(&app);
    app.borrow_mut().last_query = Some(q.clone());
    text(&app, "applied-query", &q.label);
    start_work(app, Task::Search, move |a| begin(a, q));
}
async fn begin(app: Shared, query: Query) -> Result<()> {
    let p = app.borrow().profile.clone().ok_or("LOAD_SEARCH_PROFILE")?;
    let generation = app.borrow().generation.clone();
    let expected = generation.get();
    let reader = Reader {
        profile: p.access.clone(),
        generation,
        expected,
    };
    let ctx = reader.begin(None).await?;
    let next_case = Uint256::hex(
        &reader
            .call(
                &ctx,
                &p.access.deployment.moderation.address,
                "nextCaseId()",
                "",
            )
            .await?,
    )
    .map_err(|e| e.0)?;
    if next_case == Uint256::ZERO {
        return Err("INVALID_CONTRACT_STATE");
    }
    let mut counts = BTreeMap::new();
    for topic in &query.plan.topics {
        let n = Uint256::hex(
            &reader
                .call(
                    &ctx,
                    &p.access.deployment.index.address,
                    "listedCount(bytes32)",
                    &topic[2..],
                )
                .await?,
        )
        .map_err(|e| e.0)?;
        counts.insert(topic.clone(), n);
    }
    reader.finish(&ctx).await?;
    reader.live()?;
    let s = Session {
        profile: p,
        reader,
        ctx,
        plan: query.plan.clone(),
        category: query.category,
        query,
        next_case,
        next_scan: Uint256::from_u64(1),
        bindings: Vec::new(),
        binding_limit: false,
        row_limit: false,
        blocked: false,
        topic_index: 0,
        offset: Uint256::ZERO,
        rows: Vec::new(),
        page: 0,
        done: false,
        seen: BTreeSet::new(),
        counts,
    };
    app.borrow_mut().session = Some(s);
    advance(app.clone()).await?;
    Ok(())
}
async fn advance(app: Shared) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    if s.done {
        return Err("COLLECTION_COMPLETE");
    }
    let ctx = s.reader.begin(Some(&s.ctx)).await?;
    // Stage progress privately. Failure/cancellation leaves committed progress unchanged.
    let any = s.counts.values().any(|n| *n != Uint256::ZERO);
    if !any {
        s.done = true;
    } else if s.next_scan < s.next_case && !s.binding_limit {
        for _ in 0..s.profile.scan_size {
            if s.next_scan >= s.next_case {
                break;
            }
            let id = s.next_scan;
            let c = decode_case(
                &s.reader
                    .call(
                        &ctx,
                        &s.profile.access.deployment.moderation.address,
                        "caseInfo(uint256)",
                        &id.abi(),
                    )
                    .await?,
            )
            .map_err(|e| e.0)?;
            let topics = decode_topics(
                &s.reader
                    .call(
                        &ctx,
                        &s.profile.access.deployment.moderation.address,
                        "topicsOf(uint256)",
                        &id.abi(),
                    )
                    .await?,
            )
            .map_err(|e| e.0)?;
            if let Some(b) = candidate(id, &c, topics).map_err(|e| e.0)? {
                if b.topics.iter().any(|t| s.plan.topics.contains(t)) {
                    if !retain_binding(&mut s.bindings, b).map_err(|e| e.0)? {
                        // Commit the staged cursor and retained bindings only after
                        // the canonical check below. The omitted candidate remains
                        // at next_scan and cannot be mistaken for a completed scan.
                        s.binding_limit = true;
                        break;
                    }
                }
            }
            s.next_scan = increment(id).map_err(|e| e.0)?;
        }
    }
    if any && !s.done {
        if s.next_scan < s.next_case && !s.binding_limit {
            // Partial progress is visible but cannot authenticate a unique binding.
            let topic = s.plan.topics[0].clone();
            s.rows = read_rows(&s, &ctx, &topic, Uint256::ZERO, s.profile.page_size).await?;
        } else if s.category {
            if s.topic_index == 0 && s.offset == Uint256::ZERO {
                s.rows.clear(); // Discard the non-authoritative scan preview.
            }
            collect_category_page(&mut s, &ctx).await?
        } else {
            let topic = s.plan.topics[0].clone();
            s.rows = read_rows(&s, &ctx, &topic, s.offset, s.profile.page_size).await?;
            let count = *s.counts.get(&topic).unwrap();
            for _ in 0..s.rows.len() {
                s.offset = increment(s.offset).map_err(|e| e.0)?
            }
            s.done = s.offset >= count;
            hydrate(&mut s).await?;
        }
    }
    s.reader.finish(&ctx).await?;
    s.reader.live()?;
    app.borrow_mut().session = Some(s);
    render_rows(&app);
    Ok(())
}
async fn read_rows(
    s: &Session,
    c: &Context,
    topic: &str,
    offset: Uint256,
    limit: usize,
) -> Result<Vec<Row>> {
    let count = *s.counts.get(topic).ok_or("INVALID_TOPIC")?;
    let args = format!(
        "{}{}{}",
        &topic[2..],
        offset.abi(),
        Uint256::from_u64(limit as u64).abi()
    );
    let keys = decode_page(
        &s.reader
            .call(
                c,
                &s.profile.access.deployment.index.address,
                "listedPage(bytes32,uint256,uint256)",
                &args,
            )
            .await?,
        limit,
    )
    .map_err(|e| e.0)?;
    let mut end = offset;
    for _ in &keys {
        end = increment(end).map_err(|e| e.0)?
    }
    if end > count || (keys.len() != limit && end != count) || offset >= count && !keys.is_empty() {
        return Err("INVALID_REGISTRY_PAGE");
    }
    let mut rows = Vec::new();
    for key in keys {
        let resolution = resolve(
            &s.bindings,
            &key,
            topic,
            s.next_scan == s.next_case && !s.binding_limit,
        )
        .map_err(|e| e.0)?;
        if let Resolution::Resolved(b) = &resolution {
            membership(s, c, b, topic).await?;
        }
        rows.push(Row {
            entry: key,
            topic: topic.into(),
            resolution,
            metadata: None,
            error: None,
            link: None,
            checked: None,
        });
    }
    Ok(rows)
}
async fn membership(s: &Session, c: &Context, b: &Binding, topic: &str) -> Result<()> {
    let args = format!("{}{}", &b.claim[2..], &topic[2..]);
    if !decode_bool(
        &s.reader
            .call(
                c,
                &s.profile.access.deployment.index.address,
                "isListed(bytes32,bytes32)",
                &args,
            )
            .await?,
    )
    .map_err(|e| e.0)?
    {
        return Err("ENTRY_NO_LONGER_LISTED");
    }
    verify_entry(
        &s.reader
            .call(
                c,
                &s.profile.access.deployment.index.address,
                "entryOf(bytes32,bytes32)",
                &args,
            )
            .await?,
    )
    .map_err(|e| e.0)
}
async fn collect_category_page(s: &mut Session, c: &Context) -> Result<()> {
    if s.topic_index >= s.plan.topics.len() {
        s.done = true;
        return Ok(());
    }
    let topic = s.plan.topics[s.topic_index].clone();
    let rows = read_rows(s, c, &topic, s.offset, 20).await?;
    for r in rows {
        if s.rows.len() >= MAX_CATEGORY_ROWS {
            s.row_limit = true;
            break;
        }
        if !s.seen.insert(r.entry.clone()) {
            return Err("DUPLICATE_CATEGORY_ENTRY");
        }
        s.offset = increment(s.offset).map_err(|e| e.0)?;
        s.rows.push(r)
    }
    if s.row_limit {
        s.done = true;
        for r in &mut s.rows {
            r.resolution = Resolution::Unresolved;
            r.metadata = None;
            r.link = None;
        }
        return Ok(());
    }
    if s.offset >= s.counts[&topic] {
        s.topic_index += 1;
        s.offset = Uint256::ZERO;
    }
    if s.topic_index == s.plan.topics.len() {
        let mut groups: BTreeMap<String, (Row, Vec<String>)> = BTreeMap::new();
        let mut uncertain = Vec::new();
        for r in &s.rows {
            if let Resolution::Resolved(b) = &r.resolution {
                let g = groups
                    .entry(b.claim.clone())
                    .or_insert((r.clone(), Vec::new()));
                g.1.push(r.topic.clone());
            } else {
                uncertain.push(r.clone())
            }
        }
        // AND matches require observed current membership across the selected topic sets.
        s.rows = groups
            .into_values()
            .filter(|(_, topics)| s.plan.matches(topics))
            .map(|(r, _)| r)
            .chain(uncertain)
            .collect();
        s.done = true;
        hydrate(s).await?;
    }
    Ok(())
}
async fn read_metadata(s: &Session, b: &Binding) -> Result<Metadata> {
    s.reader.live()?;
    if Uint256::hex(&b.content).map_err(|e| e.0)? == Uint256::ZERO
        || Uint256::hex(&b.metadata).map_err(|e| e.0)? == Uint256::ZERO
    {
        return Err("UNUSABLE_REFERENCES");
    }
    let url = resource_url(
        &s.profile.access.gateway_url,
        &s.profile.access.metadata_path,
        &b.metadata,
    )
    .map_err(|e| e.0)?;
    let data = fetch(&url, &RequestInit::new(), MAX_REVIEW_BYTES).await?;
    s.reader.live()?;
    parse_metadata(&data, &b.metadata, &b.topics).map_err(|e| e.0)
}
async fn hydrate(s: &mut Session) -> Result<()> {
    let lo = if s.category {
        s.page * s.profile.page_size
    } else {
        0
    };
    let hi = (lo + s.profile.page_size).min(s.rows.len());
    for i in lo..hi {
        if let Resolution::Resolved(b) = &s.rows[i].resolution {
            match read_metadata(s, b).await {
                Ok(m) => {
                    s.rows[i].metadata = Some(m);
                    s.rows[i].error = None
                }
                Err("CANCELLED") => return Err("CANCELLED"),
                Err(e) => {
                    s.rows[i].error = Some(e);
                    s.rows[i].metadata = None;
                    s.rows[i].link = None;
                    s.rows[i].checked = None
                }
            }
        }
    }
    Ok(())
}
async fn page(app: Shared, forward: bool) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    if s.blocked || collecting(&s) {
        return Err("INCOMPLETE_SEARCH_RESULT");
    }
    let destination = if forward {
        s.page.checked_add(1).ok_or("NO_NEXT_PAGE")?
    } else {
        s.page.checked_sub(1).ok_or("NO_PREVIOUS_PAGE")?
    };
    let ctx = s.reader.begin(Some(&s.ctx)).await?;
    if s.category {
        if destination * s.profile.page_size >= s.rows.len() {
            return Err("NO_NEXT_PAGE");
        }
        s.page = destination;
    } else {
        if forward && s.done {
            return Err("NO_NEXT_PAGE");
        }
        let offset = destination
            .checked_mul(s.profile.page_size)
            .and_then(|n| u64::try_from(n).ok())
            .ok_or("INVALID_SEARCH_LIMIT")?;
        let topic = s.plan.topics[0].clone();
        s.rows = read_rows(
            &s,
            &ctx,
            &topic,
            Uint256::from_u64(offset),
            s.profile.page_size,
        )
        .await?;
        s.page = destination;
        s.offset = Uint256::from_u64(offset);
        for _ in &s.rows {
            s.offset = increment(s.offset).map_err(|e| e.0)?;
        }
        s.done = s.offset >= s.counts[&topic];
    }
    hydrate(&mut s).await?;
    s.reader.finish(&ctx).await?;
    s.reader.live()?;
    app.borrow_mut().session = Some(s);
    render_rows(&app);
    Ok(())
}
async fn retry(app: Shared) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    if s.blocked || collecting(&s) {
        return Err("INCOMPLETE_SEARCH_RESULT");
    }
    s.reader.begin(Some(&s.ctx)).await?;
    hydrate(&mut s).await?;
    s.reader.finish(&s.ctx).await?;
    s.reader.live()?;
    app.borrow_mut().session = Some(s);
    render_rows(&app);
    Ok(())
}
async fn open(app: Shared, index: usize) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    let row = s.rows.get(index).ok_or("INVALID_ROW")?.clone();
    if s.blocked || s.binding_limit || s.row_limit {
        return Err("INCOMPLETE_SEARCH_RESULT");
    }
    let b = match &row.resolution {
        Resolution::Resolved(b) => b.clone(),
        _ => return Err("UNRESOLVED_ENTRY"),
    };
    let ctx = s.reader.begin(None).await?;
    let c = decode_case(
        &s.reader
            .call(
                &ctx,
                &s.profile.access.deployment.moderation.address,
                "caseInfo(uint256)",
                &b.case_id.abi(),
            )
            .await?,
    )
    .map_err(|e| e.0)?;
    let topics = decode_topics(
        &s.reader
            .call(
                &ctx,
                &s.profile.access.deployment.moderation.address,
                "topicsOf(uint256)",
                &b.case_id.abi(),
            )
            .await?,
    )
    .map_err(|e| e.0)?;
    if candidate(b.case_id, &c, topics).map_err(|e| e.0)?.as_ref() != Some(&b) {
        return Err("ENTRY_CONTEXT_CHANGED");
    }
    membership(&s, &ctx, &b, &row.topic).await?;
    // A category AND result must still match every current membership requirement.
    if s.category {
        let mut current = Vec::new();
        for topic in &s.plan.topics {
            let args = format!("{}{}", &b.claim[2..], &topic[2..]);
            if decode_bool(
                &s.reader
                    .call(
                        &ctx,
                        &s.profile.access.deployment.index.address,
                        "isListed(bytes32,bytes32)",
                        &args,
                    )
                    .await?,
            )
            .map_err(|e| e.0)?
            {
                verify_entry(
                    &s.reader
                        .call(
                            &ctx,
                            &s.profile.access.deployment.index.address,
                            "entryOf(bytes32,bytes32)",
                            &args,
                        )
                        .await?,
                )
                .map_err(|e| e.0)?;
                current.push(topic.clone());
            }
        }
        if !s.plan.matches(&current) {
            return Err("CATEGORY_MEMBERSHIP_CHANGED");
        }
    }
    let metadata = read_metadata(&s, &b).await?;
    let origin = web_sys::window()
        .ok_or("WINDOW_UNAVAILABLE")?
        .location()
        .origin()
        .map_err(|_| "INVALID_ORIGIN")?;
    let link = separate_content_url(
        &s.profile.content_gateway,
        &s.profile.access.content_path,
        &b.content,
        &origin,
    )
    .map_err(|e| e.0)?;
    s.reader.finish(&ctx).await?;
    s.reader.live()?;
    s.rows[index].metadata = Some(metadata);
    s.rows[index].link = Some(link);
    s.rows[index].error = None;
    s.rows[index].checked = Some((ctx.source.clone(), js_sys::Date::now()));
    app.borrow_mut().session = Some(s);
    update_row(&app, index);
    Ok(())
}

pub fn start_search() -> std::result::Result<(), JsValue> {
    let document = web_sys::window()
        .ok_or_else(|| JsValue::from_str("WINDOW_UNAVAILABLE"))?
        .document()
        .ok_or_else(|| JsValue::from_str("DOCUMENT_UNAVAILABLE"))?;
    let app = Rc::new(RefCell::new(App {
        document,
        generation: Rc::new(Cell::new(0)),
        focus_revision: Rc::new(Cell::new(0)),
        profile: None,
        candidate: None,
        active_summary: String::new(),
        graph: None,
        graph_fingerprint: String::new(),
        category_choices: Vec::new(),
        category_callbacks: Vec::new(),
        session: None,
        last_query: None,
        editing_category: false,
        busy: None,
        row_callbacks: Vec::new(),
    }));
    bind_focus_intent(&app)?;
    event(&app, "profile", "change", |a| {
        start_work(a, Task::Source, |a| setup::load(a, false))
    })?;
    button(&app, "load-profile-url", |a| {
        start_work(a, Task::Source, |a| setup::load(a, true))
    })?;
    button(&app, "use-profile", setup::accept)?;
    event(&app, "trust-profile", "change", |a| refresh(&a))?;
    for id in ["profile-url", "profile-pin"] {
        event(&app, id, "input", |a| {
            a.borrow_mut().candidate = None;
            hidden(&a, "candidate", true);
            refresh(&a);
        })?;
    }
    event(&app, "graph", "change", |a| {
        start_work(a, Task::Graph, setup::load_graph)
    })?;
    button(&app, "source-link", |a| {
        set_open(&a, "source-settings", true)
    })?;
    button(&app, "search", |a| launch_query(a, false))?;
    button(&app, "category-search", |a| launch_query(a, true))?;
    event(&app, "topic", "input", |a| {
        a.borrow_mut().editing_category = false;
        text(&a, "topic-feedback", "");
        let _ = element(&a, "topic").remove_attribute("aria-invalid");
        refresh(&a);
    })?;
    for id in ["expanded", "all"] {
        event(&app, id, "change", |a| {
            a.borrow_mut().editing_category = true;
            category_preview(&a);
            refresh(&a);
        })?;
    }
    // A key handler avoids form navigation: the static site's CSP forbids form actions.
    let a = app.clone();
    let enter =
        Closure::<dyn FnMut(web_sys::KeyboardEvent)>::new(move |e: web_sys::KeyboardEvent| {
            if e.key() == "Enter" && !e.is_composing() {
                e.prevent_default();
                launch_query(a.clone(), false);
            }
        });
    element(&app, "topic")
        .add_event_listener_with_callback("keydown", enter.as_ref().unchecked_ref())?;
    enter.forget();
    button(&app, "continue", |a| start_work(a, Task::Collect, advance))?;
    button(&app, "previous", |a| {
        start_work(a, Task::Page, |a| page(a, false))
    })?;
    button(&app, "next", |a| {
        start_work(a, Task::Page, |a| page(a, true))
    })?;
    button(&app, "retry", |a| start_work(a, Task::Metadata, retry))?;
    button(&app, "cancel", |a| cancel(&a))?;
    button(&app, "fresh", |a| {
        let query = a.borrow().last_query.clone();
        if let Some(q) = query {
            launch_spec(a, q);
        }
    })?;
    setup::from_link(&app);
    text(&app, "boot", "");
    refresh(&app);
    Ok(())
}
