//! Canonical-block-pinned moderator evidence and authenticated review documents.
use crate::{
    transport::{as_str, fetch, quantity, rpc},
    BrowserResult as Result,
};
use serde_json::{json, Value};
use swarm_core::moderator::*;
use swarm_core::review::{parse_metadata, verify_guideline_bytes, Metadata, MAX_REVIEW_BYTES};
use swarm_core::{
    link_checks, selector, verify_guidelines, verify_link, verify_runtime, ModeratorProfile,
};
use web_sys::RequestInit;

#[derive(Clone, Debug)]
pub(crate) struct ModeratorFunds {
    pub stake_amount: Uint256,
    pub balance: Uint256,
    pub allowance: Uint256,
}
#[derive(Clone, Debug)]
pub(crate) struct ModeratorEvidence {
    pub source: SourceBlock,
    pub moderator: StakeInfo,
    pub funds: ModeratorFunds,
}
#[derive(Clone, Debug)]
pub(crate) struct CaseEvidence {
    pub snapshot: CaseSnapshot,
    pub topics: Vec<String>,
    pub eligibility: Eligibility,
    pub funds: ModeratorFunds,
}
pub(crate) struct CasePage {
    pub source: SourceBlock,
    pub cases: Vec<CaseEvidence>,
    pub next_cursor: Option<Uint256>,
}
pub(crate) struct VerifiedReview {
    pub metadata: Option<Metadata>,
    pub metadata_error: Option<&'static str>,
    pub guidelines_text: Option<String>,
    pub guidelines_error: Option<&'static str>,
}
struct Context {
    source: SourceBlock,
    tag: String,
    pin: Value,
}

