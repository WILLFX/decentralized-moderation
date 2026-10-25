use crate::{
    deployment::verification, registration::install_handlers, state::WalletState,
    transport::quantity,
};
use js_sys::{Function, Reflect};
use std::{cell::RefCell, rc::Rc};
use swarm_core::{parse_profile, ModeratorProfile};
use wasm_bindgen::{closure::Closure, prelude::*, JsCast};
use wasm_bindgen_futures::{spawn_local, JsFuture};
use web_sys::{Element, HtmlInputElement};

use crate::wallet::{account, provider, read as wallet_request};
#[path = "controls.rs"]
mod controls;
type Result<T> = std::result::Result<T, &'static str>;

#[derive(Default)]
struct App {
    profile: Option<ModeratorProfile>,
    wallet: WalletState,
    busy: bool,
    wallet_events_bound: bool,
    wallet_listeners: Vec<WalletListener>,
    vault: crate::vault::VoteVault,
    controls: controls::State,
}

struct WalletListener {
    provider: JsValue,
    remove: Function,
    event: &'static str,
    handler: Closure<dyn FnMut(JsValue)>,
}

fn document() -> web_sys::Document {
    web_sys::window().unwrap().document().unwrap()
}
fn element(id: &str) -> Element {
    document().get_element_by_id(id).unwrap()
}
fn text(id: &str, value: &str) {
    element(id).set_text_content(Some(value));
}
fn notice(value: &str) {
    text("notice", value);
}

pub fn start() -> std::result::Result<(), JsValue> {
    element("app").set_inner_html(r#"
      <header><h1>Swarm Review</h1></header>
      <p class="scope">Verify the selected deployment,
      review cases, keep encrypted vote recovery and prepare transactions for MetaMask.
      Each transaction requires an explicit action and wallet confirmation.</p>
      <div id="notice" role="status" aria-live="polite">Choose the current moderator profile to begin.</div>
      <section><h2>Deployment configuration</h2>
      <label for="profile">Moderator JSON profile</label>
      <input id="profile" type="file" accept=".json,application/json">
      <p id="configuration" class="status">No profile loaded.</p></section>
      <section><h2>Wallet</h2><p id="wallet" class="status">Not connected.</p>
      <button id="connect" type="button">Connect MetaMask</button>
      <p class="muted">Requests account access only. No signature or transaction is requested.
      No automatic network switch is made.</p></section>
      <section><h2>Verified contract state</h2>
      <button id="refresh" type="button">Verify deployment and read Case 2</button>
      <p id="verification" class="status">Not checked.</p>
      <p class="muted">The selected RPC supplies this evidence. Runtime pins and canonical-block
      checks do not independently verify blockchain consensus.</p></section>
    "#);
    let app = Rc::new(RefCell::new(App::default()));
    controls::mount(app.clone());
    bind_profile(app.clone());
    bind_connect(app.clone());
    bind_refresh(app.clone());
    // No wallet is required to read the scope or load a configuration. A
    // missing provider is reported if the user explicitly requests connection.
    let _ = bind_wallet_events(&app);
    Ok(())
}

fn update_wallet(app: &App) {
    let status = if app.wallet.connected {
        "Connected"
    } else {
        "Not connected"
    };
    text(
        "wallet",
        &format!(
            "{status}\nAccount: {}\nWallet chain: {}",
            app.wallet.account.as_deref().unwrap_or("not selected"),
            app.wallet
                .chain
                .map(|v| v.to_string())
                .unwrap_or_else(|| "not checked".into())
        ),
    );
    text(
        "connect",
        if app.wallet.connected {
            "Refresh wallet connection"
        } else {
            "Connect MetaMask"
        },
    );
    controls::render(app);
}

fn busy(app: &Rc<RefCell<App>>, value: bool) {
    app.borrow_mut().busy = value;
    for id in ["connect", "refresh", "profile"] {
        if value {
            element(id).set_attribute("disabled", "").unwrap();
        } else {
            element(id).remove_attribute("disabled").unwrap();
        }
    }
    controls::set_busy(value);
    if !value {
        controls::render(&app.borrow());
    }
}

fn bind_profile(app: Rc<RefCell<App>>) {
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if app.borrow().busy {
            return;
        }
        let input = element("profile").dyn_into::<HtmlInputElement>().unwrap();
        let Some(file) = input.files().and_then(|files| files.get(0)) else {
            return;
        };
        // Clear old evidence before reading or validating a replacement file.
        {
            let mut s = app.borrow_mut();
            s.profile = None;
            s.wallet.invalidate();
            s.vault.lock();
            s.controls.clear_context();
            update_wallet(&s);
        }
        controls::clear_dom();
        text("configuration", "No profile loaded.");
        text("verification", "Not checked for this profile.");
        if file.size() > 65536.0 {
            notice("Profile rejected: file exceeds 64 KiB.");
            return;
        }
        let app = app.clone();
        busy(&app, true);
        spawn_local(async move {
            let result = match JsFuture::from(file.text()).await {
                Ok(value) => value
                    .as_string()
                    .ok_or("PROFILE_READ_FAILED")
                    .and_then(|s| parse_profile(&s).map_err(|_| "INVALID_PROFILE")),
                Err(_) => Err("PROFILE_READ_FAILED"),
            };
            match result {
                Ok(profile) => {
                    text(
                        "configuration",
                        &format!(
                            "Configured chain: {}\nModeration: {}\nRPC: {}\nBee gateway: {}",
                            profile.deployment.chain_id,
                            profile.deployment.moderation.address,
                            redact_url(&profile.rpc_url),
                            redact_url(&profile.gateway_url)
                        ),
                    );
                    app.borrow_mut().profile = Some(profile);
                    notice("Profile loaded. Connect your intended wallet account next.");
                }
                Err(code) => notice(code),
            }
            busy(&app, false);
        });
    });
    element("profile")
        .add_event_listener_with_callback("change", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
}

