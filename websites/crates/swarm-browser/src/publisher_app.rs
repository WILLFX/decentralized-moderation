//! Publisher UI: exact metadata bytes, pinned reads and explicit wallet actions.
#[path = "publisher/history.rs"]
mod history;
#[path = "publisher/io.rs"]
mod io;
#[path = "publisher/transfers.rs"]
mod transfers;
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
    events_bound: bool,

    history_faults: std::collections::BTreeSet<String>,
    history_cache: std::collections::BTreeMap<String, Vec<Value>>,
    profile: Option<ModeratorProfile>,
    upload: Option<Value>,
    account: Option<String>,
    draft: Option<Draft>,
    uploaded: bool,
    guidelines: bool,
    epoch: u64,
    busy: bool,
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
fn authoring_metadata() -> Result<Value> {
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
    .metadata()
    .map_err(|e| e.0)
}
fn fill_authoring(metadata: &Value) {
    for (id, key) in [
        ("entrytype", "type"),
        ("title", "title"),
        ("language", "language"),
        ("contenttype", "contentType"),
        ("source", "source"),
    ] {
        input(id).set_value(metadata[key].as_str().unwrap_or(""));
    }
    area("description").set_value(metadata["description"].as_str().unwrap_or(""));
    let topics = metadata["topics"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    area("topics").set_value(&topics);
}
fn value(id: &str) -> String {
    input(id).value()
}
fn invalidate(a: &Rc<RefCell<App>>) {
    let mut s = a.borrow_mut();
    s.epoch = s.epoch.wrapping_add(1);
    s.draft = None;
    s.uploaded = false;
    s.guidelines = false;
    input("ack").set_checked(false);
    for id in ["funds", "case", "owned", "guidelines"] {
        text(id, "Evidence cleared after context changed.");
    }
    text("preview", "Draft cleared after context changed.");
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
    let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        let a = state.clone();
        if action == "profile" {
            invalidate(&a);
            a.borrow_mut().profile = None;
            a.borrow_mut().upload = None;
        }
        if a.borrow().busy {
            return;
        }
        a.borrow_mut().busy = true;
        spawn_local(async move {
            let r = run(&a, action).await;
            a.borrow_mut().busy = false;
            if let Err(e) = r {
                text("notice", e);
            }
        });
    });
    el(id)
        .add_event_listener_with_callback(event, cb.as_ref().unchecked_ref())
        .unwrap();
    cb.forget();
}
fn parse_config(raw: &str) -> Result<(ModeratorProfile, Option<Value>)> {
    if raw.len() > 65536 {
        return Err("CONFIG_TOO_LARGE");
    }
    let mut v: Value = serde_json::from_str(raw).map_err(|_| "INVALID_CONFIG")?;
    let obj = v.as_object().ok_or("INVALID_CONFIG")?;
    if obj.keys().any(|k| {
        !["deployment", "rpcUrl", "upload", "display", "guidelinesUrl"].contains(&k.as_str())
    }) {
        return Err("INVALID_CONFIG");
    }
    let upload = v.get("upload").cloned();
    if let Some(u) = &upload {
        let o = u.as_object().ok_or("INVALID_UPLOAD_CONFIG")?;
        if o.keys()
            .any(|k| !["endpoint", "postageBatchId", "authorization"].contains(&k.as_str()))
        {
            return Err("INVALID_UPLOAD_CONFIG");
        }
        let endpoint = u["endpoint"].as_str().ok_or("INVALID_UPLOAD_CONFIG")?;
        swarm_core::review::resource_url(endpoint, "bytes", &format!("0x{}", "1".repeat(64)))
            .map_err(|e| e.0)?;
        let batch = u["postageBatchId"].as_str().ok_or("INVALID_BATCH")?;
        if batch.len() != 64 || !batch.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("INVALID_BATCH");
        }
        if let Some(auth) = u.get("authorization") {
            let s = auth.as_str().ok_or("INVALID_UPLOAD_AUTHORIZATION")?;
            if s.trim().is_empty() || s.len() > 8192 || s.chars().any(|c| c.is_control()) {
                return Err("INVALID_UPLOAD_AUTHORIZATION");
            }
        }
    }
    v.as_object_mut().unwrap().remove("upload");
    v["gatewayUrl"] = json!("http://127.0.0.1/");
    v["timing"] = json!({"clockErrorSeconds":5,"maxEvidenceAgeSeconds":30,"maxHeadLagSeconds":30,"inclusionBudgetSeconds":120});
    Ok((
        swarm_core::parse_profile(&v.to_string()).map_err(|e| e.0)?,
        upload,
    ))
}
async fn run(a: &Rc<RefCell<App>>, action: &str) -> Result<()> {
    match action {
        "exportdraft" | "importdraft" | "exporthistory" | "importhistory" | "savehistory" => {
            transfers::transfer(a, action).await?
        }
        "profile" => {
            invalidate(a);
            a.borrow_mut().profile = None;
            a.borrow_mut().upload = None;
            let epoch = a.borrow().epoch;
            let f = input("profile")
                .files()
                .and_then(|f| f.get(0))
                .ok_or("PROFILE_REQUIRED")?;
            if f.size() > 65536.0 {
                return Err("CONFIG_TOO_LARGE");
            }
            let raw = JsFuture::from(f.text())
                .await
                .map_err(|_| "FILE_READ_FAILED")?
                .as_string()
                .ok_or("FILE_READ_FAILED")?;
            let (p, u) = parse_config(&raw)?;
            active(a, epoch)?;
            text(
                "config",
                &format!(
                    "Chain {}. Moderation {}. Upload settings stay in memory only.",
                    p.deployment.chain_id, p.deployment.moderation.address
                ),
            );
            let mut s = a.borrow_mut();
            s.profile = Some(p);
            s.upload = u;
            text("notice", "Profile loaded. Connect MetaMask.");
        }
        "connect" => {
            install_events(a)?;
            invalidate(a);
            a.borrow_mut().account = None;
            let epoch = a.borrow().epoch;
            let account = wallet::account(&wallet::read("eth_requestAccounts").await?)?;
            let p = a.borrow().profile.clone().ok_or("PROFILE_REQUIRED")?;
            wallet::check(p.deployment.chain_id, &account).await?;
            active(a, epoch)?;
            text("wallet", &format!("Connected: {account}"));
            a.borrow_mut().account = Some(account);
        }
        "funds" => {
            let (p, who, epoch) = context(a)?;
            wallet::check(p.deployment.chain_id, &who).await?;
            let c = io::begin(&p).await?;
            let (min, balance, allowance) = io::funds(&p, &c, &who).await?;
            io::finish(&p, &c).await?;
            active(a, epoch)?;
            text("funds",&format!("Verified at block {}. Minimum fee {min}; balance {balance}; allowance {allowance}. Amounts are base units.",c.source["number"]));
            input("fee").set_value(&min.to_decimal());
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
            invalidate(a);
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
                        "Refund {owed} is paid to original submitter {}.",
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
                let amount = fee(&value("fee")).map_err(|e| e.0)?;
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
                    json!({"contentHash":d.content_hash,"metaHash":d.meta_hash,"topics":d.topic_keys,"fee":fee(&value("fee")).map_err(|e|e.0)?.to_decimal()}),
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
            if records.len() >= 100 {
                return Err("HISTORY_SIZE_LIMIT");
            }
            records.push(history::record(
                &p, &who, action, &to, &data, intent, caseid,
            ));
            if let Err(error) = history::save(a, &p, &who, &records) {
                let reserved = records.pop().ok_or("INVALID_HISTORY")?;
                history::cancel_unsent(a, &p, &who, &reserved);
                return Err(error);
            }
            let result = wallet::send_prepared(p.deployment.chain_id, &who, &to, &data).await;
            let hash = match result {
                Ok(hash) => hash,
                Err(e) => {
                    records.last_mut().unwrap()["state"] = json!(if e == "WALLET_REJECTED" {
                        "rejected"
                    } else {
                        "unknown"
                    });
                    let _ = history::save(a, &p, &who, &records);
                    return Err(e);
                }
            };
            records.last_mut().unwrap()["state"] = json!("unchecked");
            records.last_mut().unwrap()["hash"] = json!(hash);
            let journal_saved = history::save(a, &p, &who, &records).is_ok();
            // Preserve public hash even when wallet context changed while the prompt was open.
            input("txhash").set_value(&hash);
            text("transaction",&format!("{action} broadcast: {hash}. Check receipt; do not resend an uncertain transaction."));
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
            text(
                "transaction",
                &records
                    .iter()
                    .map(|r| format!("{} {}", r["action"], r["hash"]))
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
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
                        "Case {id}: phase {}, refund {refund}, metadata {}",
                        case.phase, case.meta_hash
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
        "case" => {
            let (p, who, epoch) = context(a)?;
            let id = positive(&value("caseid"))?;
            let c = io::begin(&p).await?;
            let (case, owed, topics) = io::case(&p, &c, id).await?;
            io::finish(&p, &c).await?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            text("case",&format!("Case {id}; source block {}\nSubmitter {}\nPhase {} (1 commit A, 2 commit B, 3 reveal, 4 challenge, 5 finalized, 6 unresolved)\nVerdict {} (0 not drawn, 1 approve, 2 reject)\nRefund owed {owed}; recipient {}\nContent {}\nMetadata {}\nTopics {}",c.source["number"],case.submitter,case.phase,case.preliminary,case.submitter,case.content_hash,case.meta_hash,topics.join(", ")));
        }
        "receipt" => {
            let (p, who, epoch) = context(a)?;
            let hash = value("txhash");
            let h = Uint256::hex(&hash).map_err(|e| e.0)?;
            if h == Uint256::ZERO {
                return Err("INVALID_TRANSACTION_HASH");
            }
            let c = io::begin(&p).await?;
            let r = rpc(&p, "eth_getTransactionReceipt", json!([hash])).await?;
            if r.is_null() {
                io::finish(&p, &c).await?;
                active(a, epoch)?;
                text(
                    "transaction",
                    "Pending or not found. Do not resend automatically.",
                );
                return Ok(());
            }
            if !as_str(&r["transactionHash"])?.eq_ignore_ascii_case(&hash)
                || !as_str(&r["from"])?.eq_ignore_ascii_case(&who)
                || ![
                    p.deployment.moderation.address.as_str(),
                    p.deployment.token.address.as_str(),
                ]
                .iter()
                .any(|s| as_str(&r["to"]).is_ok_and(|v| v.eq_ignore_ascii_case(s)))
            {
                return Err("INVALID_RECEIPT");
            }
            let b = rpc(&p, "eth_getBlockByNumber", json!([r["blockNumber"], false])).await?;
            if b["hash"] != r["blockHash"] {
                return Err("RECEIPT_BLOCK_CHANGED");
            }
            if r["status"] != "0x0" && r["status"] != "0x1" {
                return Err("INVALID_RECEIPT");
            }
            io::finish(&p, &c).await?;
            wallet::check(p.deployment.chain_id, &who).await?;
            active(a, epoch)?;
            let mut matched = None;
            let tx = rpc(&p, "eth_getTransactionByHash", json!([hash])).await?;
            if !history::same_hex_bytes(&tx["hash"], &json!(hash), Some(32))
                || !as_str(&tx["from"])?.eq_ignore_ascii_case(&who)
                || !history::same_hex_bytes(&tx["to"], &r["to"], Some(20))
                || tx["value"] != "0x0"
            {
                return Err("INVALID_TRANSACTION");
            }
            let mut records = history::load_current(a, &p, &who)?;
            if let Some(index) =
                history::receipt_record_index(&records, &hash, &tx["to"], &tx["input"])?
            {
                let record = &mut records[index];
                if record["action"] == "submit" && r["status"] == "0x1" {
                    matched = Some(io::submission_receipt(&p, &r, &record["intent"], &who).await?);
                } else if record["action"] == "approve" && r["status"] == "0x1" {
                    matched = Some(format!("Approval confirmed at canonical block {}. Recipient and exact calldata match the saved request. Verify current allowance before submitting.", as_str(&r["blockNumber"])?));
                }
                record["hash"] = json!(hash);
                record["state"] = json!(if r["status"] == "0x1" {
                    "confirmed"
                } else {
                    "failed"
                });
            }
            active(a, epoch)?;
            history::save(a, &p, &who, &records)?;
            active(a, epoch)?;
            if let Some(message) = matched {
                text("transaction", &message);
            } else {
                text("transaction",&format!("Canonical transaction receipt: status {}, block {}. A successful receipt alone does not prove a matching Submitted event; read the case and compare its references.",r["status"],r["blockNumber"]));
            }
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
    el("app").set_inner_html(r#"<header><h1>Swarm Publish</h1></header><p id="notice" role="status">Load the current publisher profile.</p>
 <section><h2>Deployment and wallet</h2><label>Publisher JSON profile <input id="profile" type="file" accept=".json"></label><p id="config">No profile.</p><button id="connect">Connect or refresh MetaMask</button><p id="wallet">Not connected.</p><button id="readfunds">Verify deployment and read fee</button><p id="funds"></p></section>
 <section><h2>Publication draft</h2><p>Upload your content separately. This form publishes metadata for an existing unencrypted content reference.</p><label>Content reference <input id="reference"></label><label for="entrytype">Type</label><input id="entrytype" list="entrytypes" value="article"><datalist id="entrytypes"><option value="article"><option value="post"><option value="comment"><option value="image"><option value="video"><option value="audio"><option value="document"><option value="dataset"><option value="other"></datalist>
<label for="title">Title</label><input id="title" maxlength="200">
<label for="description">Description (optional)</label><textarea id="description" rows="4" maxlength="5000"></textarea>
<label for="topics">Topics — one per line, up to five</label><textarea id="topics" rows="5"></textarea>
<label for="language">Language (optional, for example en)</label><input id="language" maxlength="35">
<label for="contenttype">Content type</label><input id="contenttype" value="text/plain" maxlength="255">
<label for="source">Source (optional)</label><input id="source" maxlength="2048"><button id="draft">Preview exact metadata</button><button id="exportdraft">Export public draft</button><label>Saved public draft <input id="draftfile" type="file" accept=".json"></label><button id="importdraft">Import draft</button><pre id="preview"></pre><button id="loadguidelines">Load and verify pinned guidelines</button><pre id="guidelines"></pre><label><input type="checkbox" id="ack">I reviewed this exact metadata and the verified guidelines.</label><button id="upload">Upload and verify public metadata</button><label>Fee (base units) <input id="fee" value="0"></label><button id="approve">Approve exact fee in MetaMask</button><button id="submit">Submit publication in MetaMask</button></section>
 <section><h2>Cases and refunds</h2><label>Own submission scan cursor <input id="cursor" value="1"></label><button id="loadowned">Scan next 20 case IDs for my submissions</button><pre id="owned"></pre><label>Case ID <input id="caseid"></label><button id="readcase">Read case</button><pre id="case"></pre><button id="refund">Withdraw existing refund to original submitter</button></section>
 <section><h2>Public transaction receipt</h2><label>Transaction hash <input id="txhash"></label><button id="receipt">Check receipt</button><button id="history">Read my public transaction history</button><button id="exporthistory">Export public history</button><button id="savehistory">Retry saving public history</button><label>Saved public history <input id="historyfile" type="file" accept=".json"></label><button id="importhistory">Merge public history</button><pre id="transaction"></pre><p>Every transaction needs your action and wallet confirmation. No automatic retries. The selected RPC supplies these results; runtime checks do not independently verify consensus.</p></section>"#);
    let a = Rc::new(RefCell::new(App::default()));
    for (id, action, event) in [
        ("profile", "profile", "change"),
        ("connect", "connect", "click"),
        ("readfunds", "funds", "click"),
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
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| invalidate(&state));
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
    ] {
        let state = a.clone();
        let cb = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
            let mut s = state.borrow_mut();
            s.epoch = s.epoch.wrapping_add(1);
            text("funds", "Evidence cleared after input changed.");
            text("case", "Evidence cleared after input changed.");
        });
        el(id).add_event_listener_with_callback("input", cb.as_ref().unchecked_ref())?;
        cb.forget();
    }
    Ok(())
}
fn install_events(a: &Rc<RefCell<App>>) -> Result<()> {
    if a.borrow().events_bound {
        return Ok(());
    }
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
        let state = a.clone();
        let cb = Closure::<dyn FnMut(JsValue)>::new(move |_| {
            invalidate(&state);
            state.borrow_mut().account = None;
            text("wallet", "Wallet context changed. Connect again.");
        });
        let ok = on.call2(&provider, &event.into(), cb.as_ref()).is_ok();
        handlers.push((event, cb));
        if !ok {
            for (name, callback) in handlers {
                if remove
                    .call2(&provider, &name.into(), callback.as_ref())
                    .is_err()
                {
                    callback.forget();
                }
            }
            return Err("WALLET_EVENTS_UNAVAILABLE");
        }
    }
    for (_, callback) in handlers {
        callback.forget();
    }
    a.borrow_mut().events_bound = true;
    Ok(())
}
