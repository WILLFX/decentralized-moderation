//! Explicit EIP-1193 calls. Only the transaction workflow may call send_prepared.
use crate::{transport::quantity, BrowserResult as Result};
use js_sys::{Array, Function, Promise, Reflect};
use serde_json::{json, Value};
use wasm_bindgen::{JsCast, JsValue};
use wasm_bindgen_futures::JsFuture;

pub(crate) fn provider() -> Result<JsValue> {
    let window = web_sys::window().ok_or("WALLET_UNAVAILABLE")?;
    let p = Reflect::get(window.as_ref(), &"ethereum".into()).map_err(|_| "WALLET_UNAVAILABLE")?;
    if p.is_null() || p.is_undefined() {
        return Err("WALLET_UNAVAILABLE");
    }
    if !Reflect::get(&p, &"isMetaMask".into())
        .ok()
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
    {
        return Err("METAMASK_PROVIDER_REQUIRED");
    }
    Ok(p)
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
    check_hex(from, 20, true)?;
    check_hex(to, 20, true)?;
    if data.len() < 10
        || data.len() % 2 != 0
        || !data.starts_with("0x")
        || !data[2..].bytes().all(|v| v.is_ascii_hexdigit())
    {
        return Err("INVALID_TRANSACTION");
    }
    let hash = request(
        "eth_sendTransaction",
        json!([{"chainId":format!("0x{chain:x}"),
        "from":from,"to":to,"data":data,"value":"0x0"}]),
    )
    .await?
    .as_string()
    .ok_or("INVALID_TRANSACTION_HASH")?;
    check_hex(&hash, 32, true)?;
    Ok(hash.to_ascii_lowercase())
}