// Endpoint queries can contain access tokens. Never render them or provider text.
fn redact_url(url: &str) -> String {
    // Some providers put credentials in URL paths as well as query strings.
    let Some((scheme, rest)) = url.split_once("://") else {
        return "configured endpoint".into();
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    format!("{scheme}://{authority} (endpoint path hidden)")
}

fn bind_connect(app: Rc<RefCell<App>>) {
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if app.borrow().busy {
            return;
        }
        let Some(profile) = app.borrow().profile.clone() else {
            notice("Load a moderator profile first.");
            return;
        };
        let app = app.clone();
        busy(&app, true);
        // A provider can be injected after the module starts.
        if let Err(code) = bind_wallet_events(&app) {
            app.borrow_mut().wallet.invalidate();
            update_wallet(&app.borrow());
            text(
                "verification",
                "Not checked: wallet events are not safely registered.",
            );
            notice(code);
            busy(&app, false);
            return;
        }
        text("verification", "Not checked for this wallet connection.");
        notice("Waiting for MetaMask account access…");
        spawn_local(async move {
            let result: Result<()> = async {
                let selected = account(&wallet_request("eth_requestAccounts").await?)?;
                // Initial authorization can emit accountsChanged before returning.
                let epoch = app.borrow().wallet.epoch;
                let chain = quantity(
                    &wallet_request("eth_chainId")
                        .await?
                        .as_string()
                        .ok_or("INVALID_WALLET_CHAIN")?,
                )?;
                if chain != profile.deployment.chain_id {
                    return Err(
                        "WALLET_CHAIN_MISMATCH: select the configured network in MetaMask.",
                    );
                }
                let current = account(&wallet_request("eth_accounts").await?)?;
                if selected != current || epoch != app.borrow().wallet.epoch {
                    return Err("WALLET_CONTEXT_CHANGED: reconnect the selected account.");
                }
                let mut s = app.borrow_mut();
                if s.wallet.account.as_deref() != Some(current.as_str())
                    || s.wallet.chain != Some(chain)
                {
                    s.wallet.invalidate();
                    s.vault.lock();
                    s.controls.clear_context();
                    controls::clear_dom();
                }
                s.wallet.account = Some(current);
                s.wallet.chain = Some(chain);
                s.wallet.connected = true;
                update_wallet(&s);
                Ok(())
            }
            .await;
            match result {
                Ok(()) => notice("Wallet connected. Verify deployment to read contract state."),
                Err(code) => {
                    {
                        let mut s = app.borrow_mut();
                        s.wallet.invalidate();
                        s.vault.lock();
                        s.controls.clear_context();
                    }
                    controls::clear_dom();
                    update_wallet(&app.borrow());
                    notice(code);
                }
            }
            busy(&app, false);
        });
    });
    element("connect")
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
}

