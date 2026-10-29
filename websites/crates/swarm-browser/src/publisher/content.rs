//! Explicit public content upload/readback and separate-origin inspection.
use super::*;
#[derive(Default)]
pub(super) struct ContentState {
    pub checked: Option<(String, Vec<u8>)>,
    pub viewed: Option<String>,
    pub mismatch: bool,
}
impl ContentState {
    fn failed_upload(&mut self, code: &str, expected: &str, current_raw: Option<&str>) -> bool {
        if code != "UPLOAD_CONTENT_MISMATCH" || current_raw != Some(expected) {
            return false;
        }
        *self = Self {
            mismatch: true,
            ..Self::default()
        };
        true
    }
}
pub(super) fn clear(a: &Rc<RefCell<App>>) {
    a.borrow_mut().content = ContentState::default();
    input("contentack").set_checked(false);
    text(
        "content-feedback",
        "Content inspection has not been checked for this reference and access context.",
    );
}
fn reference() -> Result<String> {
    swarm_core::publisher::normalize_reference(&value("reference")).map_err(|e| e.0)
}
fn viewer() -> Result<(String, String)> {
    let r = reference()?;
    let path = if input("contentcollection").checked() {
        "bzz"
    } else {
        "bytes"
    };
    let origin = web_sys::window()
        .unwrap()
        .location()
        .origin()
        .map_err(|_| "INVALID_LOCATION")?;
    let url = swarm_core::review::separate_content_url(&value("contentgateway"), path, &r, &origin)
        .map_err(|e| e.0)?;
    Ok((url.clone(), format!("{r}|{path}|{url}")))
}
pub(super) fn ready(a: &Rc<RefCell<App>>) -> bool {
    let Ok(r) = reference() else { return false };
    let s = a.borrow();
    !s.content.mismatch
        && input("contentack").checked()
        && (s
            .content
            .checked
            .as_ref()
            .is_some_and(|(saved, _)| *saved == r && !input("contentcollection").checked())
            || viewer().is_ok_and(|(_, key)| s.content.viewed.as_deref() == Some(&key)))
}
pub(super) fn require(a: &Rc<RefCell<App>>) -> Result<()> {
    if ready(a) {
        Ok(())
    } else {
        Err("CONTENT_INSPECTION_REQUIRED")
    }
}
pub(super) fn selected(a: &Rc<RefCell<App>>) {
    clear(a);
    invalidate_review(a);
    let info=input("contentfile").files().and_then(|f|f.get(0)).map(|f|format!("Selected file: {} ({} bytes). Declared type: {}. Selecting it does not upload it or change the current reference. Upload uses your applied Bee settings and publishes these bytes without encryption.",f.name(),f.size(),f.type_())).unwrap_or_else(||"No local content file selected.".into());
    text("content-file-note", &info);
    validation::field("contentfile", None);
}
pub(super) fn apply_bee(a: &Rc<RefCell<App>>) -> Result<()> {
    if a.borrow().profile.is_none() {
        return Err("PROFILE_REQUIRED");
    }
    clear(a);
    invalidate_review(a);
    a.borrow_mut().upload = None;
    let config = setup::upload_config(
        value("beeendpoint").trim(),
        value("beebatch").trim(),
        &value("beeauth"),
    )?;
    a.borrow_mut().upload = Some(config);
    for id in ["beeendpoint", "beebatch", "beeauth"] {
        validation::field(id, None);
    }
    text("content-feedback","Local Bee upload settings applied. They do not change the deployment pins. Check or upload your content again; access credentials remain in memory and are excluded from draft files.");
    Ok(())
}
pub(super) async fn upload(a: &Rc<RefCell<App>>) -> Result<()> {
    if a.borrow().profile.is_none() {
        return Err("PROFILE_REQUIRED");
    }
    let epoch = a.borrow().epoch;
    let config = a.borrow().upload.clone().ok_or("UPLOAD_CONFIG_REQUIRED")?;
    let file = input("contentfile")
        .files()
        .and_then(|f| f.get(0))
        .ok_or("CONTENT_FILE_REQUIRED")?;
    let bytes = setup::file_bytes(&file, swarm_core::review::MAX_REVIEW_BYTES).await?;
    let expected = swarm_core::review::swarm_reference(&bytes).map_err(|e| e.0)?;
    active(a, epoch)?;
    text("content-feedback",&format!("Uploading the selected file as public raw bytes. Expected reference: {expected}. An interrupted response may still have published bytes; no automatic retry is made."));
    if let Err(code) = io::upload_bytes(&config, &bytes, &expected).await {
        active(a, epoch)?;
        let current = reference()
            .ok()
            .filter(|_| !input("contentcollection").checked());
        let invalidated = a
            .borrow_mut()
            .content
            .failed_upload(code, &expected, current.as_deref());
        if invalidated {
            input("contentack").set_checked(false);
            invalidate_review(a);
        }
        let inspection = if invalidated {
            " Earlier inspection and metadata readiness for this reference were cleared. Correct the bytes or access settings and check again before acknowledging."
        } else {
            ""
        };
        text("content-feedback",&format!("The upload/readback did not verify. The current reference has been kept. Expected file reference: {expected}. The server may already have stored data; inspect it before retrying.{inspection} Details: {code}"));
        return Err("CONTENT_UPLOAD_UNVERIFIED");
    }
    active(a, epoch)?;
    invalidate_review(a);
    clear(a);
    input("reference").set_value(&expected);
    input("contentcollection").set_checked(false);
    a.borrow_mut().content.checked = Some((expected.clone(), bytes));
    authoring::save_tab(a);
    validation::refresh(a);
    text("content-feedback",&format!("Content uploaded and exact readback verified: {expected}. The reference now points to that raw file. Inspect your original file or download the checked copy, then acknowledge it. Metadata has not been uploaded and no moderation case was submitted."));
    Ok(())
}
pub(super) async fn check(a: &Rc<RefCell<App>>) -> Result<()> {
    if input("contentcollection").checked() {
        return Err("COLLECTION_VIEWER_REQUIRED");
    }
    let r = reference()?;
    let epoch = a.borrow().epoch;
    let config = a
        .borrow()
        .upload
        .clone()
        .or_else(|| {
            if value("contentgateway").is_empty() {
                None
            } else {
                Some(json!({"endpoint":value("contentgateway")}))
            }
        })
        .ok_or("CONTENT_ENDPOINT_REQUIRED")?;
    input("contentack").set_checked(false);
    a.borrow_mut().content.checked = None;
    let bytes = io::content_bytes(&config, &r).await?;
    active(a, epoch)?;
    if swarm_core::review::verify_reference(&bytes, &r).is_err() {
        a.borrow_mut().content.mismatch = true;
        return Err("CONTENT_REFERENCE_MISMATCH");
    }
    a.borrow_mut().content.mismatch = false;
    a.borrow_mut().content.checked = Some((r, bytes));
    text("content-feedback","Raw content bytes match this reference. That authenticates bytes, not their safety or your metadata's honesty. Inspect a downloaded copy or the separate viewer before acknowledging.");
    Ok(())
}
pub(super) fn download(a: &Rc<RefCell<App>>) -> Result<()> {
    let s = a.borrow();
    let (r, bytes) = s.content.checked.as_ref().ok_or("CONTENT_BYTES_REQUIRED")?;
    if *r != reference()? {
        return Err("CONTENT_INSPECTION_REQUIRED");
    }
    let parts = js_sys::Array::new();
    parts.push(&js_sys::Uint8Array::from(bytes.as_slice()));
    let options = web_sys::BlobPropertyBag::new();
    options.set_type("application/octet-stream");
    let blob = web_sys::Blob::new_with_u8_array_sequence_and_options(&parts, &options)
        .map_err(|_| "EXPORT_FAILED")?;
    let url = web_sys::Url::create_object_url_with_blob(&blob).map_err(|_| "EXPORT_FAILED")?;
    let link = doc()
        .create_element("a")
        .unwrap()
        .dyn_into::<web_sys::HtmlAnchorElement>()
        .unwrap();
    link.set_href(&url);
    link.set_download(&format!("swarm-content-{}.bin", &r[2..10]));
    link.click();
    web_sys::Url::revoke_object_url(&url).map_err(|_| "EXPORT_FAILED")?;
    text("content-feedback","Checked content prepared as an octet-stream download. It has not been rendered inside this publisher. Inspect it with an appropriate viewer and acknowledge the exact content.");
    Ok(())
}
pub(super) fn bind(a: &Rc<RefCell<App>>) -> std::result::Result<(), JsValue> {
    let state = a.clone();
    let open = Closure::<dyn FnMut(web_sys::Event)>::new(move |e: web_sys::Event| {
        if state.borrow().busy {
            e.prevent_default();
            return;
        }
        match viewer() {
            Ok((url, key)) => {
                el("contentviewer").set_attribute("href", &url).unwrap();
                state.borrow_mut().content.viewed = Some(key);
                input("contentack").set_checked(false);
                text("content-feedback","A separate content view was requested for the exact displayed reference. This does not authenticate all file/collection bytes inside the publisher. Inspect what opens, then acknowledge the content. If the browser blocked the view, open the displayed link explicitly.");
                progress::render(&state);
            }
            Err(code) => {
                e.prevent_default();
                text("content-feedback", &help(code));
                validation::action_error("opencontent", code);
            }
        }
    });
    el("contentviewer").add_event_listener_with_callback("click", open.as_ref().unchecked_ref())?;
    open.forget();
    Ok(())
}
pub(super) fn render(a: &Rc<RefCell<App>>) {
    let s = a.borrow();
    let has_ref = reference().is_ok();
    let accessible = s.content.checked.is_some()
        || viewer().is_ok_and(|(_, key)| s.content.viewed.as_deref() == Some(&key));
    for (id, on) in [
        (
            "uploadcontent",
            s.profile.is_some()
                && s.upload.is_some()
                && input("contentfile").files().is_some_and(|f| f.length() > 0),
        ),
        (
            "checkcontent",
            s.profile.is_some() && has_ref && !input("contentcollection").checked(),
        ),
        ("downloadcontent", s.content.checked.is_some()),
        ("contentack", accessible && !s.content.mismatch),
    ] {
        if on && !s.busy {
            el(id).remove_attribute("disabled").unwrap();
        } else {
            el(id).set_attribute("disabled", "").unwrap();
        }
    }
    if let Ok((url, _)) = viewer() {
        el("contentviewer").set_attribute("href", &url).unwrap();
        text("content-view-address", &url);
    } else {
        el("contentviewer").remove_attribute("href").unwrap();
        text("content-view-address","Choose a valid content reference and a gateway on a different origin from this application.");
    }
}
pub(super) fn help(code: &str) -> String {
    let text=match code {
        "FILE_SIZE_LIMIT"|"RESOURCE_TOO_LARGE"=>"The built-in raw-file uploader and byte checker accept at most 256 KiB. Use the linked Swarm upload workflow for a larger file or collection, then paste its reference and inspect it through a separate gateway. This application has not authenticated those larger content bytes.",
        "CONTENT_FILE_REQUIRED"=>"Choose the local file you intend to publish. Selecting a file alone does not upload it.",
        "CONTENT_REFERENCE_MISMATCH"=>"The fetched bytes do not match this reference. Content acknowledgement is blocked. Correct the reference or Bee settings and check again; do not treat these bytes as the intended content.",
        "COLLECTION_VIEWER_REQUIRED"=>"The byte checker only checks raw references. For a file or collection uploaded through /bzz, use the separate viewer and inspect its root/default document. No inner collection path is selected by this form.",
        "SEPARATE_CONTENT_ORIGIN_REQUIRED"=>"Use a gateway with a different origin from this publisher before opening content. Active content must not share the publisher's origin.",
        "CONTENT_BYTES_REQUIRED"=>"Check raw content bytes or complete a verified raw upload before downloading a checked copy.",
        "CONTENT_INSPECTION_REQUIRED"=>"Inspect the current content using a checked copy, original uploaded file or separate viewer, then acknowledge it. Changes to reference, gateway or access settings clear this step.",
        "CONTENT_ENDPOINT_REQUIRED"=>"Apply your Bee settings or enter the separate content gateway before checking a raw reference.",
        _=>"The content action did not complete. Keep your existing reference and text. Check the selected file, reference and Bee/gateway settings before trying again.",
    };
    format!("{text}\nDetails: {code}")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn inspected() -> ContentState {
        ContentState {
            checked: Some(("current".into(), vec![1])),
            viewed: Some("view".into()),
            mismatch: false,
        }
    }
    #[test]
    fn same_reference_upload_mismatch_revokes_prior_inspection() {
        let mut state = inspected();
        assert!(state.failed_upload("UPLOAD_CONTENT_MISMATCH", "current", Some("current")));
        assert!(state.mismatch);
        assert!(state.checked.is_none());
        assert!(state.viewed.is_none());
    }
    #[test]
    fn unrelated_or_uncertain_upload_failure_keeps_current_content() {
        for (code, expected, current) in [
            ("UPLOAD_CONTENT_MISMATCH", "different", Some("current")),
            ("RESOURCE_READ_FAILED", "current", Some("current")),
            ("UPLOAD_CONTENT_MISMATCH", "current", None),
        ] {
            let mut state = inspected();
            assert!(!state.failed_upload(code, expected, current));
            assert!(!state.mismatch);
            assert!(state.checked.is_some());
            assert!(state.viewed.is_some());
        }
    }
}
