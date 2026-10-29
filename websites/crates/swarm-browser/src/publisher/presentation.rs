//! Publisher request display uses saved intent, never mutable authoring fields.
use super::*;
pub(super) fn feedback(action: &str) -> &'static str {
    if ["preparearchive", "verifyarchive", "commitarchive"].contains(&action) {
        "archive-feedback"
    } else if action == "publication" {
        "publication-feedback"
    } else if ["profile", "connect", "fetchprofile", "useprofile"].contains(&action) {
        "setup-feedback"
    } else if [
        "contentfile",
        "applybee",
        "uploadcontent",
        "checkcontent",
        "downloadcontent",
    ]
    .contains(&action)
    {
        "content-feedback"
    } else if ["funds", "minimum"].contains(&action) {
        "funds-feedback"
    } else if ["draft", "guidelines", "upload", "usemimetype"].contains(&action) {
        "draft-feedback"
    } else if ["case", "owned", "refund"].contains(&action) {
        "case-feedback"
    } else if ["receipt", "history"].contains(&action) {
        "recovery-feedback"
    } else {
        "transaction-feedback"
    }
}
// Capture the workspace before awaiting. A late result stays with its initiating task.
pub(super) fn task_feedback(action: &str, view: journey::View) -> &'static str {
    match view {
        journey::View::Source if action == "applybee" => "bee-feedback",
        journey::View::Source => "setup-feedback",
        journey::View::Records
            if ["history", "savehistory", "importhistory", "exporthistory"].contains(&action) =>
        {
            "history-feedback"
        }
        journey::View::Records
            if !["preparearchive", "verifyarchive", "commitarchive"].contains(&action) =>
        {
            "recovery-feedback"
        }
        journey::View::Editor if ["exportdraft", "importdraft"].contains(&action) => {
            "authoring-note"
        }
        _ => feedback(action),
    }
}
pub(super) fn bind_requests(a: &Rc<RefCell<App>>) -> std::result::Result<(), JsValue> {
    let state = a.clone();
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |event: web_sys::Event| {
        if state.borrow().busy {
            return;
        }
        let Some(key) = event
            .target()
            .and_then(|e| e.dyn_into::<Element>().ok())
            .and_then(|e| e.get_attribute("data-request"))
        else {
            return;
        };
        event.prevent_default();
        event.stop_propagation();
        let result = (|| -> Result<()> {
            let (p, who, _) = context(&state)?;
            let records = history::load_current(&state, &p, &who)?;
            let record = records
                .iter()
                .find(|r| recovery::identity(r) == key)
                .ok_or("SAVED_REQUEST_NOT_FOUND")?;
            state.borrow_mut().recovery_target = Some(key);
            input("txhash").set_value(
                record["resolution"]["hash"]
                    .as_str()
                    .or(record["candidateHash"].as_str())
                    .or(record["hash"].as_str())
                    .unwrap_or(""),
            );
            text("selected-request", &summary(record, p.display.as_ref()));
            text(
                "selected-request-short",
                &journey::request_summary(record, p.display.as_ref()),
            );
            text("recovery-feedback","Selected this saved request. Check its original hash, or paste the speed-up or cancellation hash from wallet activity. The application will verify the relationship before resolving it.");
            journey::open_records(&state);
            let _ = input("txhash").focus();
            Ok(())
        })();
        if let Err(code) = result {
            journey::open_records(&state);
            text("recovery-feedback", &error(code));
        }
    });
    for id in ["request-list", "publication-list", "wallet-request"] {
        el(id).add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())?;
    }
    handler.forget();
    Ok(())
}

