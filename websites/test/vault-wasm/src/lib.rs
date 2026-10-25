//! Synthetic encrypted-recovery test harness. Not a public website asset.
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub async fn encrypt_test(payload: &str, password: &str) -> Result<String, JsValue> {
    swarm_browser::encrypt_recovery_for_test(payload, password).await
}
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub async fn decrypt_test(envelope: &str, password: &str) -> Result<String, JsValue> {
    swarm_browser::decrypt_recovery_for_test(envelope, password).await
}

// Calls the production state machine; all data comes from synthetic Node fixtures.
#[cfg(any(target_arch = "wasm32", feature = "browser-check"))]
mod lifecycle {
    use swarm_browser::VoteVault;
    use swarm_core::recovery::VoteRecord;
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen]
    pub struct LifecycleVault(VoteVault);

    fn error(e: &str) -> JsValue {
        JsValue::from_str(e)
    }

    #[wasm_bindgen]
    impl LifecycleVault {
        #[wasm_bindgen(constructor)]
        pub fn new() -> Self {
            Self(VoteVault::new())
        }
        pub fn lock(&self) {
            self.0.lock();
        }
        pub fn unlocked(&self) -> bool {
            self.0.is_unlocked()
        }
        pub async fn unlock(&self, password: &str) -> Result<usize, JsValue> {
            self.0.unlock(password).await.map_err(error)
        }
        pub fn records(&self) -> Result<String, JsValue> {
            serde_json::to_string(&self.0.list_votes().map_err(error)?)
                .map_err(|_| error("TEST_SERIALIZATION"))
        }
        pub fn covered(&self, record: &str) -> Result<bool, JsValue> {
            let record: VoteRecord =
                serde_json::from_str(record).map_err(|_| error("TEST_RECORD"))?;
            self.0.is_backed_up(&record.context()).map_err(error)
        }
        pub async fn save(&self, record: &str) -> Result<(), JsValue> {
            let record: VoteRecord =
                serde_json::from_str(record).map_err(|_| error("TEST_RECORD"))?;
            self.0.save_vote(record).await.map(|_| ()).map_err(error)
        }
        pub async fn export_backup(&self) -> Result<String, JsValue> {
            self.0.export_backup().await.map_err(error)
        }
        pub async fn verify(&self, text: &str, password: Option<String>) -> Result<usize, JsValue> {
            self.0
                .verify_backup(text, password.as_deref())
                .await
                .map_err(error)
        }
        pub async fn import_backup(
            &self,
            text: &str,
            password: Option<String>,
        ) -> Result<usize, JsValue> {
            self.0
                .import_backup(text, password.as_deref())
                .await
                .map_err(error)
        }
    }
}
