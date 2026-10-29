//! Durable submission references, with fresh receipt and case checks on every open.
use super::*;
use swarm_core::moderator::{
    decode_outcome_recovery, decode_schedule, CaseInfo, OutcomeRecovery, PairSchedule,
};

pub(super) fn validate(record: &Value) -> Result<()> {
    if let Some(hint) = record.get("caseHint").filter(|v| !v.is_null()) {
        if record["action"] != "submit" {
            return Err("INVALID_CASE_REFERENCE");
        }
        positive(as_str(hint)?)?;
    }
    if let Some(e) = record.get("caseEvidence").filter(|v| !v.is_null()) {
        if record["action"] != "submit"
            || ["failed", "cancelled", "rejected"].contains(&record["state"].as_str().unwrap_or(""))
            || e.as_object()
                .ok_or("INVALID_CASE_REFERENCE")?
                .keys()
                .any(|k| {
                    !["caseId", "transactionHash", "blockNumber", "blockHash"].contains(&k.as_str())
                })
            || !history::same_hex_bytes(&e["transactionHash"], &record["hash"], Some(32))
                && !history::same_hex_bytes(
                    &e["transactionHash"],
                    &record["resolution"]["hash"],
                    Some(32),
                )
        {
            return Err("INVALID_CASE_REFERENCE");
        }
        positive(as_str(&e["caseId"])?)?;
        if !history::same_hex_bytes(&e["blockHash"], &e["blockHash"], Some(32))
            || Uint256::hex(as_str(&e["blockHash"])?).map_err(|e| e.0)? == Uint256::ZERO
        {
            return Err("INVALID_CASE_REFERENCE");
        }
        crate::transport::quantity(as_str(&e["blockNumber"])?)?;
    }
    Ok(())
}
pub(super) fn bind(a: &Rc<RefCell<App>>) -> std::result::Result<(), JsValue> {
    let state = a.clone();
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |event: web_sys::Event| {
        if state.borrow().busy {
            return;
        }
        let Some(key) = event
            .target()
            .and_then(|e| e.dyn_into::<Element>().ok())
            .and_then(|e| e.get_attribute("data-publication"))
        else {
            return;
        };
        state.borrow_mut().publication_target = Some(key);
        dispatch(state.clone(), "publication");
    });
    el("publication-list")
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())?;
    handler.forget();
    Ok(())
}
pub(super) fn render(a: &Rc<RefCell<App>>) -> Result<()> {
    let (p, who, _) = context(a)?;
    let records = history::load_current(a, &p, &who)?;
    el("publication-list").set_text_content(None);
    let mut count = 0;
    let submissions = records
        .iter()
        .rev()
        .filter(|r| r["action"] == "submit")
        .collect::<Vec<_>>();
    let pages = submissions.len().div_ceil(ledger::PAGE).max(1);
    let current = a.borrow().publication_page.min(pages - 1);
    a.borrow_mut().publication_page = current;
    text("publication-page",&format!("Publication page {} of {pages}; {} saved submission records, including archived history.",current+1,submissions.len()));
    for (id, on) in [
        ("publicationprev", current > 0),
        ("publicationnext", current + 1 < pages),
    ] {
        if on && !a.borrow().busy {
            el(id).remove_attribute("disabled").unwrap();
        } else {
            el(id).set_attribute("disabled", "").unwrap();
        }
    }
    for r in submissions
        .into_iter()
        .skip(current * ledger::PAGE)
        .take(ledger::PAGE)
    {
        count += 1;
        let card = doc().create_element("article").unwrap();
        card.set_class_name("request-card");
        let heading = doc().create_element("h3").unwrap();
        let id = r["caseEvidence"]["caseId"].as_str();
        heading.set_text_content(Some(
            &id.map(|id| format!("Case {id}"))
                .unwrap_or_else(|| "Submission awaiting receipt verification".into()),
        ));
        card.append_child(&heading).unwrap();
        let status = doc().create_element("p").unwrap();
        status.set_text_content(Some(&if let Some(id)=id {
            format!("Case {id} was verified from its submission receipt at block {}. Opening it rechecks the receipt and current case. Read the dated status below for moderation and current index membership.",r["caseEvidence"]["blockNumber"].as_str().unwrap_or(""))
        } else if !r["caseHint"].is_null() {
            format!("Imported case hint: {}. This is not verified case identity. Check the actual submission receipt before opening a case.",r["caseHint"].as_str().unwrap_or(""))
        } else {format!("Saved submission state: {}. A broadcast or approval alone does not verify a submitted case.",r["state"].as_str().unwrap_or(""))}));
        card.append_child(&status).unwrap();
        let refs = doc().create_element("details").unwrap();
        let summary = doc().create_element("summary").unwrap();
        summary.set_text_content(Some("Saved publication references"));
        refs.append_child(&summary).unwrap();
        let body = doc().create_element("pre").unwrap();
        body.set_text_content(Some(&format!(
            "Content: {}\nMetadata: {}\nSubmission transaction: {}",
            r["intent"]["contentHash"].as_str().unwrap_or(""),
            r["intent"]["metaHash"].as_str().unwrap_or(""),
            r["caseEvidence"]["transactionHash"]
                .as_str()
                .or(r["candidateHash"].as_str())
                .or(r["hash"].as_str())
                .unwrap_or("No hash returned")
        )));
        refs.append_child(&body).unwrap();
        card.append_child(&refs).unwrap();
        if !["failed", "cancelled", "rejected"].contains(&r["state"].as_str().unwrap_or(""))
            && (!r["hash"].is_null() || !r["candidateHash"].is_null())
        {
            let button = doc().create_element("button").unwrap();
            button.set_attribute("type", "button").unwrap();
            button
                .set_attribute("data-publication", &recovery::identity(r))
                .unwrap();
            button.set_text_content(Some(
                &id.map(|id| format!("Read Case {id} and refresh publication status"))
                    .unwrap_or_else(|| "Verify submission receipt and open publication".into()),
            ));
            if a.borrow().busy {
                button.set_attribute("disabled", "").unwrap();
            }
            card.append_child(&button).unwrap();
        }
        if !["confirmed", "failed", "cancelled", "rejected"]
            .contains(&r["state"].as_str().unwrap_or(""))
        {
            let recovery = doc().create_element("button").unwrap();
            recovery.set_class_name("secondary");
            recovery.set_attribute("type", "button").unwrap();
            recovery
                .set_attribute("data-request", &recovery::identity(r))
                .unwrap();
            recovery.set_text_content(Some("Recover this saved submission"));
            if a.borrow().busy {
                recovery.set_attribute("disabled", "").unwrap();
            }
            card.append_child(&recovery).unwrap();
        }
        el("publication-list").append_child(&card).unwrap();
    }
    text(
        "publication-list-note",
        if count == 0 {
            "No saved submissions for this account and deployment. Import public history if a submission is missing."
        } else {
            "These are saved submission records for this account and deployment. Use a card to refresh its status; you do not need to copy a case ID or scan the global queue."
        },
    );
    Ok(())
}
pub(super) async fn open(a: &Rc<RefCell<App>>) -> Result<()> {
    journey::clear_publication(a);
    text(
        "publication-status",
        "Checking the saved submission receipt before reading current publication status…",
    );
    text("case","Current case evidence has not been read for this saved request. Its submission receipt must be verified first.");
    a.borrow_mut().refund_ready = false;
    let (p, who, epoch) = context(a)?;
    let key = a
        .borrow()
        .publication_target
        .clone()
        .ok_or("SAVED_REQUEST_NOT_FOUND")?;
    let records = history::load_current(a, &p, &who)?;
    let record = records
        .iter()
        .find(|r| recovery::identity(r) == key && r["action"] == "submit")
        .ok_or("SAVED_REQUEST_NOT_FOUND")?
        .clone();
    let hash = record["caseEvidence"]["transactionHash"]
        .as_str()
        .or(record["candidateHash"].as_str())
        .or(record["resolution"]["hash"].as_str())
        .or(record["hash"].as_str())
        .ok_or("INVALID_RECEIPT_HASH")?;
    input("txhash").set_value(hash);
    a.borrow_mut().recovery_target = Some(key);
    let id = recovery::check(a).await?.ok_or("SUBMISSION_NOT_VERIFIED")?;
    active(a, epoch)?;
    read_case(a, id, Some(&record["intent"])).await
}
pub(super) fn matches(case: &CaseInfo, topics: &[String], intent: &Value, who: &str) -> bool {
    let Some(expected) = intent["topics"].as_array() else {
        return false;
    };
    let Some(content) = intent["contentHash"]
        .as_str()
        .and_then(|v| v.strip_prefix("0x"))
        .and_then(|v| hex::decode(v).ok())
    else {
        return false;
    };
    let Some(metadata) = intent["metaHash"]
        .as_str()
        .and_then(|v| v.strip_prefix("0x"))
        .and_then(|v| hex::decode(v).ok())
    else {
        return false;
    };
    let claim = swarm_core::keccak256_hex(&[content, metadata].concat());
    case.action_type == 0
        && case.target_case_id == Uint256::ZERO
        && case.submitter.eq_ignore_ascii_case(who)
        && case.claim_key == claim
        && case.content_hash == intent["contentHash"]
        && case.meta_hash == intent["metaHash"]
        && case.topic_count as usize == expected.len()
        && (1..=5).contains(&expected.len())
        && topics.len() == 5
        && expected
            .iter()
            .enumerate()
            .all(|(i, v)| v.as_str() == Some(topics[i].as_str()))
        && topics[expected.len()..]
            .iter()
            .all(|s| Uint256::hex(s).is_ok_and(|v| v == Uint256::ZERO))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn case() -> CaseInfo {
        let mut fields = [0u64; 25];
        fields[7] = 1;
        fields[9] = 900;
        fields[15] = 3;
        let raw = format!(
            "0x{}",
            fields
                .iter()
                .map(|n| Uint256::from_u64(*n).abi())
                .collect::<String>()
        );
        swarm_core::moderator::decode_case(&raw).unwrap()
    }
    #[test]
    fn effective_committee_b_and_closed_windows_are_not_reported_as_committee_a() {
        let c = case();
        let schedule = PairSchedule {
            deadline_a: 900,
            deadline_b: 1500,
            entropy_b: format!("0x{}", "00".repeat(32)),
            revised: false,
        };
        assert_eq!(
            stage(&c, &schedule, 1000),
            ("Under review — committee B commitments", Some(1500))
        );
        assert!(stage(&c, &schedule, 1600).0.contains("closed"));
        let mut no_votes = c;
        no_votes.commits_a = 0;
        assert!(stage(&no_votes, &schedule, 1000).0.contains("closed"));
    }
    #[test]
    fn case_reference_is_full_width_bound_to_submission_and_imported_only_as_a_hint() {
        let mut r = json!({"action":"submit","state":"confirmed","hash":format!("0x{}","66".repeat(32)),"caseEvidence":{"caseId":"18446744073709551616","transactionHash":format!("0x{}","66".repeat(32)),"blockNumber":"0x10","blockHash":format!("0x{}","aa".repeat(32))}});
        validate(&r).unwrap();
        let mut foreign = r.clone();
        foreign["caseEvidence"]["transactionHash"] = json!(format!("0x{}", "77".repeat(32)));
        assert!(validate(&foreign).is_err());
        recovery::reset_import(&mut r);
        assert!(r["caseEvidence"].is_null());
        assert_eq!(r["caseHint"], "18446744073709551616");
        assert_eq!(r["state"], "unchecked");
    }
    #[test]
    fn old_journal_updates_keep_derived_case_identity_but_failure_retires_it() {
        let r = json!({"action":"submit","requestId":"one","hash":format!("0x{}","66".repeat(32)),"state":"confirmed","caseEvidence":{"caseId":"19"}});
        let mut update = r.clone();
        update.as_object_mut().unwrap().remove("caseEvidence");
        assert_eq!(
            history::merge(&[r.clone()], &[update.clone()]).unwrap()[0]["caseEvidence"]["caseId"],
            "19"
        );
        update["state"] = json!("failed");
        assert!(history::merge(&[r], &[update]).unwrap()[0]["caseEvidence"].is_null());
    }
    #[test]
    fn fresh_case_identity_must_match_the_publisher_references_claim_and_topics() {
        let mut c = case();
        c.content_hash = format!("0x{}", "66".repeat(32));
        c.meta_hash = format!("0x{}", "77".repeat(32));
        c.submitter = format!("0x{}", "55".repeat(20));
        c.topic_count = 1;
        c.claim_key = swarm_core::keccak256_hex(
            &hex::decode(format!("{}{}", "66".repeat(32), "77".repeat(32))).unwrap(),
        );
        let topic = format!("0x{}", "88".repeat(32));
        let mut topics = vec![topic.clone()];
        topics.extend(vec![format!("0x{}", "00".repeat(32)); 4]);
        let intent = json!({"contentHash":c.content_hash,"metaHash":c.meta_hash,"topics":[topic]});
        assert!(matches(&c, &topics, &intent, &c.submitter));
        let mut wrong = c.clone();
        wrong.claim_key = format!("0x{}", "99".repeat(32));
        assert!(!matches(&wrong, &topics, &intent, &c.submitter));
        assert!(!matches(
            &c,
            &topics,
            &intent,
            &format!("0x{}", "aa".repeat(20))
        ));
        topics[0] = format!("0x{}", "bb".repeat(32));
        assert!(!matches(&c, &topics, &intent, &c.submitter));
    }
}
pub(super) fn stage(
    c: &CaseInfo,
    schedule: &PairSchedule,
    now: u64,
) -> (&'static str, Option<u64>) {
    match c.phase {
        1 if now < schedule.deadline_a => (
            "Under review — committee A commitments",
            Some(schedule.deadline_a),
        ),
        1 | 2
            if now < schedule.deadline_b
                && !(c.phase == 1 && c.challenges == 0 && c.commits_a == 0) =>
        {
            (
                "Under review — committee B commitments",
                Some(schedule.deadline_b),
            )
        }
        1 | 2 => ("Commit windows closed — awaiting case progress", None),
        3 if c.outcome_seed_block != 0 => ("Awaiting outcome draw", None),
        3 if now >= c.phase_deadline => ("Reveal deadline reached — awaiting case progress", None),
        3 => ("Under review — reveal phase", Some(c.phase_deadline)),
        4 => (
            "Preliminary outcome — challenge phase",
            Some(c.phase_deadline),
        ),
        5 => ("Finalized moderation outcome", None),
        6 => ("Unresolved — no final moderation outcome", None),
        _ => ("Unsupported case phase", None),
    }
}
fn time(seconds: u64) -> String {
    String::from(js_sys::Date::new(&((seconds as f64) * 1000.0).into()).to_iso_string())
}
/// A pinned capability read may be unavailable on older deployments. Never infer
/// irrecoverable expiry from age alone or an RPC failure.
fn draw_status(case: &CaseInfo, height: u64, recovery: Option<&OutcomeRecovery>) -> String {
    if let Some(r) = recovery {
        if r.expired {
            return if case.challenges == 0 {
                "\nInitial draw expired; case unresolved. Current refund availability is shown below.".into()
            } else {
                "\nThe last completed outcome finalized after draw expiry. Ordinary settlement follows that fallback; it does not prove responsibility for the failed draw.".into()
            };
        }
    }
    if case.phase != 3 || case.outcome_seed_block == 0 {
        return String::new();
    }
    let Some(r) = recovery else {
        return "\nOriginal-hash recovery support could not be verified at this read. No expiry conclusion was accepted; refresh current evidence.".into();
    };
    if r.cached() {
        "\nOriginal draw hash saved. It remains drawable without an age limit; a draw still needs an explicit transaction.".into()
    } else if height <= case.outcome_seed_block {
        format!(
            "\nOutcome draw waits for a block after original target {}.",
            case.outcome_seed_block
        )
    } else if height <= r.recover_until {
        format!("\nOriginal-hash recovery remains within its window through block {}, inclusive. A failed history read does not permit early expiry.", r.recover_until)
    } else if case.challenges == 0 {
        "\nOriginal-hash recovery ended without a saved hash. An explicit expiry call can make the case unresolved and its fee refundable; no refund is yet inferred.".into()
    } else {
        format!("\nOriginal-hash recovery ended without a saved hash. An explicit expiry call can finalize the last completed outcome: {}. The case has not finalized merely because the boundary passed.", crate::moderator_view::choice(case.action_type, case.preliminary))
    }
}
pub(super) async fn read_case(
    a: &Rc<RefCell<App>>,
    id: Uint256,
    expected: Option<&Value>,
) -> Result<()> {
    a.borrow_mut().refund_ready = false;
    journey::clear_publication(a);
    text("case", "Reading current case evidence…");
    let (p, who, epoch) = context(a)?;
    let ctx = io::begin(&p).await?;
    let (case, owed, topics) = io::case(&p, &ctx, id).await?;
    if expected.is_some_and(|intent| !matches(&case, &topics, intent, &who)) {
        return Err("SUBMISSION_MISMATCH");
    }
    let schedule = decode_schedule(
        &io::view(
            &p,
            &ctx,
            &p.deployment.moderation.address,
            "pairScheduleOf(uint256)",
            &id.abi(),
        )
        .await?,
    )
    .map_err(|e| e.0)?;
    let mut listed = 0;
    for topic in topics.iter().take(case.topic_count as usize) {
        let raw = io::view(
            &p,
            &ctx,
            &p.deployment.index.address,
            "isListed(bytes32,bytes32)",
            &format!("{}{}", &case.claim_key[2..], &topic[2..]),
        )
        .await?;
        let value = Uint256::hex(&raw).map_err(|e| e.0)?;
        if value == Uint256::from_u64(1) {
            listed += 1;
        } else if value != Uint256::ZERO {
            return Err("INVALID_MEMBERSHIP");
        }
    }
    let recovery = if case.outcome_seed_block != 0 && [3, 5, 6].contains(&case.phase) {
        io::view(
            &p,
            &ctx,
            &p.deployment.moderation.address,
            "outcomeRecoveryOf(uint256)",
            &id.abi(),
        )
        .await
        .ok()
        .and_then(|raw| decode_outcome_recovery(&raw, &case).ok())
    } else {
        None
    };
    io::finish(&p, &ctx).await?;
    wallet::check(p.deployment.chain_id, &who).await?;
    active(a, epoch)?;
    let now = crate::transport::quantity(as_str(&ctx.source["timestamp"])?)?;
    let (phase, deadline) = stage(&case, &schedule, now);
    let when = deadline
        .map(|d| {
            format!(
                "\nPhase deadline: {} ({} remaining at this read)",
                time(d),
                crate::moderator_view::duration(d.saturating_sub(now))
            )
        })
        .unwrap_or_default();
    let decision = if case.preliminary == 0 {
        "No outcome drawn"
    } else {
        crate::moderator_view::choice(case.action_type, case.preliminary)
    };
    let next = if owed != Uint256::ZERO {
        "A submission refund is available. The refund control pays the original submitter; it does not pay another connected account."
    } else if case.phase == 6 {
        "No submission refund remains owed at this read. There is no final moderation outcome."
    } else if case.phase == 5 {
        "The moderation outcome is final. Current membership is reported separately because later removal or listing decisions can change it."
    } else {
        "The submission is still under moderation. Do not submit it again to refresh its status; return to this saved publication and read its current state."
    };
    let draw = draw_status(
        &case,
        crate::transport::quantity(as_str(&ctx.source["number"])?)?,
        recovery.as_ref(),
    );
    let completed = if [5, 6].contains(&case.phase) && case.finalized_at != 0 {
        format!("\nModeration completed: {}.", time(case.finalized_at))
    } else {
        String::new()
    };
    let height = crate::transport::quantity(as_str(&ctx.source["number"])?)?;
    let refund = crate::token_amounts::describe(owed, p.display.as_ref());
    let body=format!("Case {id}\n{}\n{phase}{when}{draw}{completed}\n{} outcome: {decision}\nCurrent index membership: {listed} of {} submitted topics listed.\nRefund owed: {refund}; recipient {}.\n{next}\nSource: block {height}, {}. Refresh for current evidence.\nContent: {}\nMetadata: {}",
        crate::moderator_view::question(&case),if case.phase==5 {"Final"} else {"Preliminary"},case.topic_count,case.submitter,time(now),case.content_hash,case.meta_hash);
    let publication_key = if expected.is_some() {
        a.borrow().publication_target.clone()
    } else {
        None
    };
    a.borrow_mut().journey.publication = Some(journey::Publication {
        key: publication_key,
        id: id.to_decimal(),
        phase: format!(
            "{phase} · {} outcome: {decision}",
            if case.phase == 5 {
                "Final"
            } else {
                "Preliminary"
            }
        ),
        membership: format!(
            "Current index: {listed} of {} submitted topics listed.",
            case.topic_count
        ),
        next: if owed != Uint256::ZERO {
            format!("Refund owed at this read: {refund}. Recipient: {}. A later request needs a fresh check.",case.submitter)
        } else if !draw.is_empty() {
            draw.trim().to_owned()
        } else {
            next.to_owned()
        },
        source: format!(
            "Checked at block {height} · {}. Refresh for current status.",
            time(now)
        ),
        refund: owed != Uint256::ZERO,
    });
    input("caseid").set_value(&id.to_decimal());
    a.borrow_mut().refund_ready = owed != Uint256::ZERO;
    text("case", &body);
    if expected.is_some() {
        text("publication-status", &body);
        text(
            "publication-feedback",
            "Current case, membership and refund checked. No transaction was requested.",
        );
    } else {
        text("publication-status", &body);
    }
    Ok(())
}

