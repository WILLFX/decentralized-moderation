//! Moderator interface, chain evidence, request history and private vote recovery.
mod saved_vote;
mod state;
pub(crate) mod view;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod app;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod evidence;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod requests;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub(crate) mod vault;
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod workflow;

#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
pub use app::start;
