//! Authority reads use the caller's existing canonical block pin.
use crate::{
    transport::{as_str, rpc},
    BrowserResult as Result,
};
use serde_json::{json, Value};
use swarm_core::{
    moderator::{CaseInfo, Uint256},
    versioning as core, ModeratorProfile,
};

async fn call(
    p: &ModeratorProfile,
    pin: &Value,
    target: &str,
    sig: &str,
    args: &str,
) -> Result<String> {
    Ok(as_str(
        &rpc(
            p,
            "eth_call",
            json!([{"to":target,
        "data":format!("{}{}",swarm_core::selector(sig),args)},pin]),
        )
        .await?,
    )?
    .into())
}
pub(crate) async fn verify(p: &ModeratorProfile, pin: &Value) -> Result<()> {
    for check in core::word_checks(&p.deployment).map_err(|e| e.0)? {
        let raw = call(p, pin, &check.contract, check.signature, &check.args).await?;
        core::verify_word(&check, &raw).map_err(|e| e.0)?;
    }
    Ok(())
}
pub(crate) async fn case(
    p: &ModeratorProfile,
    pin: &Value,
    id: Uint256,
    c: &CaseInfo,
) -> Result<Option<String>> {
    let Some(family) = &p.deployment.persistent else {
        return Ok(None);
    };
    let args = core::registration_args(&p.deployment.moderation.address, id).map_err(|e| e.0)?;
    let raw = call(
        p,
        pin,
        &family.authority.address,
        "registration(address,uint256)",
        &args,
    )
    .await?;
    core::verify_registration(&p.deployment, c, &raw).map_err(|e| e.0)
}
pub(crate) async fn active_address(p: &ModeratorProfile, pin: &Value) -> Result<Option<String>> {
    let Some(family) = &p.deployment.persistent else {
        return Ok(None);
    };
    let raw = call(p, pin, &family.authority.address, "active()", "").await?;
    Ok(Some(swarm_core::decode_address(&raw).map_err(|e| e.0)?))
}
pub(crate) async fn require_active(p: &ModeratorProfile, pin: &Value) -> Result<()> {
    p.purpose.check_publication("submit").map_err(|e| e.0)?;
    if let Some(active) = active_address(p, pin).await? {
        if !active.eq_ignore_ascii_case(&p.deployment.moderation.address) {
            return Err("VERSION_CLOSED_TO_SUBMISSIONS");
        }
    }
    Ok(())
}
