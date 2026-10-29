use crate::BrowserResult as Result;
use js_sys::{Reflect, Uint8Array};
use serde_json::{json, Value};
use swarm_core::ModeratorProfile;
use wasm_bindgen::{closure::Closure, prelude::*, JsCast};
use wasm_bindgen_futures::JsFuture;
use web_sys::{Request, RequestInit, Response};
pub(crate) async fn rpc(profile: &ModeratorProfile, method: &str, params: Value) -> Result<Value> {
    if ![
        "eth_chainId",
        "eth_getBlockByNumber",
        "eth_getCode",
        "eth_call",
        "eth_getTransactionReceipt",
        "eth_getTransactionByHash",
        "eth_getTransactionCount",
    ]
    .contains(&method)
    {
        return Err("READ_METHOD_REQUIRED");
    }
    let init = RequestInit::new();
    init.set_method("POST");
    init.set_body(&JsValue::from_str(
        &json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}).to_string(),
    ));
    let headers = web_sys::Headers::new().map_err(|_| "RESOURCE_READ_FAILED")?;
    headers
        .set("Content-Type", "application/json")
        .map_err(|_| "RESOURCE_READ_FAILED")?;
    init.set_headers(&headers);
    let bytes = fetch(&profile.rpc_url, &init, 2 * 1024 * 1024).await?;
    let body: Value = serde_json::from_slice(&bytes).map_err(|_| "INVALID_RPC_RESPONSE")?;
    if method == "eth_call" && body["jsonrpc"] == "2.0" && body["id"] == 1 {
        let data = body["error"]["data"]
            .as_str()
            .or_else(|| body["error"]["data"]["data"].as_str());
        if data.is_some_and(|value| {
            value.eq_ignore_ascii_case(&swarm_core::selector("SeedUnavailable()"))
        }) {
            return Err("SEED_UNAVAILABLE");
        }
    }
    if body["jsonrpc"] != "2.0"
        || body["id"] != 1
        || body.get("error").is_some()
        || body.get("result").is_none()
    {
        return Err("RPC_READ_FAILED");
    }
    Ok(body["result"].clone())
}

pub(crate) async fn fetch(url: &str, init: &RequestInit, limit: usize) -> Result<Vec<u8>> {
    fetch_with_status(url, init, limit, 15000)
        .await
        .map(|(_, bytes)| bytes)
}

pub(crate) async fn fetch_with_status(
    url: &str,
    init: &RequestInit,
    limit: usize,
    timeout_ms: i32,
) -> Result<(u16, Vec<u8>)> {
    if !(1..=60000).contains(&timeout_ms) {
        return Err("INVALID_RESOURCE_TIMEOUT");
    }
    let controller = web_sys::AbortController::new().map_err(|_| "RESOURCE_READ_FAILED")?;
    init.set_signal(Some(&controller.signal()));
    init.set_credentials(web_sys::RequestCredentials::Omit);
    init.set_redirect(web_sys::RequestRedirect::Error);
    init.set_cache(web_sys::RequestCache::NoStore);
    init.set_referrer_policy(web_sys::ReferrerPolicy::NoReferrer);
    let request = Request::new_with_str_and_init(url, init).map_err(|_| "RESOURCE_READ_FAILED")?;
    if request.method() == "POST"
        && !request
            .headers()
            .has("Content-Type")
            .map_err(|_| "RESOURCE_READ_FAILED")?
    {
        request
            .headers()
            .set("Content-Type", "application/json")
            .map_err(|_| "RESOURCE_READ_FAILED")?;
    }
    let abort = Closure::<dyn FnMut()>::new(move || controller.abort());
    let window = web_sys::window().unwrap();
    let timeout = window
        .set_timeout_with_callback_and_timeout_and_arguments_0(
            abort.as_ref().unchecked_ref(),
            timeout_ms,
        )
        .map_err(|_| "RESOURCE_READ_FAILED")?;
    let result = async {
        let response = JsFuture::from(window.fetch_with_request(&request))
            .await
            .map_err(|_| "RESOURCE_READ_FAILED")?
            .dyn_into::<Response>()
            .map_err(|_| "RESOURCE_READ_FAILED")?;
        let status = response.status();
        if !response.ok() {
            return Err("RESOURCE_UNAVAILABLE");
        }
        if let Some(length) = response
            .headers()
            .get("Content-Length")
            .map_err(|_| "RESOURCE_READ_FAILED")?
        {
            if length
                .parse::<usize>()
                .map_err(|_| "INVALID_RESOURCE_LENGTH")?
                > limit
            {
                return Err("RESOURCE_TOO_LARGE");
            }
        }
        let stream = response.body().ok_or("RESOURCE_READ_FAILED")?;
        let reader = stream
            .get_reader()
            .dyn_into::<web_sys::ReadableStreamDefaultReader>()
            .map_err(|_| "RESOURCE_READ_FAILED")?;
        let read_result = async {
            let mut bytes = Vec::new();
            loop {
                let chunk = JsFuture::from(reader.read())
                    .await
                    .map_err(|_| "RESOURCE_READ_FAILED")?;
                let done = Reflect::get(&chunk, &"done".into())
                    .map_err(|_| "RESOURCE_READ_FAILED")?
                    .as_bool()
                    .ok_or("RESOURCE_READ_FAILED")?;
                if done {
                    break;
                }
                let data =
                    Reflect::get(&chunk, &"value".into()).map_err(|_| "RESOURCE_READ_FAILED")?;
                let array = data
                    .dyn_into::<Uint8Array>()
                    .map_err(|_| "RESOURCE_READ_FAILED")?;
                if array.length() as usize > limit.saturating_sub(bytes.len()) {
                    return Err("RESOURCE_TOO_LARGE");
                }
                bytes.extend_from_slice(&array.to_vec());
            }
            Ok(bytes)
        }
        .await;
        // Cancel even on a size or transport failure so excess data is not read.
        let _ = JsFuture::from(reader.cancel()).await;
        reader.release_lock();
        read_result.map(|bytes| (status, bytes))
    }
    .await;
    window.clear_timeout_with_handle(timeout);
    drop(abort);
    result
}

pub(crate) fn as_str(value: &Value) -> Result<&str> {
    value.as_str().ok_or("INVALID_RPC_RESULT")
}

pub(crate) fn quantity(raw: &str) -> Result<u64> {
    let s = raw.strip_prefix("0x").ok_or("INVALID_RPC_QUANTITY")?;
    if s.is_empty()
        || (s.len() > 1 && s.starts_with('0'))
        || !s.bytes().all(|v| v.is_ascii_hexdigit())
    {
        return Err("INVALID_RPC_QUANTITY");
    }
    u64::from_str_radix(s, 16).map_err(|_| "INVALID_RPC_QUANTITY")
}
