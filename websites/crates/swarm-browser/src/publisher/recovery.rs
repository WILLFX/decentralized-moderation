//! Receipt reconciliation. A replacement keeps the original journal identity.
//! Sender/nonce and mined block fields follow the Ethereum execution JSON-RPC API.
use super::*;
use crate::transport::quantity;

#[derive(Debug, PartialEq)]
pub(super) enum Outcome {
    Original,
    Replacement,
    Cancellation,
}
pub(super) fn identity(record: &Value) -> String {
    record["requestId"]
        .as_str()
        .map(|id| format!("request:{id}"))
        .unwrap_or_else(|| {
            format!(
                "hash:{}",
                record["hash"].as_str().unwrap_or("").to_ascii_lowercase()
            )
        })
}
fn same(a: &Value, b: &Value, bytes: usize) -> bool {
    history::same_hex_bytes(a, b, Some(bytes))
}
fn exact(record: &Value, tx: &Value) -> bool {
    same(&record["to"], &tx["to"], 20)
        && history::same_hex_bytes(&record["data"], &tx["input"], None)
}
pub(super) fn nonce(record: &Value, tx: &Value) -> Result<String> {
    if !same(&record["hash"], &tx["hash"], 32)
        || !same(&record["publisher"], &tx["from"], 20)
        || !exact(record, tx)
        || tx["value"] != "0x0"
    {
        return Err("ORIGINAL_TRANSACTION_MISMATCH");
    }
    if let Some(chain) = tx.get("chainId").filter(|v| !v.is_null()) {
        if quantity(as_str(chain)?)? != record["chainId"].as_u64().ok_or("INVALID_HISTORY")? {
            return Err("CHAIN_MISMATCH");
        }
    }
    let value = as_str(&tx["nonce"])?;
    let parsed = quantity(value)?;
    if let Some(n) = record.get("nonce").filter(|v| !v.is_null()) {
        if quantity(as_str(n)?)? != parsed {
            return Err("ORIGINAL_NONCE_CHANGED");
        }
    }
    Ok(format!("0x{parsed:x}"))
}
/// Pure decision over separately verified RPC facts. Imported nonce evidence is discarded.
pub(super) fn classify(record: &Value, tx: &Value, original: Option<&Value>) -> Result<Outcome> {
    if !same(&record["publisher"], &tx["from"], 20) || tx["value"] != "0x0" {
        return Err("RECOVERY_TRANSACTION_MISMATCH");
    }
    let candidate_nonce = as_str(&tx["nonce"])?;
    quantity(candidate_nonce)?;
    if same(&record["hash"], &tx["hash"], 32) {
        nonce(record, tx)?;
        return Ok(Outcome::Original);
    }
    if record["hash"].is_null() {
        if !["requesting", "unknown"].contains(&record["state"].as_str().unwrap_or("")) {
            return Err("NOT_UNCERTAIN_REQUEST");
        }
        let anchor = record
            .get("anchor")
            .filter(|v| !v.is_null())
            .ok_or("REQUEST_BOUNDARY_UNAVAILABLE")?;
        if quantity(as_str(&tx["blockNumber"])?)? <= quantity(as_str(&anchor["number"])?)? {
            return Err("TRANSACTION_PREDATES_REQUEST");
        }
        return if exact(record, tx) {
            Ok(Outcome::Original)
        } else {
            Err("HISTORY_TRANSACTION_MISMATCH")
        };
    }
    let original_nonce = if let Some(original) = original.filter(|v| !v.is_null()) {
        if !original["blockNumber"].is_null() || !original["blockHash"].is_null() {
            return Err("ORIGINAL_ALREADY_MINED");
        }
        nonce(record, original)?
    } else {
        record["nonce"]
            .as_str()
            .ok_or("ORIGINAL_NONCE_UNAVAILABLE")?
            .into()
    };
    if quantity(candidate_nonce)? != quantity(&original_nonce)? {
        return Err("REPLACEMENT_NONCE_MISMATCH");
    }
    if exact(record, tx) {
        return Ok(Outcome::Replacement);
    }
    if same(&tx["to"], &record["publisher"], 20) && tx["input"] == "0x" {
        return Ok(Outcome::Cancellation);
    }
    Err("REPLACEMENT_INTENT_MISMATCH")
}
pub(super) fn validate_fields(record: &Value) -> Result<()> {
    if let Some(n) = record.get("nonce").filter(|v| !v.is_null()) {
        quantity(as_str(n)?)?;
    }
    if let Some(a) = record.get("anchor").filter(|v| !v.is_null()) {
        if a.as_object()
            .ok_or("INVALID_HISTORY")?
            .keys()
            .any(|k| !["number", "hash"].contains(&k.as_str()))
            || !same(&a["hash"], &a["hash"], 32)
            || Uint256::hex(as_str(&a["hash"])?).map_err(|e| e.0)? == Uint256::ZERO
        {
            return Err("INVALID_HISTORY");
        }
        quantity(as_str(&a["number"])?)?;
    }
    if let Some(h) = record.get("candidateHash").filter(|v| !v.is_null()) {
        if !same(h, h, 32) || Uint256::hex(as_str(h)?).map_err(|e| e.0)? == Uint256::ZERO {
            return Err("INVALID_HISTORY");
        }
    }
    if let Some(r) = record.get("resolution").filter(|v| !v.is_null()) {
        if r.as_object()
            .ok_or("INVALID_HISTORY")?
            .keys()
            .any(|k| !["kind", "hash", "nonce", "blockNumber", "blockHash"].contains(&k.as_str()))
            || !["replacement", "cancellation"].contains(&r["kind"].as_str().unwrap_or(""))
            || !same(&r["hash"], &r["hash"], 32)
            || !same(&r["blockHash"], &r["blockHash"], 32)
            || record["hash"].is_null()
            || same(&record["hash"], &r["hash"], 32)
            || r["nonce"] != record["nonce"]
        {
            return Err("INVALID_HISTORY");
        }
        quantity(as_str(&r["nonce"])?)?;
        quantity(as_str(&r["blockNumber"])?)?;
    }
    if record["state"] == "cancelled" && record["resolution"]["kind"] != "cancellation" {
        return Err("INVALID_HISTORY");
    }
    Ok(())
}
/// Imported files provide hints, not authority to retire an uncertain request.
pub(super) fn reset_import(record: &mut Value) {
    if !record["caseEvidence"]["caseId"].is_null() {
        record["caseHint"] = record["caseEvidence"]["caseId"].clone();
    }
    record.as_object_mut().unwrap().remove("caseEvidence");
    if !record["resolution"]["hash"].is_null() {
        record["candidateHash"] = record["resolution"]["hash"].clone();
    }
    for key in ["nonce", "anchor", "resolution"] {
        record.as_object_mut().unwrap().remove(key);
    }
    record["state"] = json!(if record["hash"].is_null() {
        "unknown"
    } else {
        "unchecked"
    });
}
pub(super) async fn observe(p: &ModeratorProfile, record: &Value) -> Result<String> {
    if crate::transport::quantity(as_str(&rpc(p, "eth_chainId", json!([])).await?)?)?
        != p.deployment.chain_id
    {
        return Err("CHAIN_MISMATCH");
    }
    let tx = rpc(p, "eth_getTransactionByHash", json!([record["hash"]])).await?;
    nonce(record, &tx)
}
async fn canonical(p: &ModeratorProfile, receipt: &Value) -> Result<()> {
    if Uint256::hex(as_str(&receipt["blockHash"])?).map_err(|e| e.0)? == Uint256::ZERO {
        return Err("INVALID_RECEIPT");
    }
    let block = rpc(
        p,
        "eth_getBlockByNumber",
        json!([receipt["blockNumber"], false]),
    )
    .await?;
    if !same(&block["hash"], &receipt["blockHash"], 32) || block["number"] != receipt["blockNumber"]
    {
        return Err("RECEIPT_BLOCK_CHANGED");
    }
    Ok(())
}
/// Selecting a card never overrides ambiguity between hashless requests.
pub(super) fn target(
    records: &[Value],
    selected: Option<usize>,
    hash: &str,
    to: &Value,
    data: &Value,
) -> Result<usize> {
    if selected.is_some_and(|i| i >= records.len()) {
        return Err("SAVED_REQUEST_NOT_FOUND");
    }
    let known = records
        .iter()
        .enumerate()
        .filter(|(_, r)| {
            same(&r["hash"], &json!(hash), 32) || same(&r["resolution"]["hash"], &json!(hash), 32)
        })
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    if known.len() > 1 {
        return Err("HISTORY_AMBIGUOUS_TRANSACTION");
    }
    let known = known.first().copied();
    if selected.is_some() && known.is_some() && selected != known {
        return Err("RECEIPT_BELONGS_TO_ANOTHER_REQUEST");
    }
    let index = match selected.or(known) {
        Some(index) => index,
        None => {
            history::receipt_record_index(records, hash, to, data)?.ok_or("SELECT_SAVED_REQUEST")?
        }
    };
    if records[index]["hash"].is_null()
        && history::receipt_record_index(records, hash, to, data)? != Some(index)
    {
        return Err("HISTORY_TRANSACTION_MISMATCH");
    }
    Ok(index)
}
pub(super) async fn check(a: &Rc<RefCell<App>>) -> Result<Option<Uint256>> {
    let (p, who, epoch) = context(a)?;
    let hash = value("txhash");
    if Uint256::hex(&hash).map_err(|_| "INVALID_RECEIPT_HASH")? == Uint256::ZERO {
        return Err("INVALID_RECEIPT_HASH");
    }
    let c = io::begin(&p).await?;
    let mut records = history::load_current(a, &p, &who)?;
    let selected = a.borrow().recovery_target.clone();
    let selected = selected
        .as_ref()
        .map(|key| {
            records
                .iter()
                .position(|r| identity(r) == *key)
                .ok_or("SAVED_REQUEST_NOT_FOUND")
        })
        .transpose()?;
    let receipt = rpc(&p, "eth_getTransactionReceipt", json!([hash])).await?;
    let tx = rpc(&p, "eth_getTransactionByHash", json!([hash])).await?;
    if receipt.is_null() {
        let index = selected.or_else(|| {
            records
                .iter()
                .position(|r| same(&r["hash"], &json!(hash), 32))
        });
        if let Some(i) = index {
            if let Ok(n) = nonce(&records[i], &tx) {
                records[i]["nonce"] = json!(n);
            }
        }
        io::finish(&p, &c).await?;
        wallet::check(p.deployment.chain_id, &who).await?;
        active(a, epoch)?;
        history::save(a, &p, &who, &records)?;
        text("transaction","This hash is pending or unavailable to the selected RPC. No request was cleared. Keep the saved request; check wallet activity for its original, replacement or cancellation hash. Do not resend an uncertain request.");
        return Ok(None);
    }
    if !same(&receipt["transactionHash"], &json!(hash), 32)
        || !same(&receipt["from"], &json!(who), 20)
        || !same(&tx["hash"], &json!(hash), 32)
        || !same(&tx["from"], &json!(who), 20)
        || !same(&tx["to"], &receipt["to"], 20)
        || tx["value"] != "0x0"
        || tx["blockNumber"] != receipt["blockNumber"]
        || !same(&tx["blockHash"], &receipt["blockHash"], 32)
        || !["0x0", "0x1"].contains(&receipt["status"].as_str().unwrap_or(""))
    {
        return Err("INVALID_RECEIPT");
    }
    quantity(as_str(&receipt["blockNumber"])?)?;
    if let Some(chain) = tx.get("chainId").filter(|v| !v.is_null()) {
        if quantity(as_str(chain)?)? != p.deployment.chain_id {
            return Err("CHAIN_MISMATCH");
        }
    }
    canonical(&p, &receipt).await?;
    let index = target(&records, selected, &hash, &tx["to"], &tx["input"])?;
    let record = &records[index];
    if let Some(anchor) = record.get("anchor").filter(|v| !v.is_null()) {
        let block = rpc(&p, "eth_getBlockByNumber", json!([anchor["number"], false])).await?;
        if !same(&block["hash"], &anchor["hash"], 32) || block["number"] != anchor["number"] {
            return Err("REQUEST_BLOCK_CHANGED");
        }
    }
    let original = if !record["hash"].is_null() && !same(&record["hash"], &json!(hash), 32) {
        Some(rpc(&p, "eth_getTransactionByHash", json!([record["hash"]])).await?)
    } else {
        None
    };
    let outcome = classify(record, &tx, original.as_ref())?;
    let success = receipt["status"] == "0x1";
    let mut submission = None;
    let message = if outcome == Outcome::Cancellation && success {
        "A mined self-transfer consumed the original request's nonce. The saved request is cancelled; this does not approve a fee or submit a publication.".into()
    } else if !success {
        "The matching transaction was mined but reverted. The saved request is marked failed. Refresh the relevant case or allowance before preparing another transaction.".into()
    } else if record["action"] == "submit" {
        let id = io::submission_receipt(&p, &receipt, &record["intent"], &who).await?;
        submission = Some(id);
        format!("Submission confirmed and exact intent matched: Case {id}. This entered moderation; it does not yet mean the content is listed. Open it from My publications for current status.")
    } else if record["action"] == "approve" {
        "Approval confirmed. The recipient and exact amount match the saved request. Verify current allowance before submitting.".into()
    } else {
        "The matching refund transaction is confirmed. Read the case to verify the remaining refund balance.".into()
    };
    // The matched case/event read may await IO: recheck both anchors before mutating the journal.
    canonical(&p, &receipt).await?;
    io::finish(&p, &c).await?;
    wallet::check(p.deployment.chain_id, &who).await?;
    active(a, epoch)?;
    let record = &mut records[index];
    record["nonce"] = json!(format!("0x{:x}", quantity(as_str(&tx["nonce"])?)?));
    if outcome != Outcome::Original {
        record["resolution"] = json!({"kind":if outcome == Outcome::Cancellation {"cancellation"} else {"replacement"},"hash":hash,"nonce":record["nonce"],"blockNumber":receipt["blockNumber"],"blockHash":receipt["blockHash"]});
    } else if record["hash"].is_null() {
        record["hash"] = json!(hash);
    }
    record["state"] = json!(if !success {
        "failed"
    } else if outcome == Outcome::Cancellation {
        "cancelled"
    } else {
        "confirmed"
    });
    record.as_object_mut().unwrap().remove("caseEvidence");
    if let Some(id) = submission {
        record["caseEvidence"] = json!({"caseId":id.to_decimal(),"transactionHash":hash,"blockNumber":receipt["blockNumber"],"blockHash":receipt["blockHash"]});
    }
    let updated = record.clone();
    history::save_checked(a, &p, &who, &records, &updated)?;
    if a.borrow().recovery_target.as_deref() == Some(identity(&updated).as_str()) {
        text(
            "selected-request",
            &presentation::summary(&updated, p.display.as_ref()),
        );
    }
    if let Some(pending) = a.borrow_mut().pending_wallet.as_mut() {
        if identity(&pending.record) == identity(&updated) {
            pending.record = updated;
        }
    }
    text("transaction", &message);
    Ok(submission)
}
#[cfg(test)]
#[path = "recovery_tests.rs"]
mod tests;
