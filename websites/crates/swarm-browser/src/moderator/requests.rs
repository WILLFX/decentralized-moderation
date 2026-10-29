//! Write-ahead public send intents. Never persist calldata, vote choices or salts.
//! All writers run under the moderator Web Lock held by controls::coordinated.
use crate::{
    transport::{quantity, rpc},
    BrowserResult as Result,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use swarm_core::ModeratorProfile;

const LIMIT: usize = 2000;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    version: u8,
    pub chain: u64,
    pub contract: String,
    pub voter: String,
    pub to: String,
    pub action: String,
    pub case_id: Option<String>,
    digest: String,
    pub nonce: u64,
    pub after_block: u64,
    pub hash: Option<String>,
    pub settled: bool,
    pub resolved_hash: Option<String>,
    outcome: Option<String>,
    rejected: bool,
    #[serde(default)]
    not_sent: bool,
}
fn hex(value: &str, bytes: usize) -> bool {
    value.len() == 2 + bytes * 2
        && value.starts_with("0x")
        && value[2..].bytes().all(|b| b.is_ascii_hexdigit())
}
fn digest(data: &str) -> Result<String> {
    if !data.starts_with("0x") || data.len() < 10 {
        return Err("REQUEST_INVALID");
    }
    Ok(swarm_core::keccak256_hex(
        &hex::decode(&data[2..]).map_err(|_| "REQUEST_INVALID")?,
    ))
}
impl Request {
    fn validate(&self, p: &ModeratorProfile, voter: &str) -> Result<()> {
        if self.version != 1
            || self.chain != p.deployment.chain_id
            || !self
                .contract
                .eq_ignore_ascii_case(&p.deployment.moderation.address)
            || !self.voter.eq_ignore_ascii_case(voter)
            || !hex(&self.voter, 20)
            || !hex(&self.to, 20)
            || !hex(&self.digest, 32)
            || self.action.is_empty()
            || self.action.len() > 64
            || self
                .case_id
                .as_ref()
                .is_some_and(|v| swarm_core::moderator::Uint256::decimal(v).is_err())
            || self.hash.as_ref().is_some_and(|v| !hex(v, 32))
            || self.resolved_hash.as_ref().is_some_and(|v| !hex(v, 32))
            || (!self.settled && (self.resolved_hash.is_some() || self.outcome.is_some()))
            || (self.settled
                && !self.rejected
                && !self.not_sent
                && !matches!(
                    self.outcome.as_deref(),
                    Some("confirmed" | "reverted" | "cancelled")
                ))
            || (self.settled && self.resolved_hash.is_none() && !self.rejected && !self.not_sent)
            || self.rejected && self.not_sent
            || ((self.rejected || self.not_sent)
                && (!self.settled
                    || self.hash.is_some()
                    || self.resolved_hash.is_some()
                    || self.outcome.is_some()))
        {
            return Err("REQUEST_HISTORY_INVALID");
        }
        Ok(())
    }
    fn finish_without_send(&mut self, rejected: bool) -> Result<()> {
        if self.settled || self.hash.is_some() || self.resolved_hash.is_some() {
            return Err("REQUEST_HISTORY_CONFLICT");
        }
        self.rejected = rejected;
        self.not_sent = !rejected;
        self.settled = true;
        Ok(())
    }
    fn matches(&self, tx: &Value, hash: &str, block: u64, anchor: &str) -> Result<()> {
        let eq = |field: &str, expected: &str| {
            tx[field]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(expected))
        };
        if !eq("hash", hash)
            || !eq("from", &self.voter)
            || !eq("to", &self.to)
            || !eq("blockHash", anchor)
            || quantity(
                tx["blockNumber"]
                    .as_str()
                    .ok_or("REQUEST_TRANSACTION_MISMATCH")?,
            )? != block
            || quantity(tx["value"].as_str().ok_or("REQUEST_TRANSACTION_MISMATCH")?)? != 0
            || digest(tx["input"].as_str().ok_or("REQUEST_TRANSACTION_MISMATCH")?)? != self.digest
            || block <= self.after_block
            || self
                .hash
                .as_ref()
                .is_some_and(|v| !v.eq_ignore_ascii_case(hash))
            || self.hash.is_none()
                && quantity(tx["nonce"].as_str().ok_or("REQUEST_TRANSACTION_MISMATCH")?)?
                    != self.nonce
        {
            return Err("REQUEST_TRANSACTION_MISMATCH");
        }
        Ok(())
    }
    fn exact_intent(&self, tx: &Value, hash: &str) -> bool {
        let eq = |field: &str, expected: &str| {
            tx[field]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(expected))
        };
        eq("hash", hash)
            && eq("from", &self.voter)
            && eq("to", &self.to)
            && tx["value"].as_str().and_then(|v| quantity(v).ok()) == Some(0)
            && tx["input"].as_str().and_then(|v| digest(v).ok()).as_deref()
                == Some(self.digest.as_str())
    }
    /// Replacement proof keeps the wallet-returned hash as the original identity.
    /// A hashless request can only use its locally observed nonce and start block.
    fn replacement(
        &self,
        original: Option<&Value>,
        tx: &Value,
        hash: &str,
        block: u64,
        anchor: &str,
    ) -> Result<bool> {
        let nonce = match &self.hash {
            Some(saved) => {
                let old = original
                    .filter(|v| self.exact_intent(v, saved))
                    .ok_or("REQUEST_ORIGINAL_UNAVAILABLE")?;
                quantity(
                    old["nonce"]
                        .as_str()
                        .ok_or("REQUEST_TRANSACTION_MISMATCH")?,
                )?
            }
            None => self.nonce,
        };
        let eq = |field: &str, expected: &str| {
            tx[field]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case(expected))
        };
        if !eq("hash", hash)
            || !eq("from", &self.voter)
            || !eq("blockHash", anchor)
            || quantity(
                tx["blockNumber"]
                    .as_str()
                    .ok_or("REQUEST_TRANSACTION_MISMATCH")?,
            )? != block
            || quantity(tx["nonce"].as_str().ok_or("REQUEST_TRANSACTION_MISMATCH")?)? != nonce
            || block <= self.after_block
        {
            return Err("REQUEST_TRANSACTION_MISMATCH");
        }
        let cancelled = eq("to", &self.voter)
            && tx["input"].as_str() == Some("0x")
            && tx["value"].as_str().and_then(|v| quantity(v).ok()) == Some(0);
        if !cancelled && !self.exact_intent(tx, hash) {
            return Err("REQUEST_TRANSACTION_MISMATCH");
        }
        Ok(cancelled)
    }
}
fn storage() -> Result<web_sys::Storage> {
    web_sys::window()
        .ok_or("REQUEST_STORAGE_FAILED")?
        .local_storage()
        .map_err(|_| "REQUEST_STORAGE_FAILED")?
        .ok_or("REQUEST_STORAGE_FAILED")
}
fn key(p: &ModeratorProfile, voter: &str) -> String {
    format!(
        "moderator-requests-v1:{}:{}:{}",
        p.deployment.chain_id,
        p.deployment.moderation.address.to_ascii_lowercase(),
        voter.to_ascii_lowercase()
    )
}
pub(crate) fn load(p: &ModeratorProfile, voter: &str) -> Result<Vec<Request>> {
    let Some(raw) = storage()?
        .get_item(&key(p, voter))
        .map_err(|_| "REQUEST_STORAGE_FAILED")?
    else {
        return Ok(vec![]);
    };
    parse(&raw, p, voter)
}
fn parse(raw: &str, p: &ModeratorProfile, voter: &str) -> Result<Vec<Request>> {
    if raw.len() > 2 * 1024 * 1024 {
        return Err("REQUEST_HISTORY_INVALID");
    }
    let rows: Vec<Request> = serde_json::from_str(raw).map_err(|_| "REQUEST_HISTORY_INVALID")?;
    if rows.len() > LIMIT || rows.iter().filter(|r| !r.settled).count() > 1 {
        return Err("REQUEST_HISTORY_INVALID");
    }
    for row in &rows {
        row.validate(p, voter)?;
    }
    Ok(rows)
}
fn save(p: &ModeratorProfile, voter: &str, rows: &[Request]) -> Result<()> {
    let raw = serde_json::to_string(rows).map_err(|_| "REQUEST_STORAGE_FAILED")?;
    parse(&raw, p, voter)?;
    let s = storage()?;
    let k = key(p, voter);
    s.set_item(&k, &raw).map_err(|_| "REQUEST_STORAGE_FAILED")?;
    if s.get_item(&k)
        .map_err(|_| "REQUEST_STORAGE_FAILED")?
        .as_deref()
        != Some(&raw)
    {
        return Err("REQUEST_STORAGE_FAILED");
    }
    Ok(())
}
pub(crate) fn ensure_clear(p: &ModeratorProfile, voter: &str) -> Result<()> {
    if load(p, voter)?.iter().any(|r| !r.settled) {
        return Err("REQUEST_UNRESOLVED");
    }
    Ok(())
}
pub(crate) async fn boundary(p: &ModeratorProfile, voter: &str) -> Result<(u64, u64)> {
    ensure_clear(p, voter)?;
    let block = rpc(p, "eth_getBlockByNumber", json!(["latest", false])).await?;
    let nonce = rpc(p, "eth_getTransactionCount", json!([voter, "pending"])).await?;
    let chain = rpc(p, "eth_chainId", json!([])).await?;
    if quantity(chain.as_str().ok_or("INVALID_RPC_RESULT")?)? != p.deployment.chain_id {
        return Err("SOURCE_CHAIN_CHANGED");
    }
    Ok((
        quantity(block["number"].as_str().ok_or("INVALID_RPC_RESULT")?)?,
        quantity(nonce.as_str().ok_or("INVALID_RPC_RESULT")?)?,
    ))
}
pub(crate) fn begin(
    p: &ModeratorProfile,
    voter: &str,
    to: &str,
    data: &str,
    action: &str,
    case_id: Option<String>,
    boundary: (u64, u64),
) -> Result<usize> {
    ensure_clear(p, voter)?;
    let mut rows = load(p, voter)?;
    if rows.len() >= LIMIT {
        return Err("REQUEST_HISTORY_FULL");
    }
    let index = rows.len();
    rows.push(Request {
        version: 1,
        chain: p.deployment.chain_id,
        contract: p.deployment.moderation.address.to_ascii_lowercase(),
        voter: voter.to_ascii_lowercase(),
        to: to.to_ascii_lowercase(),
        action: action.into(),
        case_id,
        digest: digest(data)?,
        nonce: boundary.1,
        after_block: boundary.0,
        hash: None,
        settled: false,
        resolved_hash: None,
        outcome: None,
        rejected: false,
        not_sent: false,
    });
    save(p, voter, &rows)?;
    Ok(index)
}
fn without_send(p: &ModeratorProfile, voter: &str, index: usize, rejected: bool) -> Result<()> {
    let mut rows = load(p, voter)?;
    rows.get_mut(index)
        .ok_or("REQUEST_HISTORY_CONFLICT")?
        .finish_without_send(rejected)?;
    save(p, voter, &rows)
}
pub(crate) fn rejected(p: &ModeratorProfile, voter: &str, index: usize) -> Result<()> {
    without_send(p, voter, index, true)
}
/// Only the caller's still-running, pre-disclosure control flow can prove this.
/// A page reload, missing receipt or latest chain absence must never call it.
pub(crate) fn not_sent(p: &ModeratorProfile, voter: &str, index: usize) -> Result<()> {
    without_send(p, voter, index, false)
}
pub(crate) fn sent(p: &ModeratorProfile, voter: &str, index: usize, hash: &str) -> Result<()> {
    let mut rows = load(p, voter)?;
    let row = rows
        .get_mut(index)
        .filter(|r| !r.settled && r.hash.is_none())
        .ok_or("REQUEST_HISTORY_CONFLICT")?;
    row.hash = Some(hash.into());
    save(p, voter, &rows)
}
/// A hash supplied by the user is a hint, never authority to clear an unknown send.
pub(crate) async fn reconcile(
    p: &ModeratorProfile,
    hash: &str,
    receipt: &Value,
) -> Result<Option<&'static str>> {
    let tx = rpc(p, "eth_getTransactionByHash", json!([hash])).await?;
    let voter = tx["from"].as_str().ok_or("INVALID_RPC_RESULT")?;
    if !hex(voter, 20) {
        return Err("INVALID_RPC_RESULT");
    }
    let mut rows = load(p, voter)?;
    let Some(index) = rows.iter().position(|r| !r.settled) else {
        return Ok(rows
            .iter()
            .find(|r| {
                r.resolved_hash.as_deref() == Some(hash)
                    && r.outcome.as_deref() == Some("cancelled")
            })
            .map(|_| {
                "Same-nonce cancellation verified. Refresh current evidence before another action."
            }));
    };
    let block = quantity(receipt["blockNumber"].as_str().ok_or("INVALID_RECEIPT")?)?;
    let anchor = receipt["blockHash"].as_str().ok_or("INVALID_RECEIPT")?;
    let cancelled = if rows[index]
        .hash
        .as_ref()
        .is_some_and(|v| v.eq_ignore_ascii_case(hash))
    {
        rows[index].matches(&tx, hash, block, anchor)?;
        false
    } else {
        let original = match &rows[index].hash {
            Some(saved) => Some(rpc(p, "eth_getTransactionByHash", json!([saved])).await?),
            None => None,
        };
        rows[index].replacement(original.as_ref(), &tx, hash, block, anchor)?
    };
    let finalized = rpc(p, "eth_getBlockByNumber", json!(["finalized", false])).await?;
    let final_height = quantity(
        finalized["number"]
            .as_str()
            .ok_or("FINALITY_NOT_AVAILABLE")?,
    )?;
    // Recheck the mined anchor after the finality read and before writing any resolution.
    let canonical = rpc(
        p,
        "eth_getBlockByNumber",
        json!([format!("0x{block:x}"), false]),
    )
    .await?;
    let chain = rpc(p, "eth_chainId", json!([])).await?;
    crate::workflow::canonical_receipt_status(
        receipt,
        hash,
        &canonical,
        p.deployment.chain_id,
        &chain,
    )?;
    if final_height < block {
        return Err("REQUEST_WAIT_FINALITY");
    }
    rows[index].resolved_hash = Some(hash.into());
    rows[index].outcome = Some(
        if cancelled {
            "cancelled"
        } else if receipt["status"] == "0x1" {
            "confirmed"
        } else {
            "reverted"
        }
        .into(),
    );
    rows[index].settled = true;
    save(p, voter, &rows)?;
    Ok(cancelled.then_some(
        "Same-nonce cancellation verified. Refresh current evidence before another action.",
    ))
}
pub(crate) fn label(action: &str) -> &'static str {
    match action {
        "approveStake" => "stake approval",
        "stake" => "stake",
        "withdraw" => "stake withdrawal",
        "commit" => "vote commitment",
        "reveal" => "vote reveal",
        "closeCommitA(uint256)" => "first committee close",
        "closeCommitB(uint256)" => "second committee close",
        "closeReveal(uint256)" => "reveal close",
        "draw(uint256)" => "outcome draw",
        "cacheOutcome(uint256)" => "save original draw hash",
        "expireOutcome(uint256,uint8,uint40)" => "complete expired draw",
        "closeChallenge(uint256)" => "case finalization",
        "challenge(uint256,uint8,uint8)" | "challenge(uint256)" => "outcome challenge",
        "claim(uint256,address)" => "vote settlement",
        "withdrawRefund(uint256)" => "fee refund",
        _ => "moderator transaction",
    }
}
pub(crate) fn summary(p: &ModeratorProfile, voter: &str) -> Result<Option<String>> {
    Ok(load(p, voter)?.iter().find(|r| !r.settled).map(|r| {
        format!(
            "Unfinished {}{}. Check it before sending again.",
            label(&r.action),
            r.case_id
                .as_ref()
                .map(|id| format!(" for case {id}"))
                .unwrap_or_default()
        )
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Request, Value, String, String, String) {
        let salt = "a7".repeat(32);
        let data = format!("0x12345678{}{}", "00".repeat(31) + "01", salt);
        let hash = format!("0x{}", "aa".repeat(32));
        let anchor = format!("0x{}", "bb".repeat(32));
        let r = Request {
            version: 1,
            chain: 10200,
            contract: format!("0x{}", "10".repeat(20)),
            voter: format!("0x{}", "50".repeat(20)),
            to: format!("0x{}", "20".repeat(20)),
            action: "reveal".into(),
            case_id: Some("1".into()),
            digest: digest(&data).unwrap(),
            nonce: 9,
            after_block: 64,
            hash: None,
            settled: false,
            resolved_hash: None,
            outcome: None,
            rejected: false,
            not_sent: false,
        };
        let tx = json!({"hash":hash,"from":r.voter,"to":r.to,"value":"0x0","input":data,"nonce":"0x9","blockNumber":"0x42","blockHash":anchor});
        (r, tx, hash, anchor, salt)
    }
    fn profile(r: &Request) -> ModeratorProfile {
        let pin = json!({"address":r.contract,"codeHash":r.digest});
        serde_json::from_value(json!({"deployment":{"chainId":"10200","moderation":pin,"stakes":pin,"index":pin,"token":pin,"guidelines":{"version":"1","hash":r.digest}},"rpcUrl":"http://localhost/fixture/rpc","gatewayUrl":"http://localhost","timing":{"clockErrorSeconds":5,"maxEvidenceAgeSeconds":30,"maxHeadLagSeconds":30,"inclusionBudgetSeconds":120}})).unwrap()
    }
    #[test]
    fn damaged_foreign_or_multiple_unknown_records_never_become_an_empty_journal() {
        let (r, _, _, _, _) = fixture();
        let p = profile(&r);
        assert!(parse("not json", &p, &r.voter).is_err());
        assert!(parse("{}", &p, &r.voter).is_err());
        let raw = serde_json::to_string(&vec![r.clone()]).unwrap();
        assert_eq!(parse(&raw, &p, &r.voter).unwrap(), vec![r.clone()]);
        assert!(parse(&raw, &p, &r.to).is_err());
        let mut foreign = p.clone();
        foreign.deployment.chain_id = 1;
        assert!(parse(&raw, &foreign, &r.voter).is_err());
        let doubled = serde_json::to_string(&vec![r.clone(), r.clone()]).unwrap();
        assert!(parse(&doubled, &p, &r.voter).is_err());
        let mut rejected = r.clone();
        rejected.rejected = true;
        rejected.settled = true;
        assert!(rejected.validate(&p, &r.voter).is_ok());
        rejected.settled = false;
        assert!(rejected.validate(&p, &r.voter).is_err());
    }
    #[test]
    fn pre_disclosure_abort_is_retained_and_never_reclassifies_a_broadcast() {
        let (mut r, _, hash, _, _) = fixture();
        let p = profile(&r);
        r.finish_without_send(false).unwrap();
        assert!(r.not_sent && r.settled && !r.rejected && r.hash.is_none());
        r.validate(&p, &r.voter).unwrap();
        assert!(r.finish_without_send(false).is_err());
        let (mut broadcast, _, _, _, _) = fixture();
        broadcast.hash = Some(hash);
        assert!(broadcast.finish_without_send(false).is_err());
        assert!(!broadcast.settled && !broadcast.not_sent);
        let (mut rejected, _, _, _, _) = fixture();
        rejected.finish_without_send(true).unwrap();
        assert!(rejected.rejected && !rejected.not_sent);
        // Older journal records have no pre-disclosure-abort claim.
        let mut old = serde_json::to_value(fixture().0).unwrap();
        old.as_object_mut().unwrap().remove("not_sent");
        let old: Request = serde_json::from_value(old).unwrap();
        assert!(!old.not_sent && !old.settled);
    }
    #[test]
    fn serialized_reveal_intent_has_no_preimage_or_choice() {
        let (r, tx, _, _, salt) = fixture();
        let raw = serde_json::to_string(&r).unwrap();
        assert!(!raw.contains(&salt));
        assert!(!raw.contains(tx["input"].as_str().unwrap()));
        assert!(!raw.contains("\"vote\""));
        assert!(!raw.contains("\"salt\""));
        assert!(!raw.contains("\"data\""));
        assert_eq!(serde_json::from_str::<Request>(&raw).unwrap(), r);
    }
    #[test]
    fn hashless_match_requires_exact_nonce_intent_sender_and_boundary() {
        let (r, tx, hash, anchor, _) = fixture();
        assert!(r.matches(&tx, &hash, 66, &anchor).is_ok());
        for (field, value) in [
            ("nonce", json!("0x8")),
            ("from", json!(r.to)),
            ("to", json!(r.voter)),
            ("value", json!("0x1")),
            ("input", json!("0x12345678")),
            ("blockHash", json!(hash)),
            ("blockNumber", json!("0x41")),
            ("hash", json!(anchor)),
        ] {
            let mut wrong = tx.clone();
            wrong[field] = value;
            assert!(r.matches(&wrong, &hash, 66, &anchor).is_err(), "{field}");
        }
        let mut old = r.clone();
        old.after_block = 66;
        assert!(old.matches(&tx, &hash, 66, &anchor).is_err());
    }
    #[test]
    fn returned_hash_cannot_be_replaced_by_another_transaction() {
        let (mut r, tx, hash, anchor, _) = fixture();
        r.hash = Some(anchor.clone());
        assert!(r.matches(&tx, &hash, 66, &anchor).is_err());
        r.hash = Some(hash.clone());
        let mut different_nonce = tx;
        different_nonce["nonce"] = json!("0xa");
        // A valid wallet-returned hash binds the exact transaction even if the
        // wallet selected a different nonce from the RPC's earlier estimate.
        assert!(r.matches(&different_nonce, &hash, 66, &anchor).is_ok());
    }
    #[test]
    fn speedup_requires_the_verified_original_nonce_and_preserves_its_hash() {
        let (mut r, original, hash, anchor, _) = fixture();
        r.hash = Some(hash.clone());
        let replacement_hash = format!("0x{}", "cc".repeat(32));
        let mut tx = original.clone();
        tx["hash"] = json!(replacement_hash);
        assert_eq!(
            r.replacement(None, &tx, &replacement_hash, 66, &anchor),
            Err("REQUEST_ORIGINAL_UNAVAILABLE")
        );
        assert_eq!(
            r.replacement(Some(&original), &tx, &replacement_hash, 66, &anchor),
            Ok(false)
        );
        let mut bad_original = original.clone();
        bad_original["input"] = json!("0x12345678");
        assert!(r
            .replacement(Some(&bad_original), &tx, &replacement_hash, 66, &anchor)
            .is_err());
        tx["nonce"] = json!("0xa");
        assert!(r
            .replacement(Some(&original), &tx, &replacement_hash, 66, &anchor)
            .is_err());
        assert_eq!(r.hash.as_deref(), Some(hash.as_str()));
    }
    #[test]
    fn cancellation_is_only_an_anchored_same_nonce_empty_zero_value_self_transfer() {
        let (r, mut tx, hash, anchor, _) = fixture();
        tx["to"] = json!(r.voter);
        tx["input"] = json!("0x");
        assert_eq!(r.replacement(None, &tx, &hash, 66, &anchor), Ok(true));
        for (field, value) in [
            ("to", json!(r.to)),
            ("value", json!("0x1")),
            ("input", json!("0x00")),
            ("nonce", json!("0x8")),
            ("from", json!(r.to)),
        ] {
            let mut wrong = tx.clone();
            wrong[field] = value;
            assert!(
                r.replacement(None, &wrong, &hash, 66, &anchor).is_err(),
                "{field}"
            );
        }
        let mut old = r;
        old.after_block = 66;
        assert!(old.replacement(None, &tx, &hash, 66, &anchor).is_err());
    }
    #[test]
    fn stored_record_cannot_accept_extra_preimage_fields() {
        let (r, _, _, _, _) = fixture();
        let mut raw = serde_json::to_value(r).unwrap();
        raw["salt"] = json!("secret");
        assert!(serde_json::from_value::<Request>(raw).is_err());
    }

    #[test]
    fn challenge_receipt_cannot_substitute_round_outcome_or_legacy_calldata() {
        use swarm_core::moderator::{encode_action, Action, Uint256};
        let (mut request, mut tx, hash, anchor, _) = fixture();
        let call = encode_action(
            Action::Challenge,
            Uint256::from_u64(1),
            &["0".into(), "1".into()],
        )
        .unwrap();
        request.action = Action::Challenge.signature().into();
        request.digest = digest(&call).unwrap();
        tx["input"] = json!(call);
        assert!(request.matches(&tx, &hash, 66, &anchor).is_ok());
        for args in [["1", "1"], ["0", "2"]] {
            let mut wrong = tx.clone();
            wrong["input"] = json!(encode_action(
                Action::Challenge,
                Uint256::from_u64(1),
                &args.map(String::from)
            )
            .unwrap());
            assert!(request.matches(&wrong, &hash, 66, &anchor).is_err());
            assert!(!request.exact_intent(&wrong, &hash));
        }
        tx["input"] = json!(format!(
            "{}{}",
            swarm_core::selector("challenge(uint256)"),
            Uint256::from_u64(1).abi()
        ));
        assert!(request.matches(&tx, &hash, 66, &anchor).is_err());
        assert!(!request.settled && request.hash.is_none());
    }
}
