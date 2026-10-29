//! Local encrypted recovery. No wallet or network access exists in this module.
//! Lock invalidates pending asynchronous work. Callers must await each mutation.
//! Lock drops secrets and derived keys; browser/Rust allocator copies cannot be
//! guaranteed to be erased immediately. Raw WebCrypto buffers are cleared.
use super::BrowserResult;
use js_sys::{Array, Function, Object, Promise, Reflect, Uint8Array};
use std::{cell::RefCell, rc::Rc};
use swarm_core::recovery::{self, Cipher, Envelope, Kdf, Payload, VoteContext, VoteRecord};
use wasm_bindgen::{JsCast, JsValue};
use wasm_bindgen_futures::JsFuture;
const STORAGE_KEY: &str = "moderator-vote-vault-v1";
fn err<T>(_: T) -> &'static str {
    "VAULT_UNAVAILABLE"
}
fn call(object: &JsValue, name: &str, args: &[JsValue]) -> BrowserResult<JsValue> {
    let f = Reflect::get(object, &name.into())
        .map_err(err)?
        .dyn_into::<Function>()
        .map_err(err)?;
    let a = Array::new();
    for arg in args {
        a.push(arg);
    }
    f.apply(object, &a).map_err(err)
}
fn obj(fields: &[(&str, JsValue)]) -> JsValue {
    let o = Object::new();
    for (k, v) in fields {
        Reflect::set(&o, &(*k).into(), v).expect("new object properties");
    }
    o.into()
}
async fn promise(v: JsValue) -> BrowserResult<JsValue> {
    JsFuture::from(v.dyn_into::<Promise>().map_err(err)?)
        .await
        .map_err(|_| "BACKUP_AUTHENTICATION_FAILED")
}
fn crypto() -> BrowserResult<JsValue> {
    Reflect::get(&js_sys::global(), &"crypto".into()).map_err(err)
}
fn subtle() -> BrowserResult<JsValue> {
    Reflect::get(&crypto()?, &"subtle".into()).map_err(err)
}
pub fn random_bytes(length: u32) -> BrowserResult<Vec<u8>> {
    let bytes = Uint8Array::new_with_length(length);
    call(&crypto()?, "getRandomValues", &[bytes.clone().into()])?;
    Ok(bytes.to_vec())
}
fn read() -> BrowserResult<Option<String>> {
    web_sys::window()
        .ok_or("VAULT_UNAVAILABLE")?
        .local_storage()
        .map_err(|_| "STORAGE_FAILED")?
        .ok_or("VAULT_UNAVAILABLE")?
        .get_item(STORAGE_KEY)
        .map_err(|_| "STORAGE_FAILED")
}
fn write(text: &str) -> BrowserResult<()> {
    web_sys::window()
        .ok_or("VAULT_UNAVAILABLE")?
        .local_storage()
        .map_err(|_| "STORAGE_FAILED")?
        .ok_or("VAULT_UNAVAILABLE")?
        .set_item(STORAGE_KEY, text)
        .map_err(|_| "STORAGE_FAILED")
}
fn decode(s: &str) -> BrowserResult<JsValue> {
    Ok(Uint8Array::from(hex::decode(s).map_err(|_| "INVALID_BACKUP")?.as_slice()).into())
}
async fn derive(password: &str, kdf: &Kdf) -> BrowserResult<JsValue> {
    if password.is_empty() || password.encode_utf16().count() > 1024 {
        return Err("INVALID_PASSWORD");
    }
    let raw = Uint8Array::from(password.as_bytes());
    let uses = Array::of1(&"deriveKey".into());
    let imported = call(
        &subtle()?,
        "importKey",
        &[
            "raw".into(),
            raw.clone().into(),
            "PBKDF2".into(),
            false.into(),
            uses.into(),
        ],
    );
    let material = match imported {
        Ok(p) => promise(p).await,
        Err(e) => Err(e),
    };
    raw.fill(0, 0, raw.length());
    let material = material?;
    promise(call(
        &subtle()?,
        "deriveKey",
        &[
            obj(&[
                ("name", "PBKDF2".into()),
                ("hash", "SHA-256".into()),
                ("salt", decode(&kdf.salt)?),
                ("iterations", recovery::ITERATIONS.into()),
            ]),
            material,
            obj(&[("name", "AES-GCM".into()), ("length", 256.into())]),
            false.into(),
            Array::of2(&"encrypt".into(), &"decrypt".into()).into(),
        ],
    )?)
    .await
}
fn algorithm(iv: JsValue) -> JsValue {
    obj(&[
        ("name", "AES-GCM".into()),
        ("iv", iv),
        ("additionalData", Uint8Array::from(recovery::AAD).into()),
        ("tagLength", 128.into()),
    ])
}
async fn encrypt(payload: &Payload, key: &JsValue, kdf: &Kdf) -> BrowserResult<String> {
    let iv = random_bytes(12)?;
    let raw = Uint8Array::from(serde_json::to_vec(payload).map_err(err)?.as_slice());
    let encrypted = call(
        &subtle()?,
        "encrypt",
        &[
            algorithm(Uint8Array::from(iv.as_slice()).into()),
            key.clone(),
            raw.clone().into(),
        ],
    );
    let result = match encrypted {
        Ok(p) => promise(p).await,
        Err(e) => Err(e),
    };
    raw.fill(0, 0, raw.length());
    let data = Uint8Array::new(&result?).to_vec();
    let envelope = Envelope {
        format: recovery::FORMAT.into(),
        version: 1,
        kdf: kdf.clone(),
        cipher: Cipher {
            name: "AES-GCM".into(),
            iv: hex::encode(iv),
            data: hex::encode(data),
        },
    };
    let text = serde_json::to_string(&envelope).map_err(err)?;
    if text.len() > recovery::MAX_FILE_BYTES {
        return Err("VAULT_FULL");
    }
    Ok(text)
}
async fn decrypt(envelope: &Envelope, key: &JsValue) -> BrowserResult<Payload> {
    let raw = Uint8Array::new(
        &promise(call(
            &subtle()?,
            "decrypt",
            &[
                algorithm(decode(&envelope.cipher.iv)?),
                key.clone(),
                decode(&envelope.cipher.data)?,
            ],
        )?)
        .await?,
    );
    let payload = Payload::parse(&raw.to_vec()).map_err(|_| "BACKUP_AUTHENTICATION_FAILED");
    raw.fill(0, 0, raw.length());
    payload
}
async fn fingerprint(record: &VoteRecord) -> BrowserResult<String> {
    let raw = Uint8Array::from(record.json_bytes().as_slice());
    let result = call(
        &subtle()?,
        "digest",
        &["SHA-256".into(), raw.clone().into()],
    );
    let digest = match result {
        Ok(p) => promise(p).await,
        Err(e) => Err(e),
    };
    raw.fill(0, 0, raw.length());
    Ok(hex::encode(Uint8Array::new(&digest?).to_vec()))
}
#[derive(Default)]
struct State {
    generation: u64,
    busy: bool,
    key: Option<JsValue>,
    kdf: Option<Kdf>,
    payload: Option<Payload>,
    fingerprints: Vec<String>,
    stored: Option<String>,
    fresh: Vec<VoteRecord>,
}
#[derive(Clone, Default)]
pub struct VoteVault(Rc<RefCell<State>>);
struct Operation {
    vault: VoteVault,
    token: u64,
}
impl Drop for Operation {
    fn drop(&mut self) {
        let mut s = self.vault.0.borrow_mut();
        if s.generation == self.token {
            s.busy = false;
        }
    }
}
impl Operation {
    fn current(&self) -> BrowserResult<()> {
        if self.vault.0.borrow().generation != self.token {
            Err("VAULT_LOCKED")
        } else {
            Ok(())
        }
    }
}
impl VoteVault {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn lock(&self) {
        let generation = self.0.borrow().generation.wrapping_add(1);
        *self.0.borrow_mut() = State {
            generation,
            ..State::default()
        };
    }
    pub fn is_unlocked(&self) -> bool {
        self.0.borrow().key.is_some()
    }
    /// Capture before asynchronous file reading, which precedes a vault operation.
    /// An explicit lock invalidates that import/verification intent as well.
    pub fn generation(&self) -> u64 {
        self.0.borrow().generation
    }
    fn begin(&self, locked_allowed: bool) -> BrowserResult<Operation> {
        let mut s = self.0.borrow_mut();
        if s.busy {
            return Err("VAULT_BUSY");
        }
        if !locked_allowed && s.key.is_none() {
            return Err("VAULT_LOCKED");
        }
        s.busy = true;
        Ok(Operation {
            vault: self.clone(),
            token: s.generation,
        })
    }
    fn active(&self) -> BrowserResult<(JsValue, Kdf, Payload)> {
        let s = self.0.borrow();
        Ok((
            s.key.clone().ok_or("VAULT_LOCKED")?,
            s.kdf.clone().ok_or("VAULT_LOCKED")?,
            s.payload.clone().ok_or("VAULT_LOCKED")?,
        ))
    }
    pub fn list_votes(&self) -> BrowserResult<Vec<VoteRecord>> {
        Ok(self.active()?.2.all_votes().cloned().collect())
    }
    pub fn get_vote(&self, context: &VoteContext) -> BrowserResult<Option<VoteRecord>> {
        let id = context.identity().map_err(|e| e.0)?;
        Ok(self
            .active()?
            .2
            .votes
            .into_iter()
            .find(|v| v.context().identity().ok().as_ref() == Some(&id)))
    }
    pub fn is_backed_up(&self, context: &VoteContext) -> BrowserResult<bool> {
        let id = context.identity().map_err(|e| e.0)?;
        let s = self.0.borrow();
        let p = s.payload.as_ref().ok_or("VAULT_LOCKED")?;
        Ok(p.votes
            .iter()
            .position(|v| v.context().identity().ok().as_ref() == Some(&id))
            .is_some_and(|i| p.backed_up.contains(&s.fingerprints[i])))
    }
    async fn persist(&self, payload: Payload, op: &Operation) -> BrowserResult<()> {
        let (key, kdf, _) = self.active()?;
        let mut fingerprints = vec![];
        for v in payload.all_votes() {
            fingerprints.push(fingerprint(v).await?);
        }
        op.current()?;
        let text = encrypt(&payload, &key, &kdf).await?;
        op.current()?;
        if read()? != self.0.borrow().stored {
            return Err("VAULT_CHANGED");
        }
        write(&text)?;
        let mut s = self.0.borrow_mut();
        s.payload = Some(payload);
        s.fingerprints = fingerprints;
        s.stored = Some(text);
        Ok(())
    }
    pub async fn unlock(&self, password: &str) -> BrowserResult<usize> {
        self.lock();
        let op = self.begin(true)?;
        let stored = read()?;
        let envelope = stored
            .as_deref()
            .map(Envelope::parse)
            .transpose()
            .map_err(|e| e.0)?;
        let kdf = match &envelope {
            Some(e) => e.kdf.clone(),
            None => Kdf {
                name: "PBKDF2".into(),
                hash: "SHA-256".into(),
                iterations: recovery::ITERATIONS,
                salt: hex::encode(random_bytes(16)?),
            },
        };
        let key = derive(password, &kdf).await?;
        let payload = match envelope {
            Some(ref e) => decrypt(e, &key).await?,
            None => Payload::empty(),
        };
        let mut fingerprints = vec![];
        for v in payload.all_votes() {
            fingerprints.push(fingerprint(v).await?);
        }
        if payload.backed_up.iter().any(|f| !fingerprints.contains(f)) {
            return Err("INVALID_BACKUP");
        }
        let text = match &stored {
            Some(t) => t.clone(),
            None => encrypt(&payload, &key, &kdf).await?,
        };
        op.current()?;
        if read()? != stored {
            return Err("VAULT_CHANGED");
        }
        if stored.is_none() {
            write(&text)?;
        }
        let count = payload.votes.len();
        let mut s = self.0.borrow_mut();
        s.key = Some(key);
        s.kdf = Some(kdf);
        s.payload = Some(payload);
        s.fingerprints = fingerprints;
        s.stored = Some(text);
        Ok(count)
    }
    pub async fn save_vote(&self, record: VoteRecord) -> BrowserResult<VoteRecord> {
        let record = record.normalized().map_err(|e| e.0)?;
        let op = self.begin(false)?;
        let mut p = self.active()?.2;
        if let Some(existing) = self.get_vote(&record.context())? {
            return if existing == record {
                Ok(existing)
            } else {
                Err("VOTE_CONFLICT")
            };
        }
        p.votes = recovery::merge(&p.votes, &[record.clone()]).map_err(|e| e.0)?;
        self.persist(p, &op).await?;
        self.0.borrow_mut().fresh.push(record.clone());
        Ok(record)
    }
    /// No reload/import/journal absence can recreate this capability.
    pub fn can_correct(&self, record: &VoteRecord) -> bool {
        let s = self.0.borrow();
        s.key.is_some() && s.fresh.contains(record) && read().is_ok_and(|raw| raw == s.stored)
    }
    pub fn seal_choice(&self, record: &VoteRecord) {
        self.0.borrow_mut().fresh.retain(|v| v != record);
    }
    pub async fn correct_vote(
        &self,
        original: &VoteRecord,
        replacement: VoteRecord,
    ) -> BrowserResult<VoteRecord> {
        let op = self.begin(false)?;
        if !self.can_correct(original) {
            return Err("CHOICE_PROTECTED");
        }
        let p = self
            .active()?
            .2
            .corrected(original, replacement.clone())
            .map_err(|e| e.0)?;
        self.persist(p, &op).await?;
        // Persist checks generation and cross-tab storage before writing.
        self.seal_choice(original);
        self.0.borrow_mut().fresh.push(replacement.clone());
        Ok(replacement)
    }
    pub async fn export_backup(&self) -> BrowserResult<String> {
        let op = self.begin(false)?;
        let (key, kdf, mut p) = self.active()?;
        p.backed_up.clear();
        let text = encrypt(&p, &key, &kdf).await?;
        op.current()?;
        Ok(text)
    }
    async fn open_backup(&self, text: &str, password: Option<&str>) -> BrowserResult<Payload> {
        let e = Envelope::parse(text).map_err(|e| e.0)?;
        let key = if let Some(p) = password {
            derive(p, &e.kdf).await?
        } else {
            let (key, kdf, _) = self.active()?;
            if kdf.salt != e.kdf.salt {
                return Err("BACKUP_PASSWORD_REQUIRED");
            }
            key
        };
        decrypt(&e, &key).await
    }
    pub async fn verify_backup(&self, text: &str, password: Option<&str>) -> BrowserResult<usize> {
        let op = self.begin(false)?;
        let backup = self.open_backup(text, password).await?;
        let mut p = self.active()?.2;
        let matches = p
            .all_votes()
            .filter(|v| backup.all_votes().any(|b| b == *v))
            .cloned()
            .collect::<Vec<_>>();
        for v in &matches {
            let f = fingerprint(v).await?;
            if !p.backed_up.contains(&f) {
                p.backed_up.push(f);
            }
        }
        self.persist(p, &op).await?;
        Ok(matches.len())
    }
    pub async fn import_backup(&self, text: &str, password: Option<&str>) -> BrowserResult<usize> {
        let op = self.begin(true)?;
        self.0.borrow_mut().fresh.clear();
        if !self.is_unlocked() {
            if read()?.is_some() {
                return Err("VAULT_LOCKED");
            }
            let envelope = Envelope::parse(text).map_err(|e| e.0)?;
            let key = derive(password.ok_or("BACKUP_PASSWORD_REQUIRED")?, &envelope.kdf).await?;
            let mut p = decrypt(&envelope, &key).await?;
            let mut fingerprints = vec![];
            for v in p.all_votes() {
                fingerprints.push(fingerprint(v).await?);
            }
            p.backed_up = fingerprints.clone();
            let encrypted = encrypt(&p, &key, &envelope.kdf).await?;
            op.current()?;
            if read()?.is_some() {
                return Err("VAULT_CHANGED");
            }
            write(&encrypted)?;
            let count = p.votes.len();
            let mut s = self.0.borrow_mut();
            s.key = Some(key);
            s.kdf = Some(envelope.kdf);
            s.payload = Some(p);
            s.fingerprints = fingerprints;
            s.stored = Some(encrypted);
            return Ok(count);
        }
        let backup = self.open_backup(text, password).await?;
        let mut p = self.active()?.2;
        p = p.merged(&backup).map_err(|e| e.0)?;
        for v in backup.all_votes() {
            let f = fingerprint(v).await?;
            if !p.backed_up.contains(&f) {
                p.backed_up.push(f);
            }
        }
        self.persist(p, &op).await?;
        Ok(backup.votes.len())
    }
}

