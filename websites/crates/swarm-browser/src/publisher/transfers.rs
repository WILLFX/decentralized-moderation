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
    if action == "exportdraft" {
        let d = a.borrow().draft.clone().ok_or("DRAFT_REQUIRED")?;
        let metadata: Value = serde_json::from_slice(&d.bytes).map_err(|_| "INVALID_DRAFT")?;
        return download("swarm-publication-draft.json",&json!({"format":"swarm-publication-draft","version":1,"chainId":p.deployment.chain_id,"contract":p.deployment.moderation.address,"publisher":who,"contentReference":d.content_hash,"metaHash":d.meta_hash,"metadata":metadata}).to_string());
    }
    if action == "exporthistory" {
        let records = history::load_current(a, &p, &who)?;
        return download(
            "swarm-publisher-public-history.json",
            &serde_json::to_string(&records).map_err(|_| "EXPORT_FAILED")?,
        );
    }
    let id = if action == "importdraft" {
        "draftfile"
    } else {
        "historyfile"
    };
    let f = input(id)
        .files()
        .and_then(|f| f.get(0))
        .ok_or("FILE_REQUIRED")?;
    if f.size() > 512.0 * 1024.0 {
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
    if action == "importdraft" {
        let d = parse_draft_file(&raw, &p, &who)?;
        invalidate(a);
        input("reference").set_value(&d.content_hash);
        let metadata: Value = serde_json::from_slice(&d.bytes).map_err(|_| "INVALID_DRAFT")?;
        fill_authoring(&metadata);
        text(
            "preview",
            &format!(
                "Imported draft {}. Upload and guideline acknowledgements must be repeated.\n{}",
                d.meta_hash,
                String::from_utf8_lossy(&d.bytes)
            ),
        );
        a.borrow_mut().draft = Some(d);
    } else {
        let mut imported = parse_history_file(&raw, &p, &who)?;
        let mut records = history::load_current(a, &p, &who)?;
        for record in &mut imported {
            record["state"] = json!(if record["hash"].is_null() {
                "unknown"
            } else {
                "unchecked"
            });
            if !records.iter().any(|old| {
                (!record["hash"].is_null() && old["hash"] == record["hash"])
                    || (record["hash"].is_null()
                        && old["data"] == record["data"]
                        && old["to"] == record["to"])
            }) {
                records.push(record.clone());
            }
        }
        if records.len() > 100 {
            return Err("HISTORY_SIZE_LIMIT");
        }
        history::save(a, &p, &who, &records)?;
        text("transaction","Public transaction history merged. Imported receipts require fresh verification before another matching send.");
    }
    Ok(())
}
/// Accept a metadata authoring file as well as a context-bound draft envelope.
pub(super) fn parse_draft_file(raw: &str, p: &ModeratorProfile, who: &str) -> Result<Draft> {
    if raw.len() > 512 * 1024 {
        return Err("IMPORT_SIZE_LIMIT");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "INVALID_DRAFT")?;
    let obj = v.as_object().ok_or("INVALID_DRAFT")?;
    let legacy = !obj.contains_key("format");
    let allowed = if legacy {
        vec!["version", "contentReference", "metadata"]
    } else {
        vec![
            "format",
            "version",
            "chainId",
            "contract",
            "publisher",
            "contentReference",
            "metaHash",
            "metadata",
        ]
    };
    if obj.keys().any(|k| !allowed.contains(&k.as_str())) || v["version"] != 1 {
        return Err("INVALID_DRAFT");
    }
    if !legacy
        && (v["format"] != "swarm-publication-draft"
            || v["chainId"] != p.deployment.chain_id
            || v["contract"] != p.deployment.moderation.address
            || v["publisher"] != who)
    {
        return Err("DRAFT_CONTEXT_MISMATCH");
    }
    let draft = create_draft(
        v["contentReference"].as_str().ok_or("INVALID_DRAFT")?,
        &v["metadata"],
    )
    .map_err(|e| e.0)?;
    if !legacy && draft.meta_hash != v["metaHash"] {
        return Err("INVALID_DRAFT");
    }
    Ok(draft)
}
pub(super) fn parse_history_file(raw: &str, p: &ModeratorProfile, who: &str) -> Result<Vec<Value>> {
    if raw.len() > 256 * 1024 {
        return Err("HISTORY_SIZE_LIMIT");
    }
    let v: Value = serde_json::from_str(raw).map_err(|_| "INVALID_HISTORY")?;
    if v.is_array() {
        return history::merge(&[], &history::validate(raw, p, who)?);
    }
    let envelope = v.as_object().ok_or("INVALID_HISTORY")?;
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
    fn imports_authoring_file_without_credentials() {
        let p = history::fixture_profile();
        let who = format!("0x{}", "55".repeat(20));
        let legacy = json!({"version":1,"contentReference":format!("0x{}","66".repeat(32)),"metadata":{"schemaVersion":1,"type":"article","title":"Cells","topics":["biology"],"contentType":"text/plain"}});
        let draft = parse_draft_file(&legacy.to_string(), &p, &who).unwrap();
        assert_eq!(draft.topic_keys.len(), 1);
        let mut unsafe_file = legacy;
        unsafe_file["authorization"] = json!("must not export");
        assert!(parse_draft_file(&unsafe_file.to_string(), &p, &who).is_err());
    }
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
