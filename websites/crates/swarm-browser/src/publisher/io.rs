use crate::{
    transport::{as_str, quantity, rpc},
    BrowserResult as Result,
};
use serde_json::{json, Value};
use swarm_core::moderator::{decode_case, decode_topics, CaseInfo, Uint256};
use swarm_core::publisher::Draft;
use swarm_core::{
    link_checks, selector, verify_guidelines, verify_link, verify_runtime, ModeratorProfile,
};
#[derive(Clone)]
pub(super) struct Context {
    pub source: Value,
    pub pin: Value,
}
pub(super) async fn view(
    p: &ModeratorProfile,
    c: &Context,
    to: &str,
    sig: &str,
    args: &str,
) -> Result<String> {
    Ok(as_str(
        &rpc(
            p,
            "eth_call",
            json!([{"to":to,"data":format!("{}{}",selector(sig),args)},c.pin]),
        )
        .await?,
    )?
    .into())
}
pub(super) async fn begin(p: &ModeratorProfile) -> Result<Context> {
    begin_at(p, "latest").await
}
async fn begin_at(p: &ModeratorProfile, tag: &str) -> Result<Context> {
    if quantity(as_str(&rpc(p, "eth_chainId", json!([])).await?)?)? != p.deployment.chain_id {
        return Err("CHAIN_MISMATCH");
    }
    let source = rpc(p, "eth_getBlockByNumber", json!([tag, false])).await?;
    let hash = as_str(&source["hash"])?;
    Uint256::hex(hash).map_err(|e| e.0)?;
    quantity(as_str(&source["number"])?)?;
    quantity(as_str(&source["timestamp"])?)?;
    if hash[2..].bytes().all(|b| b == b'0') {
        return Err("INVALID_BLOCK_HASH");
    }
    let c = Context {
        pin: json!({"blockHash":hash,"requireCanonical":true}),
        source,
    };
    let d = &p.deployment;
    for pin in [&d.moderation, &d.stakes, &d.index, &d.token] {
        verify_runtime(
            pin,
            as_str(&rpc(p, "eth_getCode", json!([pin.address, c.pin])).await?)?,
        )
        .map_err(|e| e.0)?;
    }
    for l in link_checks(d) {
        verify_link(
            &l,
            &view(p, &c, &l.contract_address, l.signature, "").await?,
        )
        .map_err(|e| e.0)?;
    }
    verify_guidelines(
        d,
        &view(p, &c, &d.moderation.address, "guidelinesVersion()", "").await?,
        &view(p, &c, &d.moderation.address, "guidelinesHash()", "").await?,
    )
    .map_err(|e| e.0)?;
    Ok(c)
}
pub(super) async fn finish(p: &ModeratorProfile, c: &Context) -> Result<()> {
    let b = rpc(
        p,
        "eth_getBlockByNumber",
        json!([c.source["number"], false]),
    )
    .await?;
    if ["number", "hash", "timestamp"]
        .iter()
        .any(|k| b[k] != c.source[k])
        || quantity(as_str(&rpc(p, "eth_chainId", json!([])).await?)?)? != p.deployment.chain_id
    {
        return Err("CONTEXT_CHANGED");
    }
    Ok(())
}
fn amount(s: &str) -> Result<Uint256> {
    Uint256::hex(s).map_err(|e| e.0)
}
pub(super) async fn funds(
    p: &ModeratorProfile,
    c: &Context,
    account: &str,
) -> Result<(Uint256, Uint256, Uint256)> {
    let arg = format!("{:0>64}", &account[2..]);
    let d = &p.deployment;
    Ok((
        amount(&view(p, c, &d.moderation.address, "feeMin()", "").await?)?,
        amount(&view(p, c, &d.token.address, "balanceOf(address)", &arg).await?)?,
        amount(
            &view(
                p,
                c,
                &d.token.address,
                "allowance(address,address)",
                &format!("{}{:0>64}", arg, &d.moderation.address[2..]),
            )
            .await?,
        )?,
    ))
}
pub(super) async fn case(
    p: &ModeratorProfile,
    c: &Context,
    id: Uint256,
) -> Result<(CaseInfo, Uint256, Vec<String>)> {
    let d = &p.deployment.moderation.address;
    Ok((
        decode_case(&view(p, c, d, "caseInfo(uint256)", &id.abi()).await?).map_err(|e| e.0)?,
        amount(&view(p, c, d, "refundOwed(uint256)", &id.abi()).await?)?,
        decode_topics(&view(p, c, d, "topicsOf(uint256)", &id.abi()).await?).map_err(|e| e.0)?,
    ))
}
pub(super) async fn upload(config: &Value, draft: &Draft) -> Result<()> {
    upload_bytes(config, &draft.bytes, &draft.meta_hash).await
}
pub(super) async fn upload_bytes(config: &Value, bytes: &[u8], reference: &str) -> Result<()> {
    let endpoint = config["endpoint"]
        .as_str()
        .ok_or("UPLOAD_CONFIG_REQUIRED")?;
    let url = swarm_core::review::resource_url(endpoint, "bytes", reference).map_err(|e| e.0)?;
    let post = url.rsplit_once('/').ok_or("INVALID_UPLOAD_ENDPOINT")?.0;
    let init = web_sys::RequestInit::new();
    init.set_method("POST");
    let data = js_sys::Uint8Array::from(bytes);
    init.set_body(data.as_ref());
    let h = web_sys::Headers::new().map_err(|_| "UPLOAD_FAILED")?;
    for (k, v) in [
        ("Content-Type", "application/octet-stream"),
        (
            "swarm-postage-batch-id",
            config["postageBatchId"].as_str().ok_or("INVALID_BATCH")?,
        ),
        ("swarm-encrypt", "false"),
        ("swarm-redundancy-level", "0"),
        ("swarm-act", "false"),
        ("swarm-deferred-upload", "false"),
    ] {
        h.set(k, v).map_err(|_| "UPLOAD_FAILED")?;
    }
    if let Some(auth) = config["authorization"].as_str() {
        h.set("Authorization", auth).map_err(|_| "UPLOAD_FAILED")?;
    }
    init.set_headers(h.as_ref());
    let (status, raw) = crate::transport::fetch_with_status(post, &init, 16 * 1024, 60000).await?;
    if status != 201 {
        return Err("UPLOAD_HTTP_ERROR");
    }
    let result: Value = serde_json::from_slice(&raw).map_err(|_| "INVALID_UPLOAD_RESPONSE")?;
    if result["reference"]
        .as_str()
        .map(|s| format!("0x{}", s.to_ascii_lowercase()))
        != Some(reference.to_owned())
    {
        return Err("UPLOAD_REFERENCE_MISMATCH");
    }
    let get = web_sys::RequestInit::new();
    let read_headers = web_sys::Headers::new().map_err(|_| "UPLOAD_FAILED")?;
    read_headers
        .set("Accept", "application/octet-stream")
        .map_err(|_| "UPLOAD_FAILED")?;
    read_headers
        .set("swarm-redundancy-level", "0")
        .map_err(|_| "UPLOAD_FAILED")?;
    if let Some(auth) = config["authorization"].as_str() {
        read_headers
            .set("Authorization", auth)
            .map_err(|_| "UPLOAD_FAILED")?;
    }
    get.set_headers(read_headers.as_ref());
    let (status, readback) = crate::transport::fetch_with_status(
        &url,
        &get,
        swarm_core::review::MAX_REVIEW_BYTES,
        60000,
    )
    .await?;
    if status != 200 || readback != bytes {
        return Err("UPLOAD_CONTENT_MISMATCH");
    }
    Ok(())
}
pub(super) async fn content_bytes(config: &Value, reference: &str) -> Result<Vec<u8>> {
    let endpoint = config["endpoint"]
        .as_str()
        .ok_or("UPLOAD_CONFIG_REQUIRED")?;
    let url = swarm_core::review::resource_url(endpoint, "bytes", reference).map_err(|e| e.0)?;
    let init = web_sys::RequestInit::new();
    let h = web_sys::Headers::new().map_err(|_| "RESOURCE_READ_FAILED")?;
    h.set("Accept", "application/octet-stream")
        .map_err(|_| "RESOURCE_READ_FAILED")?;
    h.set("swarm-redundancy-level", "0")
        .map_err(|_| "RESOURCE_READ_FAILED")?;
    if let Some(auth) = config["authorization"].as_str() {
        h.set("Authorization", auth)
            .map_err(|_| "RESOURCE_READ_FAILED")?;
    }
    init.set_headers(h.as_ref());
    crate::transport::fetch(&url, &init, swarm_core::review::MAX_REVIEW_BYTES).await
}
pub(super) async fn submission_receipt(
    p: &ModeratorProfile,
    receipt: &Value,
    intent: &Value,
    who: &str,
) -> Result<Uint256> {
    let block = rpc(
        p,
        "eth_getBlockByNumber",
        json!([receipt["blockNumber"], false]),
    )
    .await?;
    if block["hash"] != receipt["blockHash"] || block["number"] != receipt["blockNumber"] {
        return Err("RECEIPT_BLOCK_CHANGED");
    }
    let ctx = begin_at(p, as_str(&receipt["blockNumber"])?).await?;
    if ctx.source["hash"] != receipt["blockHash"] {
        return Err("RECEIPT_BLOCK_CHANGED");
    }
    let logs = receipt["logs"].as_array().ok_or("INVALID_RECEIPT")?;
    if logs.len() > 512 {
        return Err("RECEIPT_LOG_LIMIT");
    }
    let signature = swarm_core::keccak256_hex(b"Submitted(uint256,address,bytes32)");
    let mut found = None;
    for l in logs {
        if !l["address"]
            .as_str()
            .is_some_and(|s| s.eq_ignore_ascii_case(&p.deployment.moderation.address))
            || l["topics"][0] != signature
        {
            continue;
        }
        if found.is_some()
            || l["removed"] == true
            || l["topics"].as_array().map(Vec::len) != Some(3)
            || l["blockHash"] != receipt["blockHash"]
            || l["transactionHash"] != receipt["transactionHash"]
        {
            return Err("INVALID_SUBMITTED_EVENT");
        }
        let id = Uint256::hex(as_str(&l["topics"][1])?).map_err(|e| e.0)?;
        if id == Uint256::ZERO {
            return Err("INVALID_SUBMITTED_EVENT");
        }
        if !as_str(&l["topics"][2])?.eq_ignore_ascii_case(&format!("0x{:0>64}", &who[2..])) {
            return Err("SUBMISSION_MISMATCH");
        }
        let mut bytes = hex::decode(
            as_str(&intent["contentHash"])?
                .strip_prefix("0x")
                .ok_or("INVALID_INTENT")?,
        )
        .map_err(|_| "INVALID_INTENT")?;
        bytes.extend(
            hex::decode(
                as_str(&intent["metaHash"])?
                    .strip_prefix("0x")
                    .ok_or("INVALID_INTENT")?,
            )
            .map_err(|_| "INVALID_INTENT")?,
        );
        let claim = swarm_core::keccak256_hex(&bytes);
        if l["data"] != claim {
            return Err("SUBMISSION_MISMATCH");
        }
        let (c, _, topics) = case(p, &ctx, id).await?;
        let expected = intent["topics"].as_array().ok_or("INVALID_INTENT")?;
        if !(1..=5).contains(&expected.len()) || topics.len() != 5 {
            return Err("INVALID_INTENT");
        }
        if c.action_type != 0
            || c.target_case_id != Uint256::ZERO
            || !c.submitter.eq_ignore_ascii_case(who)
            || c.content_hash != intent["contentHash"]
            || c.meta_hash != intent["metaHash"]
            || c.claim_key != claim
            || c.pot != swarm_core::publisher::fee(as_str(&intent["fee"])?).map_err(|e| e.0)?
            || c.topic_count as usize != expected.len()
            || !expected
                .iter()
                .enumerate()
                .all(|(i, v)| v.as_str() == topics.get(i).map(String::as_str))
            || topics[expected.len()..]
                .iter()
                .any(|s| s[2..].bytes().any(|b| b != b'0'))
        {
            return Err("SUBMISSION_MISMATCH");
        }
        found = Some(id);
    }
    finish(p, &ctx).await?;
    found.ok_or("SUBMITTED_EVENT_MISSING")
}
