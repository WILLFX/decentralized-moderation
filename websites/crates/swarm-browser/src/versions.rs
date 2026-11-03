//! A choice from a reviewed profile; never follows an unpinned active address.
use swarm_core::Deployment;
use wasm_bindgen::JsCast;
fn element(id: &str) -> web_sys::Element {
    web_sys::window()
        .unwrap()
        .document()
        .unwrap()
        .get_element_by_id(id)
        .unwrap()
}
pub(crate) fn choice() -> String {
    element("profile-version")
        .unchecked_into::<web_sys::HtmlSelectElement>()
        .value()
}
pub(crate) fn populate(d: &Deployment) {
    let wrapper = element("version-settings");
    let select = element("profile-version");
    select.set_text_content(None);
    element("version-status").set_text_content(None);
    let Some(p) = &d.persistent else {
        let _ = wrapper.set_attribute("hidden", "");
        return;
    };
    let _ = wrapper.remove_attribute("hidden");
    for v in &p.versions {
        let option = select
            .owner_document()
            .unwrap()
            .create_element("option")
            .unwrap();
        option
            .set_attribute("value", &v.moderation.address)
            .unwrap();
        option.set_text_content(Some(&format!(
            "{} · guidelines v{}",
            v.moderation.address, v.guidelines.version
        )));
        select.append_child(&option).unwrap();
    }
    let selected = p
        .versions
        .iter()
        .find(|v| {
            v.moderation
                .address
                .eq_ignore_ascii_case(&d.moderation.address)
        })
        .expect("validated selected version");
    select
        .unchecked_into::<web_sys::HtmlSelectElement>()
        .set_value(&selected.moderation.address);
}
pub(crate) fn locked(locked: bool) {
    let s = element("profile-version").unchecked_into::<web_sys::HtmlSelectElement>();
    s.set_disabled(locked);
}
pub(crate) fn active(address: &str) {
    element("version-status").set_text_content(Some(&format!(
        "Active for new cases at the last check: {address}"
    )));
}

pub(crate) fn clear() {
    let _ = element("version-settings").set_attribute("hidden", "");
    element("profile-version").set_text_content(None);
    element("version-status").set_text_content(None);
}

pub(crate) fn purpose(purpose: Option<swarm_core::ProfilePurpose>) {
    let node = element("profile-purpose");
    if purpose == Some(swarm_core::ProfilePurpose::ExistingWork) {
        let _ = node.remove_attribute("hidden");
        node.set_text_content(Some("Profile: existing work only"));
    } else {
        let _ = node.set_attribute("hidden", "");
        node.set_text_content(None);
    }
}