pub(super) struct PendingIntent {
    pub record: Value,
    pub context_changed: bool,
    pub display: Option<swarm_core::Display>,
}
pub(super) fn summary(r: &Value, display: Option<&swarm_core::Display>) -> String {
    let effect = match r["action"].as_str().unwrap_or("") {
        "approve" => {
            let data = r["data"].as_str().unwrap_or("");
            let amount = data.get(74..138).and_then(|s| Uint256::hex(&format!("0x{s}")).ok()).map(|v|crate::token_amounts::describe(v,display)).unwrap_or_else(||"Unavailable".into());
            format!("Allow the moderation contract to spend exactly {amount}. This permission does not pay the publication fee.\nToken: {}",r["to"].as_str().unwrap_or(""))
        },
        "submit" => format!("Pay the publication fee and submit this content for moderation.\nFee: {}\nContent: {}\nMetadata: {}\nTopic keys: {}",r["intent"]["fee"].as_str().and_then(|v|Uint256::decimal(v).ok()).map(|v|crate::token_amounts::describe(v,display)).unwrap_or_else(||"Unavailable".into()),r["intent"]["contentHash"].as_str().unwrap_or(""),r["intent"]["metaHash"].as_str().unwrap_or(""),r["intent"]["topics"]),
        "refund" => format!("Withdraw the existing fee refund for Case {} to its original submitter.",r["caseId"].as_str().unwrap_or("")),
        _ => "Unknown request. Do not send it.".into(),
    };
    format!("Action: {}\n{effect}\nAccount: {}\nChain: {}\nModeration: {}\nCall destination: {}\nNative value sent by this call: 0. The wallet estimates network gas separately.\nState: {}\nOriginal hash: {}\nVerified original nonce: {}",
        r["action"].as_str().unwrap_or(""),r["publisher"].as_str().unwrap_or(""),r["chainId"],r["contract"].as_str().unwrap_or(""),r["to"].as_str().unwrap_or(""),r["state"].as_str().unwrap_or(""),r["hash"].as_str().unwrap_or("Not returned"),r["nonce"].as_str().unwrap_or("Not yet available"))
}
pub(super) fn busy(a: &Rc<RefCell<App>>, value: bool) {
    a.borrow_mut().busy = value;
    for tag in ["button", "input", "textarea", "select"] {
        let fields = doc().get_elements_by_tag_name(tag);
        for i in 0..fields.length() {
            if let Some(field) = fields.item(i) {
                if value {
                    field.set_attribute("disabled", "").unwrap();
                } else {
                    field.remove_attribute("disabled").unwrap();
                }
            }
        }
    }
    if !value && !a.borrow().refund_ready {
        el("refund").set_attribute("disabled", "").unwrap();
    }
}
pub(super) fn pending(a: &Rc<RefCell<App>>) {
    journey::render(a);
    let a = a.borrow();
    if let Some(p) = &a.pending_wallet {
        journey::hidden(
            "wallet-request",
            !["requesting", "unknown", "unchecked"]
                .contains(&p.record["state"].as_str().unwrap_or("")),
        );
        text("wallet-intent", &summary(&p.record, p.display.as_ref()));
        text(
            "wallet-request-note",
            if p.context_changed
                && ["requesting", "unknown", "unchecked"]
                    .contains(&p.record["state"].as_str().unwrap_or(""))
            {
                "The account or page context changed while the wallet request was open. The wallet can still describe the saved request above. Check or reject that request in the wallet. A page change does not cancel it; its hash and any uncertainty are retained."
            } else if p.record["state"] == "requesting" {
                "Waiting for your wallet. The fields are locked to keep this request clear. Review or reject it in the wallet; this page cannot cancel an open wallet request."
            } else if ["unknown", "unchecked"].contains(&p.record["state"].as_str().unwrap_or("")) {
                "The request still needs reconciliation. Its saved intent is retained below. Use its recovery card to check the original or replacement hash before preparing another matching send."
            } else {
                "The wallet request has a recorded result. Its saved intent remains shown for reference."
            },
        );
    }
}
pub(super) fn render_history(a: &Rc<RefCell<App>>) -> Result<()> {
    let (p, who, _) = context(a)?;
    let records = history::load_current(a, &p, &who)?;
    el("request-list").set_text_content(None);
    let (visible, pages) = archive::page(&records, a.borrow().history_page);
    let current = a.borrow().history_page.min(pages - 1);
    a.borrow_mut().history_page = current;
    text("history-page",&format!("History page {} of {pages}. {} retained records across active and archived history. Export saves this displayed page.",current+1,records.len()));
    for (id, on) in [
        ("historyprev", current > 0),
        ("historynext", current + 1 < pages),
    ] {
        if on && !a.borrow().busy {
            el(id).remove_attribute("disabled").unwrap();
        } else {
            el(id).set_attribute("disabled", "").unwrap();
        }
    }
    let archived = history::load_store(a, &p, &who)
        .map(|s| s.archived)
        .unwrap_or_default();
    for record in &visible {
        let card = doc()
            .create_element("article")
            .map_err(|_| "DOM_UNAVAILABLE")?;
        card.set_class_name("request-card");
        if archived.contains_key(&recovery::identity(record)) {
            let note = doc().create_element("p").unwrap();
            note.set_text_content(Some("Archived locally after saved-backup verification. Full transaction evidence is retained."));
            card.append_child(&note).unwrap();
        }
        let details = doc()
            .create_element("details")
            .map_err(|_| "DOM_UNAVAILABLE")?;
        let title = doc()
            .create_element("summary")
            .map_err(|_| "DOM_UNAVAILABLE")?;
        title.set_text_content(Some(&format!(
            "{} request — {}",
            record["action"].as_str().unwrap_or(""),
            record["state"].as_str().unwrap_or("")
        )));
        details.append_child(&title).unwrap();
        let body = doc().create_element("pre").unwrap();
        body.set_text_content(Some(&summary(record, p.display.as_ref())));
        details.append_child(&body).unwrap();
        card.append_child(&details).unwrap();
        let status = doc().create_element("p").unwrap();
        status.set_text_content(Some(&if !record["resolution"].is_null() {
            format!("Verified {}: {}. The original hash is retained.",record["resolution"]["kind"].as_str().unwrap_or(""),record["resolution"]["hash"].as_str().unwrap_or(""))
        } else if record["hash"].is_null() && ["requesting","unknown"].contains(&record["state"].as_str().unwrap_or("")) {
            "No hash was returned. Check wallet activity for a transaction matching this saved intent. Select this request, paste its hash and check the receipt. An absent hash is not proof that nothing was sent.".into()
        } else {format!("Original hash: {}. {}",record["hash"].as_str().unwrap_or("Not returned"),if ["requesting","unknown","unchecked"].contains(&record["state"].as_str().unwrap_or("")) {"This request remains unresolved. Check it before another matching send."} else {"Recorded result; use Check to verify it again."})}));
        card.append_child(&status).unwrap();
        if record["state"] == "rejected" && record["hash"].is_null() {
            status.set_text_content(Some("Rejected in the wallet. This request has no transaction hash to check; you may deliberately prepare a new request."));
            el("request-list").append_child(&card).unwrap();
            continue;
        }
        let button = doc().create_element("button").unwrap();
        button.set_attribute("type", "button").unwrap();
        button
            .set_attribute("data-request", &recovery::identity(record))
            .unwrap();
        button.set_text_content(Some(&format!(
            "Check {} request {}",
            record["action"].as_str().unwrap_or(""),
            record["hash"].as_str().unwrap_or("without a returned hash")
        )));
        if a.borrow().busy {
            button.set_attribute("disabled", "").unwrap();
        }
        card.append_child(&button).unwrap();
        el("request-list").append_child(&card).unwrap();
    }
    let selected = a.borrow().recovery_target.clone();
    if let Some(record) =
        selected.and_then(|key| records.iter().find(|r| recovery::identity(r) == key))
    {
        text("selected-request", &summary(record, p.display.as_ref()));
        text(
            "selected-request-short",
            &journey::request_summary(record, p.display.as_ref()),
        );
    }
    text(
        "request-list-note",
        if records.is_empty() {
            "No saved requests for this account and deployment."
        } else {
            "Select a saved request before checking a speed-up or cancellation hash. Recovery verifies its account, nonce and mined receipt; it never resends a transaction."
        },
    );
    Ok(())
}
pub(super) fn error(code: &str) -> String {
    let help = match code {
        "HISTORY_CONCURRENT_CHANGE"=>"Another tab checked this request differently while this tab had unsaved changes. Keep both the saved history and this tab. Select the request and check its receipt again before retrying a save or send; no result was overwritten.",
        "HISTORY_ACTIVE_CAPACITY"|"HISTORY_SIZE_LIMIT"=>"The active journal needs more space before a new wallet request. Check capacity in transaction recovery. Back up and archive resolved records; uncertain requests must remain active. Receipt checks and export remain available.",
        "HISTORY_STORAGE_CAPACITY"=>"Retained local history has reached its bounded storage capacity. Keep this tab open and export the relevant history pages. No records were removed; do not clear storage to bypass uncertain-request guards.",
        "HISTORY_IMPORT_CAPACITY"=>"This import would overfill the active journal. No imported records were saved. Archive eligible resolved records first, then retry; imported status cannot retire uncertainty.",
        "HISTORY_BUSY_IN_ANOTHER_TAB"=>"Another publisher tab is changing history or waiting for its wallet request. Finish that action, then retry here explicitly. Nothing was queued to send later.",
        "HISTORY_COORDINATION_UNAVAILABLE"|"HISTORY_COORDINATION_FAILED"=>"This browser cannot coordinate safe journal writes between tabs. No new wallet request was made. Read and export remain available; use a browser with Web Locks support to continue writes.",
        "NOTHING_TO_ARCHIVE"=>"No locally resolved active records are eligible. Keep requesting, unknown and unchecked records, and check their receipts first. A missing hash or old age does not make a request safe to retire.",
        "ARCHIVE_PREPARE_REQUIRED"=>"Download a fresh archive backup for this account and deployment before verifying a file.",
        "ARCHIVE_FILE_REQUIRED"|"ARCHIVE_VERIFY_REQUIRED"=>"Select the saved archive backup and verify it before archiving. No records have moved.",
        "ARCHIVE_FILE_LIMIT"=>"This backup exceeds the bounded file size. Keep the records and export the relevant smaller history pages; no records have moved.",
        "ARCHIVE_FILE_MISMATCH"=>"The selected file does not exactly match the prepared backup. Select the correct saved file or download a fresh backup. No records have moved.",
        "ARCHIVE_SNAPSHOT_CHANGED"=>"A selected record changed after the backup was prepared. No records have moved. Download and verify a fresh backup; later requests and recovery updates are retained.",
        "HISTORY_SAVE_FAILED"|"HISTORY_UNAVAILABLE"=>"Browser history could not be saved or read. Keep this tab open, export its known records and retry saving. Archive completion is not confirmed and no uncertain record was cleared.",
        "SUBMISSION_NOT_VERIFIED" => "The submission receipt is not currently verified. No case was opened from an old or imported hint. Keep the saved request and check its transaction receipt before retrying.",
        "INVALID_CASE_REFERENCE" | "SUBMISSION_MISMATCH" => "The saved submission and case evidence do not match. The case has not been accepted as this publication. Keep the history and check the matching receipt and deployment.",
        "INVALID_RECEIPT_HASH" => "Paste the complete 0x transaction hash from wallet activity, then check its receipt. A receipt check does not send a transaction.",
        "HISTORY_AMBIGUOUS_TRANSACTION" => "More than one saved request could match this transaction. Selecting a card cannot prove which hashless request it belongs to. Keep those requests; no uncertainty was cleared and no transaction was sent.",
        "CHECK_PRIOR_TRANSACTION_BEFORE_RESENDING" => "An earlier matching request is unresolved. Read the saved request cards and check the original, speed-up or cancellation hash. No new transaction was sent.",
        "ORIGINAL_NONCE_UNAVAILABLE" => "The RPC cannot find the original transaction, and its nonce was not previously verified. The application cannot prove this replacement belongs to that request. Keep the request and check wallet activity; do not resend it.",
        "REQUEST_BOUNDARY_UNAVAILABLE" => "This older or imported no-hash request has no trusted starting block. A matching old receipt cannot safely resolve it. Keep the history and inspect wallet activity; this application will not clear that uncertainty.",
        "TRANSACTION_PREDATES_REQUEST" => "This transaction was already mined before the saved request began. It cannot resolve that request. Select the intended request and check its actual wallet hash.",
        "SELECT_SAVED_REQUEST" | "SAVED_REQUEST_NOT_FOUND" => "Select the intended saved request from its recovery card, then paste the original, replacement or cancellation hash and check it.",
        "REPLACEMENT_NONCE_MISMATCH" | "REPLACEMENT_INTENT_MISMATCH" | "RECOVERY_TRANSACTION_MISMATCH" | "HISTORY_TRANSACTION_MISMATCH" | "ORIGINAL_TRANSACTION_MISMATCH" | "RECEIPT_BELONGS_TO_ANOTHER_REQUEST" => "This transaction does not prove the selected request's intended action or cancellation. The saved request remains unresolved. Check that you selected the right request and wallet transaction.",
        "WALLET_REJECTED" => "You rejected the wallet request. That request is recorded as rejected; no automatic retry will occur.",
        "WALLET_REQUEST_FAILED" | "INVALID_TRANSACTION_HASH" => "The wallet did not return a usable transaction hash. A transaction might still have been sent. Keep the saved request and check wallet activity before trying again.",
        _ => "The check could not complete. Keep the saved request. Review the error details and check the relevant wallet activity before retrying a send.",
    };
    format!("{help}\nDetails: {code}")
}

#[cfg(test)]
mod task_feedback_tests {
    use super::*;
    #[test]
    fn shared_actions_report_to_the_workspace_that_started_them() {
        assert_eq!(
            task_feedback("funds", journey::View::Source),
            "setup-feedback"
        );
        assert_eq!(
            task_feedback("funds", journey::View::Review),
            "funds-feedback"
        );
        assert_eq!(
            task_feedback("applybee", journey::View::Source),
            "bee-feedback"
        );
        for action in ["savehistory", "importhistory", "exporthistory", "history"] {
            assert_eq!(
                task_feedback(action, journey::View::Records),
                "history-feedback"
            );
        }
        assert_eq!(
            task_feedback("verifyarchive", journey::View::Records),
            "archive-feedback"
        );
        assert_eq!(
            task_feedback("submit", journey::View::Review),
            "transaction-feedback"
        );
    }
}
