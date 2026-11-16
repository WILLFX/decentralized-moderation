//! Browser adapters and explicit workflows for the separate Swarm websites.
mod moderator;
mod registration;

pub(crate) type BrowserResult<T> = std::result::Result<T, &'static str>;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod token_amounts;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod coordination;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod transport;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod wallet;
#[cfg(all(target_arch = "wasm32", feature = "interop-tests"))]
pub use moderator::vault::{decrypt_recovery_for_test, encrypt_recovery_for_test};

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use moderator::start;

// Native builds run state tests without pretending browser APIs are available.
#[cfg(not(any(target_arch = "wasm32", feature = "browser-check")))]
pub fn start() -> Result<(), wasm_bindgen::JsValue> {
    Ok(())
}

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod publisher;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use publisher::start_publisher;
#[cfg(not(any(target_arch = "wasm32", feature = "browser-check")))]
pub fn start_publisher() -> Result<(), wasm_bindgen::JsValue> {
    Ok(())
}

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod search;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use search::start_search;
#[cfg(not(any(target_arch = "wasm32", feature = "browser-check")))]
pub fn start_search() -> Result<(), wasm_bindgen::JsValue> {
    Ok(())
}

// Test harness access only; public website builds omit this export.
#[cfg(all(
    feature = "interop-tests",
    any(target_arch = "wasm32", feature = "browser-check")
))]
pub use moderator::vault::VoteVault;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod versioning;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod versions;
