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
    candidate: Option<ModeratorProfile>,
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
    controls::show_notice(value);
}

pub fn start() -> std::result::Result<(), JsValue> {
    element("app").set_inner_html(include_str!("moderator/view.html"));
    let app = Rc::new(RefCell::new(App::default()));
    let discovery_app = app.clone();
    let _ = crate::wallet::discover(Rc::new(move || controls::render(&discovery_app.borrow())));
    controls::mount(app.clone());
    bind_profile(app.clone());
    controls::install_journey(app.clone());
    bind_wallet_picker(app.clone());
    bind_connect(app.clone());
    bind_refresh(app.clone());
    // Discovery never requests accounts. Subscribe to a chosen provider only
    // when the person explicitly connects it.
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
            "Connect wallet"
        },
    );
    controls::render(app);
}

fn busy(app: &Rc<RefCell<App>>, value: bool) {
    app.borrow_mut().busy = value;
    for id in ["connect", "refresh", "profile", "use-profile"] {
        if value {
            element(id).set_attribute("disabled", "").unwrap();
        } else {
            element(id).remove_attribute("disabled").unwrap();
        }
    }
    controls::set_busy(value);
    controls::render(&app.borrow());
}

fn bind_profile(app: Rc<RefCell<App>>) {
    let accepted = app.clone();
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if app.borrow().busy {
            return;
        }
        let input = element("profile").dyn_into::<HtmlInputElement>().unwrap();
        let Some(file) = input.files().and_then(|files| files.get(0)) else {
            return;
        };
        clear_wallet_guidance();
        // Clear old evidence before reading or validating a replacement file.
        {
            let mut s = app.borrow_mut();
            s.profile = None;
            s.candidate = None;
            s.wallet.invalidate();
            s.vault.lock();
            s.controls.clear_context();
            s.controls.journey_cancelled();
            update_wallet(&s);
        }
        controls::clear_dom();
        text("configuration", "No profile accepted.");
        text("profile-review", "Reading the selected file…");
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
                        "profile-review",
                        &format!(
                            "Chain: {}\nModeration: {}\nRPC: {}\nBee gateway: {}\nToken: {}\nStake registry: {}\nIndex: {}\nGuidelines hash: {}",
                            profile.deployment.chain_id,
                            profile.deployment.moderation.address,
                            redact_url(&profile.rpc_url),
                            redact_url(&profile.gateway_url),
                            profile.deployment.token.address,
                            profile.deployment.stakes.address,
                            profile.deployment.index.address,
                            profile.deployment.guidelines.hash
                        ),
                    );
                    app.borrow_mut().candidate = Some(profile);
                    notice("Profile checked. Compare its deployment with your intended operator, then use it explicitly.");
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
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if accepted.borrow().busy {
            return;
        }
        let Some(profile) = accepted.borrow_mut().candidate.take() else {
            return;
        };
        let report = element("profile-review").text_content().unwrap_or_default();
        accepted.borrow_mut().profile = Some(profile);
        text("configuration", &report);
        notice("Profile accepted. Connect your intended account.");
        controls::render(&accepted.borrow());
        controls::focus_source(if crate::wallet::needs_selection() {
            "wallet-picker"
        } else {
            "connect"
        });
    });
    element("use-profile")
        .add_event_listener_with_callback("click", handler.as_ref().unchecked_ref())
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

fn clear_wallet_guidance() {
    text("wallet-guidance", "");
    let _ = element("wallet-recovery-route").set_attribute("hidden", "");
}
fn show_wallet_guidance(code: &str) -> bool {
    let Some(message) = crate::moderator_view::wallet_guidance(code) else {
        return false;
    };
    text("wallet-guidance", message);
    if code == "WALLET_SELECTION_REQUIRED" {
        let _ = element("wallet-recovery-route").set_attribute("hidden", "");
    } else {
        let _ = element("wallet-recovery-route").remove_attribute("hidden");
    }
    text("notice-source", "");
    true
}

fn choose_wallet(app: &Rc<RefCell<App>>) -> Result<bool> {
    let id = crate::wallet::picker_choice("wallet-picker")?;
    if crate::wallet::selected_id() == Some(id) {
        return Ok(false);
    }
    {
        let mut s = app.borrow_mut();
        s.wallet.invalidate();
        s.wallet.account = None;
        s.wallet.chain = None;
        s.vault.lock();
        s.controls.clear_context();
        s.controls.journey_cancelled();
        s.wallet_events_bound = false;
    }
    controls::clear_dom();
    text("verification", "Not checked for this wallet selection.");
    cleanup_wallet_events(app)?;
    crate::wallet::select(id)?;
    update_wallet(&app.borrow());
    Ok(true)
}
fn bind_wallet_picker(app: Rc<RefCell<App>>) {
    let handler = Closure::<dyn FnMut(web_sys::Event)>::new(move |_| {
        if controls::wallet_selection_locked(&app.borrow()) {
            controls::render(&app.borrow());
            return;
        }
        clear_wallet_guidance();
        match choose_wallet(&app) {
            Ok(true) => notice("Wallet selected. Connect your intended account."),
            Ok(false) => {}
            Err(code) => {
                if !show_wallet_guidance(code) {
                    notice(code);
                }
            }
        }
        update_wallet(&app.borrow());
    });
    element("wallet-picker")
        .add_event_listener_with_callback("change", handler.as_ref().unchecked_ref())
        .unwrap();
    handler.forget();
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
        clear_wallet_guidance();
        if let Err(code) = choose_wallet(&app) {
            if !show_wallet_guidance(code) {
                notice(code);
            }
            update_wallet(&app.borrow());
            controls::focus_source(if code == "WALLET_SELECTION_REQUIRED" {
                "wallet-picker"
            } else {
                "wallet-guidance"
            });
            return;
        }
        busy(&app, true);
        // A provider can be injected after the module starts.
        if let Err(code) = bind_wallet_events(&app) {
            app.borrow_mut().wallet.invalidate();
            update_wallet(&app.borrow());
            text(
                "verification",
                "Not checked: wallet events are not safely registered.",
            );
            if !show_wallet_guidance(code) {
                notice(code);
            }
            busy(&app, false);
            controls::focus_source("wallet-guidance");
            return;
        }
        text("verification", "Not checked for this wallet connection.");
        notice("Waiting for wallet account access…");
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
                    return Err("WALLET_CHAIN_MISMATCH: select the configured network in wallet.");
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
                    if !s.busy {
                        s.controls.journey_cancelled();
                    }
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
                        if !s.busy {
                            s.controls.journey_cancelled();
                        }
                    }
                    controls::clear_dom();
                    update_wallet(&app.borrow());
                    if !show_wallet_guidance(code) {
                        notice(code);
                    }
                }
            }
            busy(&app, false);
            if !element("wallet-guidance")
                .text_content()
                .unwrap_or_default()
                .is_empty()
            {
                controls::focus_source("wallet-guidance");
            }
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
                    if !s.busy {
                        s.controls.journey_cancelled();
                    }
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
                        notice("Deployment verified. Open My work or choose a case from the review queue.");
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
