//! Separate read-only search application. No wallet, transaction, or private storage API.
#[path = "search/reader.rs"]
mod reader;
use crate::{transport::fetch, BrowserResult as Result};
use reader::{Context, Reader};
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet},
    rc::Rc,
};
use swarm_core::{
    moderator::{decode_bool, decode_case, decode_topics, Uint256},
    review::{parse_metadata, resource_url, separate_content_url, Metadata, MAX_REVIEW_BYTES},
    search::*,
};

use wasm_bindgen::{closure::Closure, prelude::*, JsCast};
use wasm_bindgen_futures::{spawn_local, JsFuture};
use web_sys::{Document, HtmlAnchorElement, HtmlInputElement, RequestInit};
#[derive(Clone)]
struct Row {
    entry: String,
    topic: String,
    resolution: Resolution,
    metadata: Option<Metadata>,
    error: Option<&'static str>,
    link: Option<String>,
}
#[derive(Clone)]
struct Session {
    profile: SearchProfile,
    reader: Reader,
    ctx: Context,
    plan: CategoryPlan,
    category: bool,
    next_case: Uint256,
    next_scan: Uint256,
    bindings: Vec<Binding>,
    binding_limit: bool,
    row_limit: bool,
    topic_index: usize,
    offset: Uint256,
    rows: Vec<Row>,
    page: usize,
    done: bool,
    seen: BTreeSet<String>,
    counts: BTreeMap<String, Uint256>,
}
struct App {
    document: Document,
    generation: Rc<Cell<u64>>,
    profile: Option<SearchProfile>,
    graph: Option<Graph>,
    category_choices: Vec<(String, HtmlInputElement)>,
    session: Option<Session>,
    busy: bool,
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
fn notice(app: &Shared, text: &str) {
    element(app, "notice").set_text_content(Some(text));
}
fn invalidate(app: &Shared) {
    let mut a = app.borrow_mut();
    a.generation.set(a.generation.get().wrapping_add(1));
    a.session = None;
    a.busy = false;
    drop(a);
    element(app, "results").set_text_content(None);
    notice(app, "Previous evidence cleared.");
}
fn button<F>(app: &Shared, id: &str, run: F) -> std::result::Result<(), JsValue>
where
    F: Fn(Shared) + 'static,
{
    let a = app.clone();
    let c = Closure::<dyn FnMut()>::new(move || run(a.clone()));
    element(app, id).add_event_listener_with_callback("click", c.as_ref().unchecked_ref())?;
    c.forget();
    Ok(())
}
fn start_work<F, Fut>(app: Shared, work: F)
where
    F: FnOnce(Shared) -> Fut + 'static,
    Fut: std::future::Future<Output = Result<()>> + 'static,
{
    if app.borrow().busy {
        notice(
            &app,
            "A read is in progress. Cancel it before starting another.",
        );
        return;
    }
    app.borrow_mut().busy = true;
    let generation = app.borrow().generation.get();
    notice(&app, "Reading and verifying…");
    spawn_local(async move {
        if let Some(s) = &mut app.borrow_mut().session {
            for r in &mut s.rows {
                r.link = None;
            }
        }
        if app.borrow().session.is_some() {
            render(&app);
            notice(&app, "Reading and verifying…");
        }
        let r = work(app.clone()).await;
        if app.borrow().generation.get() == generation {
            app.borrow_mut().busy = false;
            if let Err(e) = r {
                notice(&app, e)
            }
        }
    });
}
async fn file_text(app: &Shared, id: &str, limit: u64) -> Result<String> {
    let f = input(app, id)
        .files()
        .and_then(|f| f.get(0))
        .ok_or("SELECT_FILE")?;
    if f.size() > limit as f64 {
        return Err("FILE_TOO_LARGE");
    }
    JsFuture::from(f.text())
        .await
        .map_err(|_| "FILE_READ_FAILED")?
        .as_string()
        .ok_or("FILE_READ_FAILED")
}
async fn load_profile(app: Shared) -> Result<()> {
    let epoch = app.borrow().generation.get();
    let t = file_text(&app, "profile", 65536).await?;
    if epoch != app.borrow().generation.get() {
        return Err("CANCELLED");
    }
    let p = parse_profile(&t).map_err(|e| e.0)?;
    app.borrow_mut().profile = Some(p);
    notice(
        &app,
        "Search profile loaded. Search uses read-only RPC; no wallet connection is required.",
    );
    Ok(())
}
async fn load_graph(app: Shared) -> Result<()> {
    let epoch = app.borrow().generation.get();
    let t = file_text(&app, "graph", 65536).await?;
    if epoch != app.borrow().generation.get() {
        return Err("CANCELLED");
    }
    let g = Graph::parse(t.as_bytes()).map_err(|e| e.0)?;
    let root = element(&app, "categories");
    root.set_text_content(None);
    let document = app.borrow().document.clone();
    let mut choices = Vec::new();
    for (index, category) in g.categories.iter().enumerate() {
        let label = document
            .create_element("label")
            .map_err(|_| "RENDER_FAILED")?;
        let choice = document
            .create_element("input")
            .map_err(|_| "RENDER_FAILED")?
            .dyn_into::<HtmlInputElement>()
            .map_err(|_| "RENDER_FAILED")?;
        choice.set_type("checkbox");
        choice.set_id(&format!("category-choice-{index}"));
        let text = document
            .create_element("span")
            .map_err(|_| "RENDER_FAILED")?;
        text.set_text_content(Some(&category.label));
        label.append_child(&choice).map_err(|_| "RENDER_FAILED")?;
        label.append_child(&text).map_err(|_| "RENDER_FAILED")?;
        root.append_child(&label).map_err(|_| "RENDER_FAILED")?;
        choices.push((category.id.clone(), choice));
    }
    let mut state = app.borrow_mut();
    state.graph = Some(g);
    state.category_choices = choices;
    drop(state);
    notice(&app,"Category graph loaded as local query data. Its relationships do not prove moderation approval.");
    Ok(())
}
async fn begin(app: Shared, category: bool) -> Result<()> {
    let p = app.borrow().profile.clone().ok_or("LOAD_SEARCH_PROFILE")?;
    let plan = if category {
        let ids: Vec<String> = app
            .borrow()
            .category_choices
            .iter()
            .filter(|(_, choice)| choice.checked())
            .map(|(id, _)| id.clone())
            .collect();
        app.borrow()
            .graph
            .as_ref()
            .ok_or("LOAD_CATEGORY_GRAPH")?
            .plan(
                &ids,
                input(&app, "expanded").checked(),
                input(&app, "all").checked(),
            )
            .map_err(|e| e.0)?
    } else {
        let (t, key) = normalize_topic(&input(&app, "topic").value()).map_err(|e| e.0)?;
        input(&app, "topic").set_value(&t);
        CategoryPlan {
            terms: vec![vec![key.clone()]],
            topics: vec![key],
            all: true,
        }
    };
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
    for topic in &plan.topics {
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
        plan,
        category,
        next_case,
        next_scan: Uint256::from_u64(1),
        bindings: Vec::new(),
        binding_limit: false,
        row_limit: false,
        topic_index: 0,
        offset: Uint256::ZERO,
        rows: Vec::new(),
        page: 0,
        done: false,
        seen: BTreeSet::new(),
        counts,
    };
    app.borrow_mut().session = Some(s);
    advance(app).await
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
    render(&app);
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
                    s.rows[i].metadata = None
                }
            }
        }
    }
    Ok(())
}
async fn next(app: Shared) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    if s.category && s.done {
        if (s.page + 1) * s.profile.page_size < s.rows.len() {
            s.page += 1;
            hydrate(&mut s).await?;
            s.reader.finish(&s.ctx).await?;
            s.reader.live()?;
            app.borrow_mut().session = Some(s);
            render(&app);
            Ok(())
        } else {
            Err("NO_NEXT_PAGE")
        }
    } else if s.done {
        Err("NO_NEXT_PAGE")
    } else {
        advance(app).await
    }
}
async fn retry(app: Shared) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    s.reader.begin(Some(&s.ctx)).await?;
    hydrate(&mut s).await?;
    s.reader.finish(&s.ctx).await?;
    s.reader.live()?;
    app.borrow_mut().session = Some(s);
    render(&app);
    Ok(())
}
async fn open(app: Shared, index: usize) -> Result<()> {
    let mut s = app.borrow().session.clone().ok_or("SEARCH_FIRST")?;
    let row = s.rows.get(index).ok_or("INVALID_ROW")?.clone();
    if s.binding_limit || s.row_limit {
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
    app.borrow_mut().session = Some(s);
    render(&app);
    notice(&app,"Current membership rechecked. Use the separate content link. Metadata authentication does not certify content safety.");
    Ok(())
}
fn render(app: &Shared) {
    let Some(s) = app.borrow().session.clone() else {
        return;
    };
    let root = element(app, "results");
    root.set_text_content(None);
    app.borrow_mut().row_callbacks.clear();
    let scanning = s.next_scan < s.next_case && s.counts.values().any(|n| *n != Uint256::ZERO);
    notice(
        app,
        &format!(
            "Pinned source block {}. {}",
            s.ctx.source.number,
            if s.binding_limit {
                format!("Binding limit reached ({}). Provenance is incomplete at case {}. Rows remain unresolved; no content action is available. Registry pagination can continue.", MAX_BINDINGS, s.next_scan)
            } else if s.row_limit {
                format!("Category row limit reached ({}). The category result is incomplete; rows remain non-actionable.", MAX_CATEGORY_ROWS)
            } else if scanning {
                format!(
                    "Provenance scan next case {} of {}. Continue scan to resolve rows.",
                    s.next_scan, s.next_case
                )
            } else if s.category && !s.done {
                format!(
                    "Collecting category topic {} of {}. Continue scan.",
                    s.topic_index + 1,
                    s.plan.topics.len()
                )
            } else {
                format!(
                    "{} rows on this result set. {}",
                    s.rows.len(),
                    if s.done {
                        "Collection complete."
                    } else {
                        "Next page available."
                    }
                )
            }
        ),
    );
    // Incomplete and capped queries deliberately show non-actionable rows.

    let lo = if s.category {
        s.page * s.profile.page_size
    } else {
        0
    };
    let hi = (lo + s.profile.page_size).min(s.rows.len());
    for i in lo..hi {
        let r = &s.rows[i];
        let d = app.borrow().document.clone();
        let article = d.create_element("article").unwrap();
        let title = d.create_element("h3").unwrap();
        title.set_text_content(Some(
            r.metadata
                .as_ref()
                .map(|m| m.title.as_str())
                .unwrap_or("Unverified metadata"),
        ));
        article.append_child(&title).unwrap();
        let detail = d.create_element("p").unwrap();
        detail.set_text_content(Some(&format!(
            "Entry {} · {}",
            r.entry,
            match &r.resolution {
                Resolution::Unresolved => "UNRESOLVED",
                Resolution::Ambiguous => "AMBIGUOUS",
                Resolution::Resolved(_) => r.error.unwrap_or(if r.metadata.is_some() {
                    "Authenticated metadata and historical LIST provenance"
                } else {
                    "Historical LIST binding; metadata not loaded"
                }),
            }
        )));
        article.append_child(&detail).unwrap();
        if r.metadata.is_some() && !s.binding_limit && !s.row_limit {
            let b = d.create_element("button").unwrap();
            b.set_text_content(Some("Recheck current membership for content"));
            let a = app.clone();
            let cb = Closure::<dyn FnMut()>::new(move || {
                let x = a.clone();
                start_work(x, move |app| open(app, i));
            });
            b.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref())
                .unwrap();
            app.borrow_mut().row_callbacks.push(cb);
            article.append_child(&b).unwrap();
        }
        if let Some(url) = &r.link {
            let a = d
                .create_element("a")
                .unwrap()
                .unchecked_into::<HtmlAnchorElement>();
            a.set_href(url);
            a.set_target("_blank");
            a.set_rel("noopener noreferrer");
            a.set_text_content(Some("Open content separately"));
            article.append_child(&a).unwrap();
        }
        root.append_child(&article).unwrap();
    }
}
pub fn start_search() -> std::result::Result<(), JsValue> {
    let document = web_sys::window()
        .ok_or_else(|| JsValue::from_str("WINDOW_UNAVAILABLE"))?
        .document()
        .ok_or_else(|| JsValue::from_str("DOCUMENT_UNAVAILABLE"))?;
    let app = Rc::new(RefCell::new(App {
        document,
        generation: Rc::new(Cell::new(0)),
        profile: None,
        graph: None,
        category_choices: Vec::new(),
        session: None,
        busy: false,
        row_callbacks: Vec::new(),
    }));
    button(&app, "load-profile", |a| {
        invalidate(&a);
        a.borrow_mut().profile = None;
        start_work(a, load_profile)
    })?;
    button(&app, "load-graph", |a| {
        invalidate(&a);
        a.borrow_mut().graph = None;
        a.borrow_mut().category_choices.clear();
        element(&a, "categories").set_text_content(None);
        start_work(a, load_graph)
    })?;
    button(&app, "search", |a| {
        invalidate(&a);
        start_work(a, |a| begin(a, false))
    })?;
    button(&app, "category-search", |a| {
        invalidate(&a);
        start_work(a, |a| begin(a, true))
    })?;
    button(&app, "continue", |a| start_work(a, advance))?;
    button(&app, "next", |a| start_work(a, next))?;
    button(&app, "retry", |a| start_work(a, retry))?;
    button(&app, "cancel", |a| invalidate(&a))?;
    element(&app, "boot").set_text_content(Some("Load your current search JSON profile."));
    Ok(())
}
