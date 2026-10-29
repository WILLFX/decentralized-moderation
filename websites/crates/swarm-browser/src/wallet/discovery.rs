//! Page-local wallet discovery. Discovery never requests accounts or signs.
//! Requests use the selected object, never a later window.ethereum replacement.
use crate::BrowserResult as Result;
use js_sys::{Object, Reflect};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::{closure::Closure, JsCast, JsValue};
use web_sys::{Event, HtmlSelectElement};

const MAX_PROVIDERS: usize = 16;
struct Entry {
    id: u32,
    uuid: Option<String>,
    label: String,
    rdns: String,
    provider: JsValue,
}
#[derive(Default)]
struct Registry {
    entries: Vec<Entry>,
    next: u32,
    selected: Option<u32>,
    listening: bool,
}
thread_local! {
    static REGISTRY: RefCell<Registry> = RefCell::new(Registry::default());
}

fn property(value: &JsValue, name: &str) -> Option<String> {
    Reflect::get(value, &name.into()).ok()?.as_string()
}
fn valid_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                *c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
        && b[14] == b'4'
        && matches!(b[19].to_ascii_lowercase(), b'8' | b'9' | b'a' | b'b')
}
fn canonical_uuid(s: &str) -> Option<String> {
    valid_uuid(s).then(|| s.to_ascii_lowercase())
}
fn label(s: &str) -> String {
    s.chars()
        .filter(|c| {
            !c.is_control() && !matches!(*c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(80)
        .collect::<String>()
        .trim()
        .to_owned()
}
fn capable(p: &JsValue) -> bool {
    !p.is_null()
        && !p.is_undefined()
        && Reflect::get(p, &"request".into())
            .ok()
            .is_some_and(|f| f.is_function())
}
fn preferred(selected: Option<u32>, ids: &[u32]) -> Option<u32> {
    match selected {
        Some(id) => ids.contains(&id).then_some(id),
        None => (ids.len() == 1).then(|| ids[0]),
    }
}

fn announce(event: &Event) -> bool {
    let Ok(detail) = Reflect::get(event.as_ref(), &"detail".into()) else {
        return false;
    };
    let Ok(info) = Reflect::get(&detail, &"info".into()) else {
        return false;
    };
    let Some(uuid) = property(&info, "uuid").and_then(|s| canonical_uuid(&s)) else {
        return false;
    };
    let Some(name) = property(&info, "name")
        .map(|s| label(&s))
        .filter(|s| !s.is_empty())
    else {
        return false;
    };
    let Some(rdns) = property(&info, "rdns")
        .map(|s| label(&s))
        .filter(|s| !s.is_empty())
    else {
        return false;
    };
    let Ok(provider) = Reflect::get(&detail, &"provider".into()) else {
        return false;
    };
    if !capable(&provider) {
        return false;
    }
    // Names and rdns are self-reported. Render plain text only, without icons,
    // URLs or HTML. Neither a name nor a UUID authenticates a wallet.
    let display = name;
    REGISTRY.with(|cell| {
        let mut r = cell.borrow_mut();
        if r.entries.iter().any(|e| {
            e.uuid.as_deref() == Some(uuid.as_str()) && !Object::is(&e.provider, &provider)
        }) {
            return false;
        }
        if let Some(index) = r
            .entries
            .iter()
            .position(|e| Object::is(&e.provider, &provider))
        {
            let selected = r.selected;
            let e = &mut r.entries[index];
            if e.uuid.is_some() {
                return false;
            }
            e.uuid = Some(uuid);
            if selected != Some(e.id) {
                e.label = display;
                e.rdns = rdns;
            }
            return true;
        }
        if r.entries
            .iter()
            .any(|e| e.uuid.as_deref() == Some(uuid.as_str()))
            || r.entries.len() >= MAX_PROVIDERS
        {
            return false;
        }
        r.next += 1;
        let id = r.next;
        r.entries.push(Entry {
            id,
            uuid: Some(uuid),
            label: display,
            rdns,
            provider,
        });
        true
    })
}

fn legacy() {
    // Once selected, no subsequent default-provider lookup can change a session.
    if REGISTRY.with(|r| {
        r.borrow().selected.is_some() || r.borrow().entries.iter().any(|e| e.uuid.is_some())
    }) {
        return;
    }
    let Some(window) = web_sys::window() else {
        return;
    };
    let Ok(p) = Reflect::get(window.as_ref(), &"ethereum".into()) else {
        return;
    };
    REGISTRY.with(|cell| {
        let mut r = cell.borrow_mut();
        if r.entries.iter().any(|e| Object::is(&e.provider, &p)) {
            return;
        }
        r.entries.clear();
        if p.is_null() || p.is_undefined() {
            return;
        }
        r.next += 1;
        let id = r.next;
        r.entries.push(Entry {
            id,
            uuid: None,
            label: "Browser wallet".into(),
            rdns: String::new(),
            provider: p,
        });
    });
}

pub(crate) fn discover(changed: Rc<dyn Fn()>) -> Result<()> {
    if REGISTRY.with(|r| r.borrow().listening) {
        return Ok(());
    }
    let window = web_sys::window().ok_or("WALLET_UNAVAILABLE")?;
    let listener = Closure::<dyn FnMut(Event)>::new(move |event: Event| {
        if announce(&event) {
            changed();
        }
    });
    window
        .add_event_listener_with_callback(
            "eip6963:announceProvider",
            listener.as_ref().unchecked_ref(),
        )
        .map_err(|_| "WALLET_DISCOVERY_FAILED")?;
    // The discovery subscription lives for this page's lifetime. It does not
    // replace the per-selected-wallet subscriptions owned by either controller.
    listener.forget();
    REGISTRY.with(|r| r.borrow_mut().listening = true);
    window
        .dispatch_event(
            &Event::new("eip6963:requestProvider").map_err(|_| "WALLET_DISCOVERY_FAILED")?,
        )
        .map_err(|_| "WALLET_DISCOVERY_FAILED")?;
    Ok(())
}

pub(crate) fn render_picker(id: &str, locked: bool) {
    legacy();
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(element) = document.get_element_by_id(id) else {
        return;
    };
    let Ok(select) = element.dyn_into::<HtmlSelectElement>() else {
        return;
    };
    let (items, chosen) = REGISTRY.with(|cell| {
        let r = cell.borrow();
        // An explicitly selected legacy wallet stays available if another wallet
        // announces later. Unselected legacy fallbacks do not duplicate discovery.
        let announced = r.entries.iter().any(|e| e.uuid.is_some());
        let items: Vec<_> = r
            .entries
            .iter()
            .filter(|e| !announced || e.uuid.is_some() || r.selected == Some(e.id))
            .map(|e| {
                let duplicate = r
                    .entries
                    .iter()
                    .filter(|other| other.label == e.label)
                    .count()
                    > 1;
                let name = if duplicate && !e.rdns.is_empty() {
                    format!("{} ({})", e.label, e.rdns)
                } else {
                    e.label.clone()
                };
                (e.id, name)
            })
            .collect();
        let chosen = preferred(
            r.selected,
            &items.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
        );
        (items, chosen)
    });
    select.set_text_content(None);
    let Ok(placeholder) = document.create_element("option") else {
        return;
    };
    let _ = placeholder.set_attribute("value", "");
    placeholder.set_text_content(Some(if items.is_empty() {
        "No browser wallet found"
    } else {
        "Choose a wallet"
    }));
    let _ = select.append_child(&placeholder);
    for (key, name) in &items {
        let Ok(option) = document.create_element("option") else {
            continue;
        };
        let _ = option.set_attribute("value", &key.to_string());
        option.set_text_content(Some(name));
        let _ = select.append_child(&option);
    }
    select.set_value(&chosen.map(|v| v.to_string()).unwrap_or_default());
    select.set_disabled(locked || items.is_empty());
}

pub(crate) fn picker_choice(id: &str) -> Result<u32> {
    legacy();
    let value = web_sys::window()
        .and_then(|w| w.document())
        .and_then(|d| d.get_element_by_id(id))
        .and_then(|e| e.dyn_into::<HtmlSelectElement>().ok())
        .map(|e| e.value())
        .unwrap_or_default();
    let parsed = value.parse::<u32>().ok();
    REGISTRY.with(|cell| {
        let r = cell.borrow();
        if r.entries.is_empty() {
            return Err("WALLET_UNAVAILABLE");
        }
        parsed
            .filter(|id| r.entries.iter().any(|e| e.id == *id))
            .or_else(|| (r.entries.len() == 1).then(|| r.entries[0].id))
            .ok_or("WALLET_SELECTION_REQUIRED")
    })
}
pub(crate) fn needs_selection() -> bool {
    REGISTRY.with(|cell| {
        let r = cell.borrow();
        r.selected.is_none() && r.entries.iter().filter(|e| e.uuid.is_some()).count() > 1
    })
}
pub(crate) fn selected_id() -> Option<u32> {
    REGISTRY.with(|r| r.borrow().selected)
}
/// Controllers must invalidate readiness and clean up old subscriptions first.
pub(crate) fn select(id: u32) -> Result<()> {
    let provider = REGISTRY
        .with(|cell| {
            cell.borrow()
                .entries
                .iter()
                .find(|e| e.id == id)
                .map(|e| e.provider.clone())
        })
        .ok_or("WALLET_SELECTION_REQUIRED")?;
    // Wallet getters are untrusted JavaScript; never invoke them under a registry borrow.
    if !capable(&provider) {
        return Err("WALLET_PROVIDER_UNSUPPORTED");
    }
    REGISTRY.with(|cell| {
        let mut r = cell.borrow_mut();
        if !r
            .entries
            .iter()
            .any(|e| e.id == id && Object::is(&e.provider, &provider))
        {
            return Err("WALLET_SELECTION_REQUIRED");
        }
        r.selected = Some(id);
        Ok(())
    })
}
pub(crate) fn provider() -> Result<JsValue> {
    REGISTRY.with(|cell| {
        let r = cell.borrow();
        r.selected
            .and_then(|id| r.entries.iter().find(|e| e.id == id))
            .map(|e| e.provider.clone())
            .ok_or("WALLET_SELECTION_REQUIRED")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn multiple_wallets_need_a_choice_and_discovery_never_overrides_selection() {
        assert_eq!(preferred(None, &[]), None);
        assert_eq!(preferred(None, &[1]), Some(1));
        assert_eq!(preferred(None, &[1, 2]), None);
        assert_eq!(preferred(Some(2), &[1, 2, 3]), Some(2));
        assert_eq!(preferred(Some(9), &[1, 2]), None);
    }
    #[test]
    fn discovery_metadata_is_bounded_text_and_uuids_are_v4() {
        assert!(valid_uuid("11111111-1111-4111-8111-111111111111"));
        assert_eq!(
            canonical_uuid("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            Some("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".into())
        );
        for bad in [
            "",
            "11111111-1111-1111-8111-111111111111",
            "11111111-1111-4111-7111-111111111111",
            "<script>",
        ] {
            assert!(!valid_uuid(bad));
        }
        assert_eq!(label("  Name\n\u{202e}  "), "Name");
        assert_eq!(label(&"é".repeat(100)).chars().count(), 80);
    }
}