/// Synthetic interoperability harness only. Production builds omit this API.
#[cfg(feature = "interop-tests")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn encrypt_recovery_for_test(
    payload_json: &str,
    password: &str,
) -> Result<String, JsValue> {
    let payload = Payload::parse(payload_json.as_bytes()).map_err(|e| JsValue::from_str(e.0))?;
    let kdf = Kdf {
        name: "PBKDF2".into(),
        hash: "SHA-256".into(),
        iterations: recovery::ITERATIONS,
        salt: hex::encode(random_bytes(16).map_err(JsValue::from_str)?),
    };
    let key = derive(password, &kdf).await.map_err(JsValue::from_str)?;
    encrypt(&payload, &key, &kdf)
        .await
        .map_err(JsValue::from_str)
}

/// Uses exactly the same decryption and record validation as production imports.
#[cfg(feature = "interop-tests")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn decrypt_recovery_for_test(
    envelope_json: &str,
    password: &str,
) -> Result<String, JsValue> {
    let envelope = Envelope::parse(envelope_json).map_err(|e| JsValue::from_str(e.0))?;
    let key = derive(password, &envelope.kdf)
        .await
        .map_err(JsValue::from_str)?;
    let payload = decrypt(&envelope, &key).await.map_err(JsValue::from_str)?;
    serde_json::to_string(&payload).map_err(|_| JsValue::from_str("INVALID_BACKUP"))
}