/// Remove a partial subscription set before attempting another registration.
/// Retain callbacks when a provider refuses removal, then fail connection closed.
fn cleanup_wallet_events(app: &Rc<RefCell<App>>) -> Result<()> {
    let pending = std::mem::take(&mut app.borrow_mut().wallet_listeners);
    let mut retained = Vec::new();
    for listener in pending {
        if !remove_listener(&listener) {
            retained.push(listener);
        }
    }
    app.borrow_mut().wallet_listeners = retained;
    if !app.borrow().wallet_listeners.is_empty() {
        return Err("WALLET_EVENT_CLEANUP_FAILED: reload this page before connecting.");
    }
    Ok(())
}

fn remove_listener(listener: &WalletListener) -> bool {
    listener
        .remove
        .call2(
            &listener.provider,
            &listener.event.into(),
            listener.handler.as_ref().unchecked_ref(),
        )
        .is_ok()
}

fn bind_wallet_events(app: &Rc<RefCell<App>>) -> Result<()> {
    if app.borrow().wallet_events_bound {
        return Ok(());
    }
    cleanup_wallet_events(app)?;
    let p = provider()?;
    let on = Reflect::get(&p, &"on".into())
        .and_then(|v| v.dyn_into::<Function>())
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?;
    // Validate cleanup support before registering any callback.
    let remove = Reflect::get(&p, &"removeListener".into())
        .and_then(|v| v.dyn_into::<Function>())
        .map_err(|_| "WALLET_EVENTS_UNAVAILABLE")?;
    let mut listeners = Vec::new();
    for event in ["accountsChanged", "chainChanged", "disconnect"] {
        let weak_app = Rc::downgrade(app);
        let handler = Closure::<dyn FnMut(JsValue)>::new(move |value| {
            let Some(app) = weak_app.upgrade() else {
                return;
            };
            let changed = {
                let mut s = app.borrow_mut();
                match event {
                    "accountsChanged" => s.wallet.account_changed(account(&value).ok()),
                    "chainChanged" => s
                        .wallet
                        .chain_changed(value.as_string().and_then(|v| quantity(&v).ok())),
                    _ => {
                        s.wallet.invalidate();
                        true
                    }
                }
            };
            if changed {
                {
                    let mut s = app.borrow_mut();
                    s.vault.lock();
                    s.controls.clear_context();
                }
                controls::clear_dom();
                update_wallet(&app.borrow());
                text(
                    "verification",
                    "Previous evidence cleared after wallet context changed.",
                );
                notice(
                    "Wallet context changed. Reconnect the intended account before checking again.",
                );
            }
        });
        listeners.push(WalletListener {
            provider: p.clone(),
            remove: remove.clone(),
            event,
            handler,
        });
    }
    let installed = install_handlers(
        listeners,
        |listener| {
            on.call2(
                &listener.provider,
                &listener.event.into(),
                listener.handler.as_ref().unchecked_ref(),
            )
            .is_ok()
        },
        remove_listener,
    );
    match installed {
        Ok(listeners) => {
            let mut state = app.borrow_mut();
            state.wallet_listeners = listeners;
            state.wallet_events_bound = true;
            Ok(())
        }
        Err(retained) => {
            app.borrow_mut().wallet_listeners = retained;
            Err("WALLET_EVENT_REGISTRATION_FAILED: connection was not accepted; retry or reload this page.")
        }
    }
}
fn bind_refresh(app: Rc<RefCell<App>>) {
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if app.borrow().busy {
            return;
        }
        let (profile, voter, epoch) = {
            let s = app.borrow();
            if !s.wallet.connected {
                notice("Connect the intended wallet account first.");
                return;
            }
            (
                s.profile.clone().unwrap(),
                s.wallet.account.clone().unwrap(),
                s.wallet.epoch,
            )
        };
        let app = app.clone();
        busy(&app, true);
        text("verification", "Checking pinned contract state…");
        notice("Reading the configured RPC. No transaction is sent.");
        spawn_local(async move {
            let result = verification(&profile, &voter).await;
            if app.borrow().wallet.epoch != epoch || !app.borrow().wallet.connected {
                text(
                    "verification",
                    "Evidence discarded because wallet context changed.",
                );
            } else {
                match result {
                    Ok(report) => {
                        text("verification", &report);
                        notice("Read-only deployment and case check passed.");
                    }
                    Err(code) => {
                        text(
                            "verification",
                            "Not verified. No stale result is displayed.",
                        );
                        notice(code);
                    }
                }
            }
            busy(&app, false);
        });
    });
    element("refresh")
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
}
