//! Explicit EIP-1193 calls. Only the transaction workflow may call send_prepared.
use crate::{transport::quantity, BrowserResult as Result};
use js_sys::{Array, Function, Promise, Reflect};
use serde_json::{json, Value};
use wasm_bindgen::{JsCast, JsValue};
use wasm_bindgen_futures::JsFuture;

#[path = "wallet/discovery.rs"]
mod discovery;
pub(crate) use discovery::{
    discover, needs_selection, picker_choice, render_picker, select, selected_id,
};
pub(crate) fn provider() -> Result<JsValue> {
    discovery::provider()
}
async fn request(method: &str, params: Value) -> Result<JsValue> {
    let p = provider()?;
    let f = Reflect::get(&p, &"request".into())
        .map_err(|_| "WALLET_UNAVAILABLE")?
        .dyn_into::<Function>()
        .map_err(|_| "WALLET_UNAVAILABLE")?;
    let envelope = js_sys::JSON::parse(&json!({"method":method,"params":params}).to_string())
        .map_err(|_| "INVALID_WALLET_REQUEST")?;
    let promise = f
        .call1(&p, &envelope)
        .map_err(wallet_error)?
        .dyn_into::<Promise>()
        .map_err(|_| "WALLET_REQUEST_FAILED")?;
    JsFuture::from(promise).await.map_err(wallet_error)
}
fn wallet_error(error: JsValue) -> &'static str {
    if Reflect::get(&error, &"code".into())
        .ok()
        .and_then(|v| v.as_f64())
        == Some(4001.0)
    {
        "WALLET_REJECTED"
    } else {
        "WALLET_REQUEST_FAILED"
    }
}
pub(crate) async fn read(method: &str) -> Result<JsValue> {
    if !["eth_requestAccounts", "eth_accounts", "eth_chainId"].contains(&method) {
        return Err("READ_METHOD_REQUIRED");
    }
    request(method, json!([])).await
}
pub(crate) fn account(value: &JsValue) -> Result<String> {
    if !Array::is_array(value) {
        return Err("INVALID_WALLET_ACCOUNTS");
    }
    let first = Array::from(value)
        .get(0)
        .as_string()
        .ok_or("NO_WALLET_ACCOUNT")?;
    check_hex(&first, 20, true)?;
    Ok(first.to_ascii_lowercase())
}
fn check_hex(value: &str, bytes: usize, nonzero: bool) -> Result<()> {
    if value.len() != 2 + bytes * 2
        || !value.starts_with("0x")
        || !value[2..].bytes().all(|v| v.is_ascii_hexdigit())
        || nonzero && value[2..].bytes().all(|v| v == b'0')
    {
        return Err("INVALID_WALLET_VALUE");
    }
    Ok(())
}
pub(crate) async fn check(chain: u64, voter: &str) -> Result<()> {
    let c = read("eth_chainId")
        .await?
        .as_string()
        .ok_or("INVALID_WALLET_CHAIN")?;
    if quantity(&c)? != chain {
        return Err("WALLET_CHAIN_CHANGED");
    }
    if !account(&read("eth_accounts").await?)?.eq_ignore_ascii_case(voter) {
        return Err("WALLET_ACCOUNT_CHANGED");
    }
    Ok(())
}
/// Caller must check wallet, fresh evidence and its context generation immediately
/// before this call. No extra asynchronous read may delay the final reveal guard.
pub(crate) async fn send_prepared(chain: u64, from: &str, to: &str, data: &str) -> Result<String> {
    send(chain, from, to, data, None).await
}
/// Moderator write-ahead recovery binds this nonce to the actual wallet request.
/// No asynchronous reads may be added here after the final reveal guard.
pub(crate) async fn send_journaled(
    chain: u64,
    from: &str,
    to: &str,
    data: &str,
    nonce: u64,
) -> Result<String> {
    send(chain, from, to, data, Some(nonce)).await
}
fn transaction(chain: u64, from: &str, to: &str, data: &str, nonce: Option<u64>) -> Result<Value> {
    check_hex(from, 20, true)?;
    check_hex(to, 20, true)?;
    if data.len() < 10
        || data.len() % 2 != 0
        || !data.starts_with("0x")
        || !data[2..].bytes().all(|v| v.is_ascii_hexdigit())
    {
        return Err("INVALID_TRANSACTION");
    }
    let mut tx =
        json!({"chainId":format!("0x{chain:x}"),"from":from,"to":to,"data":data,"value":"0x0"});
    if let Some(nonce) = nonce {
        tx["nonce"] = json!(format!("0x{nonce:x}"));
    }
    Ok(tx)
}
async fn send(chain: u64, from: &str, to: &str, data: &str, nonce: Option<u64>) -> Result<String> {
    let tx = transaction(chain, from, to, data, nonce)?;
    let hash = request("eth_sendTransaction", json!([tx]))
        .await?
        .as_string()
        .ok_or("INVALID_TRANSACTION_HASH")?;
    check_hex(&hash, 32, true)?;
    Ok(hash.to_ascii_lowercase())
}
#[cfg(test)]
mod transaction_tests {
    use super::*;
    #[test]
    fn durable_nonce_is_in_the_wallet_envelope_and_cannot_change_value_or_recipient_checks() {
        let from = format!("0x{}", "11".repeat(20));
        let to = format!("0x{}", "22".repeat(20));
        let tx = transaction(10200, &from, &to, "0x12345678", Some(u64::MAX)).unwrap();
        assert_eq!(tx["nonce"], "0xffffffffffffffff");
        assert_eq!(tx["from"], from);
        assert_eq!(tx["to"], to);
        assert_eq!(tx["value"], "0x0");
        assert_eq!(tx["chainId"], "0x27d8");
        assert!(transaction(10200, &from, &to, "0x12345678", None)
            .unwrap()
            .get("nonce")
            .is_none());
        assert!(transaction(
            10200,
            &from,
            &format!("0x{}", "00".repeat(20)),
            "0x12345678",
            Some(9)
        )
        .is_err());
        assert!(transaction(10200, &from, &to, "0x123", Some(9)).is_err());
    }
}
