//! A supplied setup link is a trust input, never an automatic configuration.
use super::*;
use serde::Deserialize;
pub(super) const LIMIT: usize = 64 * 1024;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Shape {
    deployment: swarm_core::Deployment,
    rpc_url: String,
    #[serde(default)]
    guidelines_url: Option<String>,
    #[serde(default)]
    display: Option<swarm_core::Display>,
    #[serde(default)]
    upload: Option<Upload>,
    #[serde(default)]
    content_gateway_url: Option<String>,
    #[serde(default)]
    content_path: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Upload {
    endpoint: String,
    postage_batch_id: String,
    #[serde(default)]
    authorization: Option<String>,
}
pub(super) struct Candidate {
    pub profile: ModeratorProfile,
    pub upload: Option<Value>,
    pub gateway: Option<String>,
    pub fingerprint: String,
    pub source: Option<String>,
}
pub(super) fn upload_config(endpoint: &str, batch: &str, auth: &str) -> Result<Value> {
    swarm_core::review::resource_url(endpoint, "bytes", &format!("0x{}", "11".repeat(32)))
        .map_err(|e| e.0)?;
    if batch.len() != 64
        || !batch.bytes().all(|b| b.is_ascii_hexdigit())
        || batch.bytes().all(|b| b == b'0')
    {
        return Err("INVALID_BATCH");
    }
    if auth.len() > 8192 || auth.chars().any(|c| c.is_control()) {
        return Err("INVALID_UPLOAD_AUTHORIZATION");
    }
    let mut value = json!({"endpoint":endpoint,"postageBatchId":batch});
    if !auth.is_empty() {
        value["authorization"] = json!(auth);
    }
    Ok(value)
}
pub(super) fn parse(raw: &[u8]) -> Result<Candidate> {
    if raw.len() > LIMIT {
        return Err("CONFIG_TOO_LARGE");
    }
    let shape: Shape = serde_json::from_slice(raw).map_err(|_| "INVALID_CONFIG")?;
    let gateway = shape.content_gateway_url;
    if let Some(g) = &gateway {
        swarm_core::review::resource_url(g, "bytes", &format!("0x{}", "11".repeat(32)))
            .map_err(|e| e.0)?;
    }
    let upload = shape
        .upload
        .map(|u| {
            upload_config(
                &u.endpoint,
                &u.postage_batch_id,
                u.authorization.as_deref().unwrap_or(""),
            )
        })
        .transpose()?;
    let p = ModeratorProfile {
        deployment: shape.deployment,
        rpc_url: shape.rpc_url,
        gateway_url: gateway
            .clone()
            .unwrap_or_else(|| "http://127.0.0.1/".into()),
        metadata_path: "bytes".into(),
        content_path: shape.content_path.unwrap_or_else(|| "bytes".into()),
        guidelines_url: shape
            .guidelines_url
            .unwrap_or_else(|| "./MODERATION_GUIDELINES.md".into()),
        timing: swarm_core::Timing {
            clock_error_seconds: 5,
            max_evidence_age_seconds: 30,
            max_head_lag_seconds: 30,
            inclusion_budget_seconds: 120,
        },
        display: shape.display,
    };
    let profile =
        swarm_core::parse_profile(&serde_json::to_string(&p).map_err(|_| "INVALID_CONFIG")?)
            .map_err(|e| e.0)?;
    Ok(Candidate {
        profile,
        upload,
        gateway,
        fingerprint: swarm_core::keccak256_hex(raw),
        source: None,
    })
}
pub(super) fn public_url(raw: &str) -> Result<String> {
    let safe = swarm_core::access_url(raw).map_err(|e| e.0)?;
    if web_url_has_query(&safe) {
        return Err("PUBLIC_PROFILE_URL_REQUIRED");
    }
    Ok(safe)
}
fn web_url_has_query(s: &str) -> bool {
    s.contains('?')
}
pub(super) fn fingerprint_matches(raw: &[u8], expected: &str) -> Result<()> {
    let expected = swarm_core::publisher::normalize_reference(expected.trim())
        .map_err(|_| "PROFILE_FINGERPRINT_REQUIRED")?;
    if swarm_core::keccak256_hex(raw) != expected {
        return Err("PROFILE_FINGERPRINT_MISMATCH");
    }
    Ok(())
}
pub(super) async fn file_bytes(file: &web_sys::File, limit: usize) -> Result<Vec<u8>> {
    if file.size() > limit as f64 {
        return Err("FILE_SIZE_LIMIT");
    }
    let data = JsFuture::from(file.array_buffer())
        .await
        .map_err(|_| "FILE_READ_FAILED")?;
    let bytes = js_sys::Uint8Array::new(&data).to_vec();
    if bytes.len() > limit {
        return Err("FILE_SIZE_LIMIT");
    }
    Ok(bytes)
}
pub(super) fn clear(a: &Rc<RefCell<App>>) {
    invalidate(a);
    let mut s = a.borrow_mut();
    s.profile = None;
    s.upload = None;
    s.account = None;
    s.setup_candidate = None;
    input("fee").set_value("");
    input("trustprofile").set_checked(false);
    for id in ["beeendpoint", "beebatch", "beeauth", "contentgateway"] {
        input(id).set_value("");
    }
    text(
        "config",
        "No profile is active. Review and accept the candidate before connecting a wallet.",
    );
    text("profile-review", "");
    text("setup-link", "");
    text("wallet", "Not connected.");
}
pub(super) async fn load(a: &Rc<RefCell<App>>, remote: bool) -> Result<()> {
    clear(a);
    let epoch = a.borrow().epoch;
    if remote && swarm_core::publisher::normalize_reference(value("profilepin").trim()).is_err() {
        return Err("PROFILE_FINGERPRINT_REQUIRED");
    }
    let source = if remote {
        Some(public_url(&value("profileurl"))?)
    } else {
        None
    };
    let raw = if let Some(url) = &source {
        crate::transport::fetch(url, &web_sys::RequestInit::new(), LIMIT).await?
    } else {
        let file = input("profile")
            .files()
            .and_then(|f| f.get(0))
            .ok_or("PROFILE_REQUIRED")?;
        file_bytes(&file, LIMIT).await?
    };
    active(a, epoch)?;
    if remote || !value("profilepin").trim().is_empty() {
        fingerprint_matches(&raw, &value("profilepin"))?;
    }
    let mut candidate = parse(&raw)?;
    if remote
        && (candidate
            .upload
            .as_ref()
            .is_some_and(|u| u.get("authorization").is_some())
            || candidate.profile.rpc_url.contains('?'))
    {
        return Err("PUBLIC_PROFILE_CONTAINS_ACCESS_SETTINGS");
    }
    candidate.source = source;
    for id in ["profile", "profileurl", "profilepin"] {
        validation::field(id, None);
    }
    let d = &candidate.profile.deployment;
    let origin = web_sys::Url::new(&candidate.profile.rpc_url)
        .map_err(|_| "INVALID_ACCESS_URL")?
        .origin();
    text("profile-review",&format!("Candidate only — not active\n{}\nModeration: {}\nToken: {}\nStakes: {}\nIndex: {}\nPinned guidelines: version {}, {}\nRPC origin: {origin}\nExact profile fingerprint (Keccak-256): {}\nCompare these with the deployment announcement you trust. A matching file does not identify its operator. No wallet request has been made.",progress::network(d.chain_id),d.moderation.address,d.token.address,d.stakes.address,d.index.address,d.guidelines.version,d.guidelines.hash,candidate.fingerprint));
    a.borrow_mut().setup_candidate = Some(candidate);
    text("notice","Profile candidate loaded. Compare its chain, addresses and fingerprint with your trusted source, then accept it.");
    Ok(())
}
pub(super) fn accept(a: &Rc<RefCell<App>>) -> Result<()> {
    if !input("trustprofile").checked() {
        return Err("PROFILE_TRUST_ACK_REQUIRED");
    }
    let candidate = a
        .borrow_mut()
        .setup_candidate
        .take()
        .ok_or("PROFILE_CANDIDATE_REQUIRED")?;
    input("contentgateway").set_value(candidate.gateway.as_deref().unwrap_or(""));
    input("contentcollection").set_checked(candidate.profile.content_path == "bzz");
    let upload = candidate.upload;
    for id in ["beeendpoint", "beebatch", "beeauth"] {
        validation::field(id, None);
    }
    input("beeendpoint").set_value(
        upload
            .as_ref()
            .and_then(|u| u["endpoint"].as_str())
            .unwrap_or(""),
    );
    input("beebatch").set_value(
        upload
            .as_ref()
            .and_then(|u| u["postageBatchId"].as_str())
            .unwrap_or(""),
    );
    input("beeauth").set_value(
        upload
            .as_ref()
            .and_then(|u| u["authorization"].as_str())
            .unwrap_or(""),
    );
    if let Some(source) = candidate.source {
        let url = web_sys::Url::new(
            &web_sys::window()
                .unwrap()
                .location()
                .href()
                .map_err(|_| "INVALID_LOCATION")?,
        )
        .map_err(|_| "INVALID_LOCATION")?;
        url.set_search("");
        url.set_hash(&format!(
            "profile={}&profileHash={}",
            js_sys::encode_uri_component(&source),
            candidate.fingerprint
        ));
        text(
            "setup-link",
            &format!("Setup link for this exact public profile: {}", url.href()),
        );
    }
    let mut s = a.borrow_mut();
    s.profile = Some(candidate.profile);
    s.upload = upload;
    text("profile-review","The reviewed profile is active. Runtime, linkage and wallet checks still run before payment; accepting this file did not connect or submit.");
    text(
        "notice",
        "Profile accepted. Connect the intended wallet, then check your Bee settings and content. Reconnecting clears inspection and metadata readiness.",
    );
    Ok(())
}
pub(super) fn seed_link(a: &Rc<RefCell<App>>) {
    let hash = web_sys::window()
        .unwrap()
        .location()
        .hash()
        .unwrap_or_default();
    if let Ok(params) = web_sys::UrlSearchParams::new_with_str(hash.trim_start_matches('#')) {
        if let (Some(url), Some(pin)) = (params.get("profile"), params.get("profileHash")) {
            if !url.is_empty() && !pin.is_empty() && url.len() <= 4096 && pin.len() <= 66 {
                a.borrow_mut().journey.view = journey::View::Source;
                a.borrow_mut().journey.notice_view = journey::View::Source;
                input("profileurl").set_value(&url);
                input("profilepin").set_value(&pin);
                text("setup-feedback","A setup link supplied a profile URL and fingerprint. Nothing has been fetched or accepted. Continue only if you trust the source of the link.");
            }
        }
    }
}
pub(super) fn render(a: &Rc<RefCell<App>>) {
    let s = a.borrow();
    for (id, on) in [
        ("trustprofile", s.setup_candidate.is_some()),
        (
            "useprofile",
            s.setup_candidate.is_some() && input("trustprofile").checked(),
        ),
        ("applybee", s.profile.is_some()),
        (
            "loadprofilefile",
            input("profile").files().is_some_and(|f| f.length() > 0),
        ),
        (
            "fetchprofile",
            !value("profileurl").trim().is_empty() && !value("profilepin").trim().is_empty(),
        ),
    ] {
        if on && !s.busy {
            el(id).remove_attribute("disabled").unwrap();
        } else {
            el(id).set_attribute("disabled", "").unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fingerprints_bind_exact_bytes_not_reformatted_json() {
        let bytes = b"{\"a\":1}";
        let pin = swarm_core::keccak256_hex(bytes);
        fingerprint_matches(bytes, &pin).unwrap();
        assert!(fingerprint_matches(b"{ \"a\":1}", &pin).is_err());
        assert!(fingerprint_matches(bytes, "").is_err());
    }
    #[test]
    fn public_links_and_private_upload_settings_have_separate_rules() {
        assert!(public_url("https://example.org/profile.json").is_ok());
        assert!(public_url("https://example.org/profile.json?key=secret").is_err());
        assert!(public_url("https://user:pass@example.org/profile.json").is_err());
        assert!(upload_config(
            "http://127.0.0.1:1633",
            &"11".repeat(32),
            "Bearer local-only"
        )
        .is_ok());
        assert!(upload_config("https://example.org/", &"00".repeat(32), "").is_err());
    }
    #[test]
    fn profiles_are_candidates_and_reject_ambiguous_root_fields() {
        let mut profile = serde_json::to_value(history::fixture_profile()).unwrap();
        for key in ["gatewayUrl", "metadataPath", "contentPath", "timing"] {
            profile.as_object_mut().unwrap().remove(key);
        }
        profile["contentGatewayUrl"] = json!("https://gateway.example.org/");
        let raw = profile.to_string();
        let candidate = parse(raw.as_bytes()).unwrap();
        assert_eq!(candidate.profile.deployment.chain_id, 100);
        assert!(candidate.source.is_none());
        assert_eq!(
            candidate.gateway.as_deref(),
            Some("https://gateway.example.org/")
        );
        let duplicate = raw.replacen("{", "{\"rpcUrl\":\"https://wrong.example/\",", 1);
        assert!(parse(duplicate.as_bytes()).is_err());
        assert!(parse(&[0xff, 0xfe]).is_err());
    }
}
