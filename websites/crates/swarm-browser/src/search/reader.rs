//! Pinned read-only search transport. Each call checks cancellation before and after IO.
use crate::{
    transport::{as_str, quantity, rpc},
    BrowserResult as Result,
};
use serde_json::{json, Value};
use std::{cell::Cell, rc::Rc};
use swarm_core::moderator::SourceBlock;
use swarm_core::{
    link_checks, selector, verify_guidelines, verify_link, verify_runtime, ModeratorProfile,
};
#[derive(Clone)]
pub(super) struct Context {
    pub source: SourceBlock,
    pub pin: Value,
}
#[derive(Clone)]
pub(super) struct Reader {
    pub profile: ModeratorProfile,
    pub generation: Rc<Cell<u64>>,
    pub expected: u64,
}
impl Reader {
    pub fn live(&self) -> Result<()> {
        if self.generation.get() != self.expected {
            Err("CANCELLED")
        } else {
            Ok(())
        }
    }
    pub async fn rpc(&self, method: &str, args: Value) -> Result<Value> {
        self.live()?;
        let v = rpc(&self.profile, method, args).await?;
        self.live()?;
        Ok(v)
    }
    pub async fn call(&self, c: &Context, to: &str, sig: &str, args: &str) -> Result<String> {
        Ok(as_str(
            &self
                .rpc(
                    "eth_call",
                    json!([{"to":to,"data":format!("{}{}",selector(sig),args)},c.pin]),
                )
                .await?,
        )?
        .into())
    }
    pub async fn begin(&self, anchor: Option<&Context>) -> Result<Context> {
        self.chain().await?;
        let tag = anchor
            .map(|c| format!("0x{:x}", c.source.number))
            .unwrap_or("latest".into());
        let source = parse_block(
            &self
                .rpc("eth_getBlockByNumber", json!([tag, false]))
                .await?,
        )?;
        if anchor.is_some_and(|a| a.source != source) {
            return Err("SOURCE_BLOCK_CHANGED");
        }
        let c = Context {
            pin: json!({"blockHash":source.hash,"requireCanonical":true}),
            source,
        };
        let d = &self.profile.deployment;
        for p in [&d.moderation, &d.stakes, &d.index, &d.token] {
            let code = self.rpc("eth_getCode", json!([p.address, c.pin])).await?;
            let code = as_str(&code)?;
            if code.len() > 131074 {
                return Err("INVALID_RUNTIME_LENGTH");
            }
            verify_runtime(p, code).map_err(|e| e.0)?;
        }
        for link in link_checks(d) {
            verify_link(
                &link,
                &self
                    .call(&c, &link.contract_address, link.signature, "")
                    .await?,
            )
            .map_err(|e| e.0)?;
        }
        verify_guidelines(
            d,
            &self
                .call(&c, &d.moderation.address, "guidelinesVersion()", "")
                .await?,
            &self
                .call(&c, &d.moderation.address, "guidelinesHash()", "")
                .await?,
        )
        .map_err(|e| e.0)?;
        Ok(c)
    }
    pub async fn finish(&self, c: &Context) -> Result<()> {
        let b = parse_block(
            &self
                .rpc(
                    "eth_getBlockByNumber",
                    json!([format!("0x{:x}", c.source.number), false]),
                )
                .await?,
        )?;
        if b != c.source {
            return Err("SOURCE_BLOCK_CHANGED");
        }
        self.chain().await
    }
    async fn chain(&self) -> Result<()> {
        if quantity(as_str(&self.rpc("eth_chainId", json!([])).await?)?)?
            != self.profile.deployment.chain_id
        {
            Err("SOURCE_CHAIN_CHANGED")
        } else {
            Ok(())
        }
    }
}
fn parse_block(v: &Value) -> Result<SourceBlock> {
    let hash = as_str(&v["hash"])?;
    if hash.len() != 66
        || !hash.starts_with("0x")
        || !hash[2..].bytes().all(|b| b.is_ascii_hexdigit())
        || hash[2..].bytes().all(|b| b == b'0')
    {
        return Err("INVALID_BLOCK_HASH");
    }
    Ok(SourceBlock {
        number: quantity(as_str(&v["number"])?)?,
        timestamp: quantity(as_str(&v["timestamp"])?)?,
        hash: hash.to_ascii_lowercase(),
    })
}
