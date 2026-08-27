//! `KeyStore` adapter that combines a hot in-memory cache with write-through
//! persistence to the Bitwarden / Vaultwarden REST API. Phase B.8.
//!
//! The split is intentional: read-side traffic (lookup_credential,
//! list_credentials, increment_counter) hits the in-memory store synchronously
//! so the CTAP2 hot path stays cheap and never blocks on the network. Only
//! the two `persist_*` hooks reach out to Vaultwarden, asynchronously, after
//! the in-memory state has already been updated.
//!
//! On `persist_new_credential`:
//!   * call `BwClient::create_passkey_cipher` to push the cipher
//!   * (today) the server-assigned cipher ID is recorded in `cipher_ids` so
//!     `persist_counter_bump` can address the right row.
//!
//! On `persist_counter_bump`:
//!   * look up the cipher ID for the given credential_id
//!   * call `BwClient::update_passkey_counter` with the bumped value
//!
//! Failures in either direction are reported back via `KeyStoreError`; the
//! CTAP2 dispatcher in `ctap2.rs` logs and continues, so a transient vault
//! outage never breaks an in-progress WebAuthn ceremony.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::Mutex;

use crate::ctap2::{InMemoryKeyStore, KeyStore, KeyStoreError, PasskeyCredential};
use crate::store::bw_api::PasskeyCipher;
use zeroize::Zeroizing;

/// Minimal trait surface of `BwClient` that this adapter actually depends on.
/// Going through a trait keeps `BwBackedKeyStore` testable without a real
/// Vaultwarden — the production wiring uses `BwClient` directly via the
/// blanket `impl` below.
#[async_trait]
pub trait BwPersist: Send + Sync {
    async fn create_passkey_cipher(&mut self, cred: &PasskeyCipher)
        -> crate::error::Result<String>;
    async fn update_passkey_counter(
        &mut self,
        cipher_id: &str,
        new_counter: u32,
    ) -> crate::error::Result<()>;
}

#[async_trait]
impl BwPersist for crate::store::bw_api::BwClient {
    async fn create_passkey_cipher(
        &mut self,
        cred: &PasskeyCipher,
    ) -> crate::error::Result<String> {
        crate::store::bw_api::BwClient::create_passkey_cipher(self, cred).await
    }
    async fn update_passkey_counter(
        &mut self,
        cipher_id: &str,
        new_counter: u32,
    ) -> crate::error::Result<()> {
        crate::store::bw_api::BwClient::update_passkey_counter(self, cipher_id, new_counter).await
    }
}

/// Combined keystore: in-memory hot read path + Vaultwarden write-through.
pub struct BwBackedKeyStore {
    inner: InMemoryKeyStore,
    bw: Arc<Mutex<dyn BwPersist>>,
    /// Map credential_id -> server-assigned cipher_id, populated on
    /// `persist_new_credential`. Used by `persist_counter_bump` to address
    /// the right cipher row in subsequent updates.
    cipher_ids: HashMap<Vec<u8>, String>,
}

impl BwBackedKeyStore {
    pub fn new(bw: Arc<Mutex<dyn BwPersist>>) -> Self {
        Self {
            inner: InMemoryKeyStore::new(),
            bw,
            cipher_ids: HashMap::new(),
        }
    }

    /// Pre-seed the cipher_id index from a vault sync. Pass the
    /// (credential_id, cipher_id) pair for every passkey already in the vault
    /// so subsequent counter bumps can resolve the row.
    pub fn record_existing_cipher_id(&mut self, credential_id: Vec<u8>, cipher_id: String) {
        self.cipher_ids.insert(credential_id, cipher_id);
    }

    /// Borrow the inner in-memory store (for bootstrap loads — see `main.rs`
    /// where every synced cipher gets fed in via `store_new_credential`).
    pub fn inner_mut(&mut self) -> &mut InMemoryKeyStore {
        &mut self.inner
    }
}

#[async_trait]
impl KeyStore for BwBackedKeyStore {
    fn lookup_credential(&self, rp_id: &str, credential_id: &[u8]) -> Option<&PasskeyCredential> {
        self.inner.lookup_credential(rp_id, credential_id)
    }

    fn list_credentials(&self, rp_id: &str) -> Vec<&PasskeyCredential> {
        self.inner.list_credentials(rp_id)
    }

    fn store_new_credential(&mut self, cred: PasskeyCredential) -> Result<(), KeyStoreError> {
        self.inner.store_new_credential(cred)
    }

    fn increment_counter(&mut self, credential_id: &[u8]) -> Result<u32, KeyStoreError> {
        self.inner.increment_counter(credential_id)
    }