fn source(value: &Value) -> Result<SourceBlock> {
    let hash = as_str(&value["hash"])?;
    if hash.len() != 66
        || !hash.starts_with("0x")
        || !hash[2..].bytes().all(|b| b.is_ascii_hexdigit())
        || hash[2..].bytes().all(|b| b == b'0')
    {
        return Err("INVALID_BLOCK_HASH");
    }
    Ok(SourceBlock {
        number: quantity(as_str(&value["number"])?)?,
        timestamp: quantity(as_str(&value["timestamp"])?)?,
        hash: hash.to_ascii_lowercase(),
    })
}
async fn chain(profile: &ModeratorProfile) -> Result<()> {
    if quantity(as_str(&rpc(profile, "eth_chainId", json!([])).await?)?)?
        != profile.deployment.chain_id
    {
        return Err("SOURCE_CHAIN_CHANGED");
    }
    Ok(())
}
async fn view(
    profile: &ModeratorProfile,
    ctx: &Context,
    target: &str,
    signature: &str,
    args: &str,
) -> Result<String> {
    Ok(as_str(
        &rpc(
            profile,
            "eth_call",
            json!([{"to":target,"data":format!("{}{}",selector(signature),args)},ctx.pin]),
        )
        .await?,
    )?
    .into())
}
async fn begin(profile: &ModeratorProfile, tag: &str) -> Result<Context> {
    if !["latest", "finalized"].contains(&tag) {
        return Err("INVALID_BLOCK_TAG");
    }
    chain(profile).await?;
    let block = source(&rpc(profile, "eth_getBlockByNumber", json!([tag, false])).await?)?;
    let ctx = Context {
        pin: json!({"blockHash":block.hash,"requireCanonical":true}),
        source: block,
        tag: tag.into(),
    };
    let d = &profile.deployment;
    for p in [&d.moderation, &d.stakes, &d.index, &d.token] {
        let code = rpc(profile, "eth_getCode", json!([p.address, ctx.pin])).await?;
        verify_runtime(p, as_str(&code)?).map_err(|e| e.0)?;
    }
    for link in link_checks(d) {
        verify_link(
            &link,
            &view(profile, &ctx, &link.contract_address, link.signature, "").await?,
        )
        .map_err(|e| e.0)?;
    }
    let version = view(
        profile,
        &ctx,
        &d.moderation.address,
        "guidelinesVersion()",
        "",
    )
    .await?;
    let hash = view(profile, &ctx, &d.moderation.address, "guidelinesHash()", "").await?;
    verify_guidelines(d, &version, &hash).map_err(|e| e.0)?;
    Ok(ctx)
}
async fn finish(profile: &ModeratorProfile, ctx: &Context) -> Result<()> {
    let canonical = source(
        &rpc(
            profile,
            "eth_getBlockByNumber",
            json!([format!("0x{:x}", ctx.source.number), false]),
        )
        .await?,
    )?;
    if canonical != ctx.source {
        return Err("SOURCE_BLOCK_CHANGED");
    }
    if ctx.tag == "finalized"
        && source(&rpc(profile, "eth_getBlockByNumber", json!(["finalized", false])).await?)?
            != ctx.source
    {
        return Err("FINALIZED_TAG_CHANGED");
    }
    chain(profile).await
}
fn address_word(voter: &str) -> Result<String> {
    if voter.len() != 42
        || !voter.starts_with("0x")
        || !voter[2..].bytes().all(|b| b.is_ascii_hexdigit())
        || voter[2..].bytes().all(|b| b == b'0')
    {
        return Err("INVALID_ACCOUNT");
    }
    Ok(format!("{:0>64}", &voter[2..]))
}
async fn moderator_at(
    profile: &ModeratorProfile,
    ctx: &Context,
    voter: &str,
) -> Result<(StakeInfo, ModeratorFunds)> {
    let addr = address_word(voter)?;
    let d = &profile.deployment;
    let moderator =
        decode_stake(&view(profile, ctx, &d.stakes.address, "infoOf(address)", &addr).await?)
            .map_err(|e| e.0)?;
    let stake_amount =
        Uint256::hex(&view(profile, ctx, &d.stakes.address, "stakeAmount()", "").await?)
            .map_err(|e| e.0)?;
    let balance =
        Uint256::hex(&view(profile, ctx, &d.token.address, "balanceOf(address)", &addr).await?)
            .map_err(|e| e.0)?;
    let allowance = Uint256::hex(
        &view(
            profile,
            ctx,
            &d.token.address,
            "allowance(address,address)",
            &format!("{addr}{}", address_word(&d.stakes.address)?),
        )
        .await?,
    )
    .map_err(|e| e.0)?;
    Ok((
        moderator,
        ModeratorFunds {
            stake_amount,
            balance,
            allowance,
        },
    ))
}
async fn case_at(
    profile: &ModeratorProfile,
    ctx: &Context,
    voter: &str,
    id: Uint256,
    moderator: StakeInfo,
    funds: ModeratorFunds,
) -> Result<CaseEvidence> {
    if id == Uint256::ZERO {
        return Err("INVALID_CASE_ID");
    }
    let target = &profile.deployment.moderation.address;
    let args = id.abi();
    let case = decode_case(&view(profile, ctx, target, "caseInfo(uint256)", &args).await?)
        .map_err(|e| e.0)?;
    let vote = decode_vote(
        &view(
            profile,
            ctx,
            target,
            "voteOf(uint256,address)",
            &format!("{args}{}", address_word(voter)?),
        )
        .await?,
    )
    .map_err(|e| e.0)?;
    let schedule =
        decode_schedule(&view(profile, ctx, target, "pairScheduleOf(uint256)", &args).await?)
            .map_err(|e| e.0)?;
    let all_topics = decode_topics(&view(profile, ctx, target, "topicsOf(uint256)", &args).await?)
        .map_err(|e| e.0)?;
    if !(1..=5).contains(&case.topic_count) {
        return Err("INVALID_CASE_TOPICS");
    }
    let topics = all_topics[..case.topic_count as usize].to_vec();
    let refund_owed =
        Uint256::hex(&view(profile, ctx, target, "refundOwed(uint256)", &args).await?)
            .map_err(|e| e.0)?;
    let snapshot = CaseSnapshot {
        case_id: id,
        source: ctx.source.clone(),
        case,
        vote,
        schedule,
        moderator,
        refund_owed,
    };
    let eligibility = if committee_at(&snapshot).is_none() {
        Eligibility::NotOpen
    } else {
        match view(
            profile,
            ctx,
            target,
            "isEligible(uint256,address)",
            &format!("{args}{}", address_word(voter)?),
        )
        .await
        {
            Ok(raw) => {
                if decode_bool(&raw).map_err(|e| e.0)? {
                    Eligibility::Selected
                } else {
                    Eligibility::NotSelected
                }
            }
            Err("SEED_UNAVAILABLE") => Eligibility::SeedUnavailable,
            Err(e) => return Err(e),
        }
    };
    Ok(CaseEvidence {
        snapshot,
        topics,
        eligibility,
        funds,
    })
}
pub(crate) async fn read_case(
    profile: &ModeratorProfile,
    voter: &str,
    id: Uint256,
    tag: &str,
) -> Result<CaseEvidence> {
    address_word(voter)?;
    let ctx = begin(profile, tag).await?;
    let (m, f) = moderator_at(profile, &ctx, voter).await?;
    let result = case_at(profile, &ctx, voter, id, m, f).await?;
    finish(profile, &ctx).await?;
    Ok(result)
}
pub(crate) async fn read_moderator(
    profile: &ModeratorProfile,
    voter: &str,
) -> Result<ModeratorEvidence> {
    address_word(voter)?;
    let ctx = begin(profile, "latest").await?;
    let (moderator, funds) = moderator_at(profile, &ctx, voter).await?;
    finish(profile, &ctx).await?;
    Ok(ModeratorEvidence {
        source: ctx.source,
        moderator,
        funds,
    })
}
fn increment(mut n: Uint256) -> Result<Uint256> {
    for byte in n.0.iter_mut().rev() {
        let (v, carry) = byte.overflowing_add(1);
        *byte = v;
        if !carry {
            return Ok(n);
        }
    }
    Err("CASE_CURSOR_OVERFLOW")
}
pub(crate) async fn list_cases(
    profile: &ModeratorProfile,
    voter: &str,
    cursor: Uint256,
    limit: u8,
) -> Result<CasePage> {
    if cursor == Uint256::ZERO || !(1..=50).contains(&limit) {
        return Err("INVALID_CASE_PAGE");
    }
    address_word(voter)?;
    let ctx = begin(profile, "latest").await?;
    let (m, f) = moderator_at(profile, &ctx, voter).await?;
    let next = Uint256::hex(
        &view(
            profile,
            &ctx,
            &profile.deployment.moderation.address,
            "nextCaseId()",
            "",
        )
        .await?,
    )
    .map_err(|e| e.0)?;
    let mut id = cursor;
    let mut cases = Vec::new();
    while id < next && cases.len() < limit as usize {
        cases.push(case_at(profile, &ctx, voter, id, m.clone(), f.clone()).await?);
        id = increment(id)?;
    }
    finish(profile, &ctx).await?;
    Ok(CasePage {
        source: ctx.source,
        cases,
        next_cursor: if id < next { Some(id) } else { None },
    })
}
/// Construct a link only. The UI must open it separately with noopener/noreferrer;
/// downloaded content is never inserted into the application's DOM.
pub(crate) fn content_url(profile: &ModeratorProfile, hash: &str) -> Result<String> {
    let origin = web_sys::window()
        .ok_or("BROWSER_REQUIRED")?
        .location()
        .origin()
        .map_err(|_| "BROWSER_REQUIRED")?;
    swarm_core::review::separate_content_url(
        &profile.gateway_url,
        &profile.content_path,
        hash,
        &origin,
    )
    .map_err(|e| e.0)
}
fn resource_url(profile: &ModeratorProfile, path: &str, hash: &str) -> Result<String> {
    swarm_core::review::resource_url(&profile.gateway_url, path, hash).map_err(|e| e.0)
}
pub(crate) async fn load_review(
    profile: &ModeratorProfile,
    meta_hash: &str,
    topics: &[String],
) -> Result<VerifiedReview> {
    let init = RequestInit::new();
    init.set_method("GET");
    let guideline_result = async {
        let bytes = fetch(&profile.guidelines_url, &init, MAX_REVIEW_BYTES).await?;
        verify_guideline_bytes(&bytes, &profile.deployment.guidelines.hash).map_err(|e| e.0)
    }
    .await;
    let metadata_result = async {
        let bytes = fetch(
            &resource_url(profile, &profile.metadata_path, meta_hash)?,
            &init,
            MAX_REVIEW_BYTES,
        )
        .await?;
        parse_metadata(&bytes, meta_hash, topics).map_err(|e| e.0)
    }
    .await;
    // Preserve the existing review policy: invalid metadata blocks approving a
    // listing, but does not prevent a moderator from reviewing and rejecting it.
    let (metadata, metadata_error) = match metadata_result {
        Ok(v) => (Some(v), None),
        Err(e) => (None, Some(e)),
    };
    let (guidelines_text, guidelines_error) = match guideline_result {
        Ok(v) => (Some(v), None),
        Err(e) => (None, Some(e)),
    };
    Ok(VerifiedReview {
        metadata,
        metadata_error,
        guidelines_text,
        guidelines_error,
    })
}
