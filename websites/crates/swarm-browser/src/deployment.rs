use crate::{
    transport::{as_str, quantity, rpc},
    BrowserResult as Result,
};
use serde_json::{json, Value};
use swarm_core::{
    link_checks, selector, verify_guidelines, verify_link, verify_runtime, ModeratorProfile,
};
async fn view(
    profile: &ModeratorProfile,
    target: &str,
    signature: &str,
    args: &str,
    pin: &Value,
) -> Result<String> {
    let data = format!("{}{}", selector(signature), args);
    let raw = rpc(
        profile,
        "eth_call",
        json!([{ "to": target, "data": data }, pin]),
    )
    .await?;
    Ok(as_str(&raw)?.to_owned())
}

pub(crate) async fn verification(profile: &ModeratorProfile, _voter: &str) -> Result<String> {
    if quantity(as_str(&rpc(profile, "eth_chainId", json!([])).await?)?)?
        != profile.deployment.chain_id
    {
        return Err("DEPLOYMENT_CHAIN_MISMATCH");
    }
    let source = rpc(profile, "eth_getBlockByNumber", json!(["latest", false])).await?;
    let height = quantity(as_str(&source["number"])?)?;
    let _ = quantity(as_str(&source["timestamp"])?)?;
    let hash = as_str(&source["hash"])?;
    if hash.len() != 66
        || !hash.starts_with("0x")
        || !hash[2..].bytes().all(|c| c.is_ascii_hexdigit())
        || hash[2..].bytes().all(|c| c == b'0')
    {
        return Err("INVALID_BLOCK_HASH");
    }
    let pin = json!({ "blockHash": hash, "requireCanonical": true });
    let d = &profile.deployment;
    for contract in [&d.moderation, &d.stakes, &d.index, &d.token] {
        let code = rpc(profile, "eth_getCode", json!([contract.address, pin])).await?;
        verify_runtime(contract, as_str(&code)?).map_err(|_| "DEPLOYMENT_RUNTIME_MISMATCH")?;
    }
    for link in link_checks(d) {
        let raw = view(profile, &link.contract_address, &link.signature, "", &pin).await?;
        verify_link(&link, &raw).map_err(|_| "DEPLOYMENT_LINK_MISMATCH")?;
    }
    let version = view(
        profile,
        &d.moderation.address,
        "guidelinesVersion()",
        "",
        &pin,
    )
    .await?;
    let guideline_hash = view(profile, &d.moderation.address, "guidelinesHash()", "", &pin).await?;
    verify_guidelines(d, &version, &guideline_hash)
        .map_err(|_| "DEPLOYMENT_GUIDELINES_MISMATCH")?;
    // Re-read the source height and chain before publishing any evidence.
    let canonical = rpc(
        profile,
        "eth_getBlockByNumber",
        json!([source["number"], false]),
    )
    .await?;
    if canonical["number"] != source["number"]
        || canonical["hash"] != source["hash"]
        || canonical["timestamp"] != source["timestamp"]
    {
        return Err("SOURCE_BLOCK_CHANGED: refresh the evidence.");
    }
    if quantity(as_str(&rpc(profile, "eth_chainId", json!([])).await?)?)? != d.chain_id {
        return Err("SOURCE_CHAIN_CHANGED");
    }
    Ok(format!("Deployment verified at block {height}.\nFour runtime hashes and six contract links match.\nPinned guidelines version {} and hash match the contract.\nNext: open My work or select a case from the review queue. Load its review documents to read the pinned guidelines.", d.guidelines.version))
}