    async fn persist_new_credential(
        &mut self,
        cred: &PasskeyCredential,
    ) -> Result<(), KeyStoreError> {
        // Convert the in-memory PasskeyCredential into the on-vault
        // PasskeyCipher shape that `BwClient::create_passkey_cipher` expects.
        // We don't carry rp_name / discoverable through the CTAP2 layer
        // today, so default them; users who want richer metadata can edit
        // the cipher in the Bitwarden UI after the first registration.
        let pc = PasskeyCipher {
            // Brand-new credential — the server assigns the cipher_id on
            // create; we record it from the response below, not from here.
            cipher_id: None,
            credential_id: cred.credential_id.clone(),
            rp_id: cred.rp_id.clone(),
            rp_name: None,
            user_handle: cred.user_handle.clone(),
            user_name: Some(cred.user_name.clone()).filter(|s| !s.is_empty()),
            user_display_name: Some(cred.user_display_name.clone()).filter(|s| !s.is_empty()),
            key_algorithm: "ECDSA".into(),
            key_curve: "P-256".into(),
            private_key_pkcs8: Zeroizing::new(cred.key_pkcs8.clone()),
            counter: cred.counter,
            discoverable: true,
        };
        let mut guard = self.bw.lock().await;
        let new_id = guard
            .create_passkey_cipher(&pc)
            .await
            .map_err(|e| KeyStoreError(format!("vault create: {e}")))?;
        drop(guard);
        self.cipher_ids.insert(cred.credential_id.clone(), new_id);
        Ok(())
    }

    async fn persist_counter_bump(
        &mut self,
        credential_id: &[u8],
        new_counter: u32,
    ) -> Result<(), KeyStoreError> {
        let cipher_id = match self.cipher_ids.get(credential_id) {
            Some(id) => id.clone(),
            None => {
                return Err(KeyStoreError(
                    "no cipher_id recorded for credential_id (was this credential synced \
                     from the vault on startup?)"
                        .into(),
                ));
            }
        };
        let mut guard = self.bw.lock().await;
        guard
            .update_passkey_counter(&cipher_id, new_counter)
            .await
            .map_err(|e| KeyStoreError(format!("vault update: {e}")))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::{BrokerError, Result as BResult};

    /// Minimal mock that records every call. Lets us assert that the
    /// adapter calls the right BW endpoint with the right arguments.
    #[derive(Default)]
    struct MockBw {
        created: Vec<PasskeyCipher>,
        updated: Vec<(String, u32)>,
        next_id: String,
        force_create_err: bool,
        force_update_err: bool,
    }

    #[async_trait]
    impl BwPersist for MockBw {
        async fn create_passkey_cipher(&mut self, cred: &PasskeyCipher) -> BResult<String> {
            if self.force_create_err {
                return Err(BrokerError::Vault("forced".into()));
            }
            self.created.push(cred.clone());
            Ok(self.next_id.clone())
        }
        async fn update_passkey_counter(
            &mut self,
            cipher_id: &str,
            new_counter: u32,
        ) -> BResult<()> {
            if self.force_update_err {
                return Err(BrokerError::Vault("forced".into()));
            }
            self.updated.push((cipher_id.into(), new_counter));
            Ok(())
        }
    }

    fn fake_credential(rp: &str, id: u8) -> PasskeyCredential {
        PasskeyCredential {
            credential_id: vec![id; 16],
            rp_id: rp.into(),
            user_handle: vec![0xAA; 8],
            user_name: "alice@example.test".into(),
            user_display_name: "Alice".into(),
            // PKCS#8 placeholder — the keystore adapter doesn't decode it.
            key_pkcs8: vec![0u8; 138],
            counter: 0,
        }
    }

    #[tokio::test]
    async fn persist_new_credential_pushes_then_records_cipher_id() {
        let mock = Arc::new(Mutex::new(MockBw {
            next_id: "server-cipher-uuid".into(),
            ..Default::default()
        }));
        let mut ks = BwBackedKeyStore::new(mock.clone() as Arc<Mutex<dyn BwPersist>>);
        let cred = fake_credential("example.test", 0xAB);

        ks.persist_new_credential(&cred).await.expect("persist ok");

        let m = mock.lock().await;
        assert_eq!(m.created.len(), 1, "BwClient::create called once");
        assert_eq!(m.created[0].rp_id, "example.test");
        assert_eq!(m.created[0].credential_id, vec![0xAB; 16]);
        drop(m);

        // cipher_id must now be addressable for subsequent counter bumps.
        assert_eq!(
            ks.cipher_ids.get(&vec![0xAB; 16]),
            Some(&"server-cipher-uuid".to_string())
        );

        // Second hop: counter bump uses the recorded cipher_id.
        ks.persist_counter_bump(&[0xAB; 16], 7)
            .await
            .expect("bump ok");
        let m = mock.lock().await;
        assert_eq!(m.updated, vec![("server-cipher-uuid".into(), 7u32)]);
    }

    #[tokio::test]
    async fn persist_counter_bump_without_known_cipher_id_errors() {
        let mock = Arc::new(Mutex::new(MockBw::default()));
        let mut ks = BwBackedKeyStore::new(mock.clone() as Arc<Mutex<dyn BwPersist>>);
        let err = ks
            .persist_counter_bump(&[0x11; 16], 42)
            .await
            .expect_err("must fail without a known cipher_id");
        assert!(err.0.contains("cipher_id"), "got {}", err.0);
        // pre-seed and retry: must succeed.
        ks.record_existing_cipher_id(vec![0x11; 16], "preseeded".into());
        ks.persist_counter_bump(&[0x11; 16], 42)
            .await
            .expect("after preseed, ok");
        let m = mock.lock().await;
        assert_eq!(m.updated, vec![("preseeded".into(), 42u32)]);
    }
}
