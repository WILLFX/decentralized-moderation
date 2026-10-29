use super::*;
pub(super) fn download(name: &str, raw: &str) -> Result<()> {
    let parts = js_sys::Array::new();
    parts.push(&JsValue::from_str(raw));
    let opts = web_sys::BlobPropertyBag::new();
    opts.set_type("application/json");
    let blob = web_sys::Blob::new_with_str_sequence_and_options(&parts, &opts)
        .map_err(|_| "EXPORT_FAILED")?;
    let url = web_sys::Url::create_object_url_with_blob(&blob).map_err(|_| "EXPORT_FAILED")?;
    let anchor = doc()
        .create_element("a")
        .map_err(|_| "EXPORT_FAILED")?
        .dyn_into::<web_sys::HtmlAnchorElement>()
        .map_err(|_| "EXPORT_FAILED")?;
    anchor.set_href(&url);
    anchor.set_download(name);
    anchor.click();
    web_sys::Url::revoke_object_url(&url).map_err(|_| "EXPORT_FAILED")?;
    Ok(())
}
pub(super) async fn transfer(a: &Rc<RefCell<App>>, action: &str) -> Result<()> {
    let (p, who, epoch) = context(a)?;
    wallet::check(p.deployment.chain_id, &who).await?;
    active(a, epoch)?;
    if action == "savehistory" {
        let records = history::load_current(a, &p, &who)?;
        history::save(a, &p, &who, &records)?;
        text(
            "notice",
            "All public transaction records for this context saved.",
        );
        return Ok(());
    }
    if action == "exporthistory" {
        let records = history::load_current(a, &p, &who)?;
        let (page, _) = archive::page(&records, a.borrow().history_page);
        return download(
            "swarm-publisher-history-page.json",
            &archive::file(&page, &p, &who, "swarm-publisher-history-page")?,
        );
    }
    let id = "historyfile";
    let f = input(id)
        .files()
        .and_then(|f| f.get(0))
        .ok_or("FILE_REQUIRED")?;
    if f.size() > ledger::FILE_BYTES as f64 {
        return Err("IMPORT_SIZE_LIMIT");
    }
    let raw = JsFuture::from(f.text())
        .await
        .map_err(|_| "FILE_READ_FAILED")?
        .as_string()
        .ok_or("FILE_READ_FAILED")?;
    active(a, epoch)?;
    wallet::check(p.deployment.chain_id, &who).await?;
    active(a, epoch)?;
    let imported = parse_history_file(&raw, &p, &who)?;
    let records = merge_import(&history::load_current(a, &p, &who)?, imported)?;
    history::import_room(a, &p, &who, &records)?;
    history::save(a, &p, &who, &records)?;
    text("transaction","Public transaction history merged. Imported receipts require fresh verification before another matching send.");
    Ok(())
}
/// Equal calldata is not request identity: a later uncertain approval must survive import.
pub(super) fn merge_import(existing: &[Value], imported: Vec<Value>) -> Result<Vec<Value>> {
    let mut records = existing.to_vec();
    for mut record in imported {
        recovery::reset_import(&mut record);
        if let Some(old) = records.iter().find(|old| {
            recovery::identity(old) == recovery::identity(&record)
                || history::same_hex_bytes(&old["hash"], &record["hash"], Some(32))
        }) {
            history::merge(&[old.clone()], &[record])?;
            // An imported hint cannot replace locally checked status or nonce evidence.
        } else {
            records = history::merge(&records, &[record])?;
        }
    }
    Ok(records)
}
pub(super) fn parse_history_file(raw: &str, p: &ModeratorProfile, who: &str) -> Result<Vec<Value>> {
    if raw.len() > ledger::FILE_BYTES {
        return Err("HISTORY_SIZE_LIMIT");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "INVALID_HISTORY")?;
    if v.is_array() {
        return history::merge(&[], &history::validate(raw, p, who)?);
    }
    let envelope = v.as_object().ok_or("INVALID_HISTORY")?;
    if [
        Some("swarm-publisher-archive"),
        Some("swarm-publisher-history-page"),
    ]
    .contains(&v["format"].as_str())
    {
        if envelope.keys().any(|k| {
            ![
                "format",
                "version",
                "chainId",
                "contract",
                "publisher",
                "records",
            ]
            .contains(&k.as_str())
        }) || v["version"] != 1
            || v["chainId"] != p.deployment.chain_id
            || v["contract"] != p.deployment.moderation.address
            || v["publisher"] != who
        {
            return Err("INVALID_HISTORY_CONTEXT");
        }
        let raw = v["records"].to_string();
        return history::merge(
            &[],
            &history::validate_retained(&raw, p, who, ledger::ACTIVE_COUNT, ledger::FILE_BYTES)?,
        );
    }
    if envelope
        .keys()
        .any(|k| !["version", "records"].contains(&k.as_str()))
        || v["version"] != 1
    {
        return Err("INVALID_HISTORY");
    }
    let legacy = v["records"].as_array().ok_or("INVALID_HISTORY")?;
    if legacy.len() > 100 {
        return Err("HISTORY_SIZE_LIMIT");
    }
    let mut records = Vec::new();
    for r in legacy {
        let obj = r.as_object().ok_or("INVALID_HISTORY")?;
        if obj.keys().any(|k| {
            ![
                "action",
                "chainId",
                "contract",
                "publisher",
                "hash",
                "fee",
                "submission",
                "caseId",
            ]
            .contains(&k.as_str())
        }) {
            return Err("INVALID_HISTORY");
        }
        let chain = match &r["chainId"] {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            _ => return Err("INVALID_HISTORY_CONTEXT"),
        };
        if chain != p.deployment.chain_id.to_string()
            || !r["contract"]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(&p.deployment.moderation.address))
            || !r["publisher"]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(who))
        {
            return Err("INVALID_HISTORY_CONTEXT");
        }
        let hash = r["hash"]
            .as_str()
            .ok_or("INVALID_HISTORY")?
            .to_ascii_lowercase();
        if Uint256::hex(&hash).map_err(|_| "INVALID_HISTORY")? == Uint256::ZERO {
            return Err("INVALID_HISTORY");
        }
        let (action, to, data, intent, caseid) = match r["action"]
            .as_str()
            .ok_or("INVALID_HISTORY")?
        {
            "approveFee" => {
                if r.get("submission").is_some() || r.get("caseId").is_some() {
                    return Err("INVALID_HISTORY");
                }
                let n = fee(r["fee"].as_str().ok_or("INVALID_HISTORY")?)
                    .map_err(|_| "INVALID_HISTORY")?;
                (
                    "approve",
                    p.deployment.token.address.clone(),
                    encode_approve(&p.deployment.moderation.address, n)
                        .map_err(|_| "INVALID_HISTORY")?,
                    Value::Null,
                    String::new(),
                )
            }
            "submit" => {
                let sub = r["submission"].as_object().ok_or("INVALID_HISTORY")?;
                if sub
                    .keys()
                    .any(|k| !["contentHash", "metaHash", "topicKeys", "fee"].contains(&k.as_str()))
                {
                    return Err("INVALID_HISTORY");
                }
                let n = fee(r["submission"]["fee"].as_str().ok_or("INVALID_HISTORY")?)
                    .map_err(|_| "INVALID_HISTORY")?;
                if let Some(extra) = r.get("fee") {
                    if fee(extra.as_str().ok_or("INVALID_HISTORY")?)
                        .map_err(|_| "INVALID_HISTORY")?
                        != n
                    {
                        return Err("INVALID_HISTORY");
                    }
                }
                let content = r["submission"]["contentHash"]
                    .as_str()
                    .ok_or("INVALID_HISTORY")?
                    .to_ascii_lowercase();
                let meta = r["submission"]["metaHash"]
                    .as_str()
                    .ok_or("INVALID_HISTORY")?
                    .to_ascii_lowercase();
                let topics = r["submission"]["topicKeys"]
                    .as_array()
                    .ok_or("INVALID_HISTORY")?
                    .iter()
                    .map(|v| {
                        v.as_str()
                            .map(str::to_ascii_lowercase)
                            .ok_or("INVALID_HISTORY")
                    })
                    .collect::<Result<Vec<_>>>()?;
                let data =
                    swarm_core::publisher::encode_submission_parts(&content, &meta, &topics, n)
                        .map_err(|_| "INVALID_HISTORY")?;
                if let Some(id) = r.get("caseId") {
                    positive(id.as_str().ok_or("INVALID_HISTORY")?)?;
                }
                (
                    "submit",
                    p.deployment.moderation.address.clone(),
                    data,
                    json!({"contentHash":content,"metaHash":meta,"topics":topics,"fee":n.to_decimal()}),
                    String::new(),
                )
            }
            "withdrawRefund" => {
                if r.get("fee").is_some() || r.get("submission").is_some() {
                    return Err("INVALID_HISTORY");
                }
                let id = positive(r["caseId"].as_str().ok_or("INVALID_HISTORY")?)?;
                (
                    "refund",
                    p.deployment.moderation.address.clone(),
                    format!(
                        "{}{}",
                        swarm_core::selector("withdrawRefund(uint256)"),
                        id.abi()
                    ),
                    Value::Null,
                    id.to_decimal(),
                )
            }
            _ => return Err("INVALID_HISTORY"),
        };
        records.push(json!({"chainId":p.deployment.chain_id,"contract":p.deployment.moderation.address,"publisher":who,"action":action,"to":to,"data":data,"intent":intent,"caseId":caseid,"state":"unchecked","hash":hash,"requestId":format!("legacy-{}",hash)}));
    }
    let checked = history::validate(
        &serde_json::to_string(&records).map_err(|_| "INVALID_HISTORY")?,
        p,
        who,
    )?;
    history::merge(&[], &checked)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn imports_public_history_with_exact_calldata_and_unchecked_receipts() {
        let p = history::fixture_profile();
        let who = format!("0x{}", "55".repeat(20));
        let base = json!({"action":"approveFee","chainId":"100","contract":p.deployment.moderation.address,"publisher":who,"hash":format!("0x{}","66".repeat(32)),"fee":"1200"});
        let submit = json!({"action":"submit","chainId":"100","contract":p.deployment.moderation.address,"publisher":who,"hash":format!("0x{}","77".repeat(32)),"submission":{"contentHash":format!("0x{}","88".repeat(32)),"metaHash":format!("0x{}","99".repeat(32)),"topicKeys":[format!("0x{}","aa".repeat(32))],"fee":"1200"}});
        let refund = json!({"action":"withdrawRefund","chainId":"100","contract":p.deployment.moderation.address,"publisher":who,"hash":format!("0x{}","bb".repeat(32)),"caseId":"3"});
        let records = parse_history_file(
            &json!({"version":1,"records":[base,submit,refund]}).to_string(),
            &p,
            &who,
        )
        .unwrap();
        assert_eq!(records.len(), 3);
        assert!(records.iter().all(|r| r["state"] == "unchecked"));
        assert_eq!(records[0]["action"], "approve");
        assert_eq!(records[1]["action"], "submit");
        assert_eq!(records[2]["action"], "refund");
        assert_eq!(
            records[0]["data"],
            encode_approve(&p.deployment.moderation.address, fee("1200").unwrap()).unwrap()
        );
    }
    #[test]
    fn legacy_history_cannot_import_a_foreign_wallet() {
        let p = history::fixture_profile();
        let who = format!("0x{}", "55".repeat(20));
        let record = json!({"action":"approveFee","chainId":"100","contract":p.deployment.moderation.address,"publisher":format!("0x{}","99".repeat(20)),"hash":format!("0x{}","66".repeat(32)),"fee":"1200"});
        assert!(parse_history_file(
            &json!({"version":1,"records":[record]}).to_string(),
            &p,
            &who
        )
        .is_err());
    }
}
