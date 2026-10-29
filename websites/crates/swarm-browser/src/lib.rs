//! Browser adapters and explicit workflows for the separate Swarm websites.
mod moderator_view;
mod registration;
mod saved_vote;
mod state;

pub(crate) type BrowserResult<T> = std::result::Result<T, &'static str>;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod token_amounts;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod app;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod deployment;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod evidence;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod transport;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod vault;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod wallet;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod workflow;
#[cfg(all(target_arch = "wasm32", feature = "interop-tests"))]
pub use vault::{decrypt_recovery_for_test, encrypt_recovery_for_test};

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use app::start;

// Native builds run state tests without pretending browser APIs are available.
#[cfg(not(any(target_arch = "wasm32", feature = "browser-check")))]
pub fn start() -> Result<(), wasm_bindgen::JsValue> {
    Ok(())
}

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod publisher_app;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use publisher_app::start_publisher;
#[cfg(not(any(target_arch = "wasm32", feature = "browser-check")))]
pub fn start_publisher() -> Result<(), wasm_bindgen::JsValue> {
    Ok(())
}

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod search_app;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use search_app::start_search;
#[cfg(not(any(target_arch = "wasm32", feature = "browser-check")))]
pub fn start_search() -> Result<(), wasm_bindgen::JsValue> {
    Ok(())
}

// Test harness access only; public website builds omit this export.
#[cfg(all(
    feature = "interop-tests",
    any(target_arch = "wasm32", feature = "browser-check")
))]
pub use vault::VoteVault;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
#[path = "moderator/requests.rs"]
mod moderator_requests;
