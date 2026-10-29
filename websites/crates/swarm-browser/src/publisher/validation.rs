//! Field errors stay beside unmodified authoring text; core rules remain shared.
use super::*;
const IDS: &[&str] = &[
    "reference",
    "entrytype",
    "title",
    "description",
    "topics",
    "language",
    "contenttype",
    "source",
];
// Preserve unsupported imported text visibly, without making it a valid category.
pub(super) fn restore_category(value: &str) {
    if let Some(old) = doc().get_element_by_id("saved-category") {
        old.remove();
    }
    let select = el("entrytype")
        .dyn_into::<web_sys::HtmlSelectElement>()
        .unwrap();
    select.set_value(value);
    if select.value() != value || value.is_empty() {
        let option = doc().create_element("option").unwrap();
        option.set_id("saved-category");
        option.set_attribute("value", value).unwrap();
        option.set_attribute("disabled", "").unwrap();
        option.set_text_content(Some(&format!("Unrecognized saved category: {value}")));
        select.append_child(&option).unwrap();
        select.set_value(value);
    }
}
pub(super) fn apply_format(a: &Rc<RefCell<App>>) -> Result<()> {
    let format = value("mimechoice");
    if format.is_empty() {
        return Err("MIME_FORMAT_REQUIRED");
    }
    invalidate_review(a);
    input("contenttype").set_value(&format);
    field("contenttype", None);
    authoring::save_tab(a);
    refresh(a);
    text("notice", "Content type changed by your selection. Preview exact metadata and repeat its review and upload before payment.");
    Ok(())
}
pub(super) fn message(code: &str) -> &'static str {
    match code {
        "REFERENCE"=>"Enter the nonzero 64 hexadecimal digits of the content reference, optionally starting with 0x. Paste the reference, not a gateway URL, filename or encrypted 128-digit reference.",
        "TYPE"=>"Choose article, post, comment, image, video, audio, document, dataset or other.",
        "TITLE"=>"Enter a title of 1 to 200 Unicode characters.",
        "DESCRIPTION"=>"Shorten the description to 5000 Unicode characters or fewer.",
        "TOPIC_COUNT"=>"Enter one to five nonempty topics, one per line. Blank lines are ignored.",
        "TOPIC_LENGTH"=>"Each topic must have 1 to 64 Unicode characters after case and spacing normalization.",
        "DUPLICATE_TOPICS"=>"Remove duplicate topics. Case, Unicode normalization and extra spacing can make two topics identical.",
        "LANGUAGE"=>"Leave language empty, or use a code such as en or en-US. Use a 2–3-letter first part and 2–8-letter/digit later parts, within 35 characters.",
        "CONTENT_TYPE"=>"Enter a lowercase media type such as text/plain or image/png, up to 255 characters. Parameters need a nonempty name=value without spaces inside it.",
        "SOURCE"=>"Shorten source to 2048 Unicode characters or fewer. This optional value is your declaration, not independently verified evidence.",
        "METADATA_SIZE"=>"The combined metadata is too large. Shorten its fields to fit the 256 KiB metadata limit.",
        _=>"Check this field before continuing.",
    }
}
fn label(id: &str) -> &str {
    match id {
        "entrytype" => "Type",
        "contenttype" => "Content type",
        _ => id,
    }
}
pub(super) fn refresh(a: &Rc<RefCell<App>>) {
    let shown = a.borrow().validation_shown;
    if shown {
        check(a, false);
    }
}
pub(super) fn field(id: &str, error: Option<&str>) {
    text(&format!("{id}-error"), error.unwrap_or(""));
    if error.is_some() {
        el(id).set_attribute("aria-invalid", "true").unwrap();
    } else {
        el(id).remove_attribute("aria-invalid").unwrap();
    }
}
pub(super) fn focus_first() {
    for id in IDS {
        if el(id).get_attribute("aria-invalid").as_deref() == Some("true") {
            journey::open_ancestors(&el(id));
            let _ = el(id).dyn_into::<web_sys::HtmlElement>().unwrap().focus();
            break;
        }
    }
}
pub(super) fn check(a: &Rc<RefCell<App>>, focus: bool) -> bool {
    a.borrow_mut().validation_shown = true;
    let mut fields = authoring_fields();
    for topic in &mut fields.topics {
        *topic = js_sys::JsString::from(topic.as_str())
            .normalize("NFC")
            .to_lower_case()
            .normalize("NFC")
            .as_string()
            .unwrap_or_default();
    }
    let mut issues = fields.field_issues();
    if swarm_core::publisher::normalize_reference(&value("reference")).is_err() {
        issues.insert(
            0,
            swarm_core::review::FieldIssue {
                field: "reference",
                code: "REFERENCE",
            },
        );
    }
    for id in IDS {
        let messages = issues
            .iter()
            .filter(|e| e.field == *id)
            .map(|e| message(e.code))
            .collect::<Vec<_>>()
            .join(" ");
        field(
            id,
            if messages.is_empty() {
                None
            } else {
                Some(&messages)
            },
        );
    }
    let summary = el("field-summary");
    summary.set_text_content(None);
    if !issues.is_empty() {
        let heading = doc().create_element("p").unwrap();
        heading.set_text_content(Some(
            "Correct the highlighted fields. Your entered text has been kept.",
        ));
        summary.append_child(&heading).unwrap();
        let list = doc().create_element("ul").unwrap();
        for id in IDS
            .iter()
            .filter(|id| issues.iter().any(|e| e.field == **id))
        {
            let li = doc().create_element("li").unwrap();
            let link = doc().create_element("a").unwrap();
            link.set_attribute("href", &format!("#{id}")).unwrap();
            link.set_text_content(Some(label(id)));
            li.append_child(&link).unwrap();
            list.append_child(&li).unwrap();
        }
        summary.append_child(&list).unwrap();
        if focus {
            let _ = el(issues[0].field)
                .dyn_into::<web_sys::HtmlElement>()
                .unwrap()
                .focus();
        }
    }
    issues.is_empty()
}
pub(super) fn fee(a: &Rc<RefCell<App>>) {
    let s = a.borrow();
    let Some(p) = &s.profile else {
        field("fee", None);
        return;
    };
    if value("fee").is_empty() {
        field("fee", None);
        return;
    }
    let error=match crate::token_amounts::parse(&value("fee"),p.display.as_ref()) {
        Err("FEE_OVERFLOW")=>Some("The fee exceeds the contract's 128-bit amount limit. Enter a smaller value; no rounding or truncation is applied.".to_string()),
        Err(_)=>Some(p.display.as_ref().map(|d|format!("Enter a nonnegative decimal with at most {} fractional digits. Do not use commas or exponents.",d.decimals)).unwrap_or_else(||"Enter a nonnegative integer number of base units. This profile supplies no decimal display settings.".into())),
        Ok(n) if s.funding.as_ref().is_some_and(|f|n<f.minimum)=>Some("The fee is below the current minimum. Choose the minimum or enter a higher fee.".into()),
        _=>None,
    };
    field("fee", error.as_deref());
}
pub(super) fn action_error(action: &str, code: &str) {
    let (id,help)=match code {
        "FILE_SIZE_LIMIT" if action=="profile" =>("profile","Choose a publisher profile no larger than 64 KiB. No replacement was accepted."),
        "PROFILE_FINGERPRINT_REQUIRED"=>("profilepin","Enter the expected 64-digit Keccak-256 fingerprint from the trusted deployment source before loading a URL."),
        "PROFILE_FINGERPRINT_MISMATCH"=>("profilepin","These profile bytes do not match the expected fingerprint. No profile was accepted. Check the source and expected fingerprint; do not accept a replacement hash from an untrusted response."),
        "PUBLIC_PROFILE_URL_REQUIRED"|"INVALID_ACCESS_URL" if action=="fetchprofile"=>("profileurl","Use a public HTTPS profile URL, or loopback HTTP for your own local service. Credentials, query strings and fragments are not accepted here."),
        "INVALID_BATCH" if action=="profile"||action=="fetchprofile" =>(if action=="fetchprofile"{"profileurl"}else{"profile"},"This profile contains an invalid postage batch. Obtain a corrected profile or one without upload settings, then apply your own Bee settings after review."),
        "INVALID_BATCH"=>("beebatch","Enter a nonzero 64-digit postage batch ID from your Bee node. Do not enter a URL or a transaction hash."),
        "INVALID_UPLOAD_AUTHORIZATION"=>("beeauth","Use a single-line authorization value or leave it empty. This local access setting is never saved into authoring files."),
        "INVALID_GATEWAY_URL"|"INVALID_ACCESS_URL" if action=="applybee"=>("beeendpoint","Enter your Bee API base URL: HTTPS, or loopback HTTP. Do not include credentials, a query, or a /bytes/reference suffix."),
        "SEPARATE_CONTENT_ORIGIN_REQUIRED"=>("contentgateway","Choose a gateway with a different scheme/host/port origin from this publisher."),
        "INVALID_ACCESS_URL"|"INVALID_GATEWAY_URL"|"CONTENT_ENDPOINT_REQUIRED" if action=="opencontent"||action=="checkcontent" =>("contentgateway","Enter a content gateway base URL using HTTPS, or loopback HTTP. Do not include credentials, a query or a fragment. Opening content also requires a different origin from this publisher."),
        "MIME_FORMAT_REQUIRED"=>("contenttype","Choose a common file format above, then apply it. You can also enter its MIME type here."),
        "FILE_SIZE_LIMIT"|"CONTENT_FILE_REQUIRED"=>("contentfile","Choose an unencrypted raw file no larger than 256 KiB for this uploader. Larger files and collections use the linked external upload workflow."),
        "INVALID_REFERENCE"=>("reference",message("REFERENCE")),
        "INVALID_CONFIG"|"CONFIG_TOO_LARGE"|"PUBLIC_PROFILE_CONTAINS_ACCESS_SETTINGS"=>(if action=="fetchprofile"{"profileurl"}else{"profile"},"This is not an acceptable publisher profile for this route. Check the selected source. Private upload authorization or RPC query settings belong in a local file, not a fetched public setup profile."),
        _=>return,
    };
    field(id, Some(help));
    journey::open_ancestors(&el(id));
    let _ = el(id).dyn_into::<web_sys::HtmlElement>().unwrap().focus();
}