#[cfg(test)]
mod outcome_tests {
    use super::*;
    fn case() -> CaseInfo {
        let mut words = [0u64; 25];
        words[3] = 1;
        words[4] = 1;
        words[7] = 3;
        words[13] = 100;
        swarm_core::moderator::decode_case(&format!(
            "0x{}",
            words
                .iter()
                .map(|n| format!("{n:064x}"))
                .collect::<String>()
        ))
        .unwrap()
    }
    fn recovery() -> OutcomeRecovery {
        OutcomeRecovery {
            original_hash: format!("0x{}", "00".repeat(32)),
            recover_until: 8291,
            expired: false,
        }
    }
    #[test]
    fn history_window_is_not_the_old_250_block_limit() {
        let c = case();
        let r = recovery();
        for height in [351, 8291] {
            assert!(draw_status(&c, height, Some(&r)).contains("remains within"));
        }
        assert!(draw_status(&c, 8292, Some(&r)).contains("no refund is yet inferred"));
        assert!(draw_status(&c, 100, Some(&r)).contains("waits"));
    }
    #[test]
    fn cached_original_never_gets_an_expiry_label() {
        let c = case();
        let mut r = recovery();
        r.original_hash = format!("0x{}", "ab".repeat(32));
        let text = draw_status(&c, 100000, Some(&r));
        assert!(text.contains("without an age limit"));
        assert!(!text.contains("ended"));
    }
    #[test]
    fn unavailable_support_is_not_proof_of_expiry() {
        assert!(draw_status(&case(), 100000, None).contains("No expiry conclusion"));
    }
    #[test]
    fn challenge_and_initial_expiry_have_different_consequences() {
        let mut c = case();
        let mut r = recovery();
        c.challenges = 1;
        c.preliminary = 1;
        assert!(draw_status(&c, 8292, Some(&r)).contains("List this content"));
        c.phase = 5;
        r.expired = true;
        assert!(draw_status(&c, 8300, Some(&r)).contains("does not prove responsibility"));
        c.challenges = 0;
        c.phase = 6;
        assert!(draw_status(&c, 8300, Some(&r)).contains("Current refund availability"));
        c.outcome_seed_block = 0;
        assert_eq!(draw_status(&c, 8300, None), "");
    }
}
