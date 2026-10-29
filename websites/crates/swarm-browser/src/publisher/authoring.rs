//! Unreviewed text belongs to the tab/file, not to a wallet or transaction intent.
use super::*;

const KEY: &str = "swarm-publisher-authoring-v1";
const LIMIT: usize = 512 * 1024;
const FIELDS: &[&str] = &[
    "reference",
    "entrytype",
    "title",
    "description",
    "topics",
    "language",
    "contenttype",
    "source",
];

fn capture() -> Value {
    let mut fields = serde_json::Map::new();
    for id in FIELDS {
        fields.insert(
            (*id).into(),
            json!(if ["description", "topics"].contains(id) {
                area(id).value()
            } else {
                value(id)
            }),
        );
    }
    Value::Object(fields)
}
fn fill(fields: &Value) {
    for id in FIELDS {
        let text = fields[*id].as_str().unwrap_or("");
        if ["description", "topics"].contains(id) {
            area(id).set_value(text);
        } else if *id == "entrytype" {
            validation::restore_category(text);
        } else {
            input(id).set_value(text);
        }
    }
}
pub(super) fn encode(fields: &Value) -> Result<String> {
    let object = fields.as_object().ok_or("INVALID_AUTHORING_FILE")?;
    if object.len() != FIELDS.len()
        || object
            .iter()
            .any(|(k, v)| !FIELDS.contains(&k.as_str()) || !v.is_string())
    {
        return Err("INVALID_AUTHORING_FILE");
    }
    let raw =
        json!({"format":"swarm-publication-authoring","version":1,"fields":fields}).to_string();
    if raw.len() > LIMIT {
        return Err("AUTHORING_SIZE_LIMIT");
    }
    Ok(raw)
}
pub(super) fn parse(raw: &str) -> Result<Value> {
    if raw.len() > LIMIT {
        return Err("AUTHORING_SIZE_LIMIT");
    }
    let file: Value = serde_json::from_str(raw).map_err(|_| "INVALID_AUTHORING_FILE")?;
    let object = file.as_object().ok_or("INVALID_AUTHORING_FILE")?;
    if file["version"] != 1 {
        return Err("INVALID_AUTHORING_FILE");
    }
    if file["format"] == "swarm-publication-authoring" {
        if object
            .keys()
            .any(|k| !["format", "version", "fields"].contains(&k.as_str()))
        {
            return Err("INVALID_AUTHORING_FILE");
        }
        encode(&file["fields"])?;
        return Ok(file["fields"].clone());
    }
    // Older complete metadata files may be reused as text in any context. No proof is restored.
    let envelope = object.contains_key("format");
    let allowed = if envelope {
        vec![
            "format",
            "version",
            "chainId",
            "contract",
            "publisher",
            "contentReference",
            "metaHash",
            "metadata",
        ]
    } else {
        vec!["version", "contentReference", "metadata"]
    };
    if object.keys().any(|k| !allowed.contains(&k.as_str()))
        || envelope && file["format"] != "swarm-publication-draft"
    {
        return Err("INVALID_AUTHORING_FILE");
    }
    let draft = create_draft(
        file["contentReference"]
            .as_str()
            .ok_or("INVALID_AUTHORING_FILE")?,
        &file["metadata"],
    )
    .map_err(|e| e.0)?;
    if envelope && file["metaHash"] != draft.meta_hash {
        return Err("INVALID_AUTHORING_FILE");
    }
    let m = &file["metadata"];
    let topics = m["topics"]
        .as_array()
        .ok_or("INVALID_AUTHORING_FILE")?
        .iter()
        .map(|v| v.as_str().ok_or("INVALID_AUTHORING_FILE"))
        .collect::<Result<Vec<_>>>()?
        .join("\n");
    Ok(
        json!({"reference":file["contentReference"],"entrytype":m["type"],"title":m["title"],"description":m["description"].as_str().unwrap_or(""),"topics":topics,"language":m["language"].as_str().unwrap_or(""),"contenttype":m["contentType"],"source":m["source"].as_str().unwrap_or("")}),
    )
}
fn storage() -> Result<web_sys::Storage> {
    web_sys::window()
        .ok_or("AUTHORING_STORAGE_UNAVAILABLE")?
        .session_storage()
        .map_err(|_| "AUTHORING_STORAGE_UNAVAILABLE")?
        .ok_or("AUTHORING_STORAGE_UNAVAILABLE")
}
pub(super) fn save_tab(a: &Rc<RefCell<App>>) {
    if a.borrow().authoring_storage_blocked {
        text("authoring-note","The previous tab draft could not be read and has been kept. Your current text is not being saved over it. Save a draft file; use a fresh tab for a separate tab draft.");
        return;
    }
    let result = (|| -> Result<()> {
        let raw = encode(&capture())?;
        storage()?
            .set_item(KEY, &raw)
            .map_err(|_| "AUTHORING_STORAGE_UNAVAILABLE")
    })();
    text(
        "authoring-note",
        if result.is_ok() {
            "Authoring text saved in this tab for reloads. Save a draft file before closing the tab or browser. Preview, upload and review evidence are not saved."
        } else {
            "This tab could not save the latest text. Your entered values are still here. Save a draft file before leaving; the earlier tab copy has not been removed."
        },
    );
}
pub(super) fn restore_tab(a: &Rc<RefCell<App>>) {
    let result = (|| -> Result<Option<Value>> {
        storage()?
            .get_item(KEY)
            .map_err(|_| "AUTHORING_STORAGE_UNAVAILABLE")?
            .map(|raw| parse(&raw))
            .transpose()
    })();
    match result {
        Ok(Some(fields)) => {fill(&fields); text("authoring-note","Restored unreviewed authoring text from this tab. Preview exact metadata and repeat deployment, upload and guideline checks before submitting. Save a file before closing this tab.");}
        Ok(None) => text("authoring-note","This tab keeps authoring text through reloads as you type. Save a draft file before closing the tab or browser. Saving and loading text need no wallet."),
        Err(_) => {a.borrow_mut().authoring_storage_blocked=true; text("authoring-note","The saved tab draft is unavailable or unreadable. It has not been replaced. You can still type and save a draft file; no wallet is needed.");}
    }
}
pub(super) async fn transfer(a: &Rc<RefCell<App>>, action: &str) -> Result<()> {
    if action == "exportdraft" {
        transfers::download("swarm-authoring-draft.json", &encode(&capture())?)?;
        text("authoring-note","Authoring draft file prepared. It contains text only, including incomplete fields. Loading it never restores wallet, upload or review readiness.");
        return Ok(());
    }
    let file = input("draftfile")
        .files()
        .and_then(|f| f.get(0))
        .ok_or("FILE_REQUIRED")?;
    if file.size() > LIMIT as f64 {
        return Err("AUTHORING_SIZE_LIMIT");
    }
    let raw = JsFuture::from(file.text())
        .await
        .map_err(|_| "FILE_READ_FAILED")?
        .as_string()
        .ok_or("FILE_READ_FAILED")?;
    let fields = parse(&raw)?;
    content::clear(a);
    invalidate_review(a);
    fill(&fields);
    validation::refresh(a);
    save_tab(a);
    text("preview","Loaded authoring text only. Preview exact metadata, load verified guidelines and repeat upload checks. Earlier acknowledgements and transaction readiness were not restored.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fields() -> Value {
        json!({"reference":"unfinished reference","entrytype":"not yet chosen","title":"  A draft\n","description":"line one\nline two","topics":" Biology \n\nmore work","language":"English","contenttype":"unfinished","source":""})
    }
    #[test]
    fn unfinished_text_round_trips_without_metadata_normalization_or_credentials() {
        let raw = encode(&fields()).unwrap();
        assert_eq!(parse(&raw).unwrap(), fields());
        for key in [
            "publisher",
            "authorization",
            "postageBatchId",
            "ack",
            "uploaded",
        ] {
            assert!(!raw.contains(key));
        }
    }
    #[test]
    fn unexpected_authority_or_invalid_field_shapes_are_rejected() {
        let mut file: Value = serde_json::from_str(&encode(&fields()).unwrap()).unwrap();
        file["authorization"] = json!("private");
        assert!(parse(&file.to_string()).is_err());
        file.as_object_mut().unwrap().remove("authorization");
        file["fields"]["ack"] = json!(true);
        assert!(parse(&file.to_string()).is_err());
        file["fields"].as_object_mut().unwrap().remove("ack");
        file["fields"]["title"] = json!(7);
        assert!(parse(&file.to_string()).is_err());
    }
    #[test]
    fn an_old_foreign_context_file_only_supplies_public_authoring_text() {
        let m = json!({"schemaVersion":1,"type":"article","title":"Cells","topics":["biology"],"contentType":"text/plain"});
        let d = create_draft(&"66".repeat(32), &m).unwrap();
        let file = json!({"format":"swarm-publication-draft","version":1,"chainId":999,"contract":format!("0x{}","ab".repeat(20)),"publisher":format!("0x{}","cd".repeat(20)),"contentReference":d.content_hash,"metaHash":d.meta_hash,"metadata":m});
        let imported = parse(&file.to_string()).unwrap();
        assert_eq!(imported["title"], "Cells");
        assert!(imported.get("chainId").is_none());
        let mut bad = file;
        bad["metaHash"] = json!(format!("0x{}", "ff".repeat(32)));
        assert!(parse(&bad.to_string()).is_err());
    }
}
