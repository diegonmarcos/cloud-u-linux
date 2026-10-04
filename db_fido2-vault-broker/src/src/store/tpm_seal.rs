//! Phase B.2 — TPM2 seal/unseal proof of concept.
//!
//! Default build = mock backend. AES-256-GCM with key derived from
//! `/etc/machine-id` via HKDF-SHA256. **NOT FOR PRODUCTION** — provides a
//! reproducible roundtrip on any Linux box (incl. CI) so the on-disk
//! format and the public API can be exercised without TPM hardware.
//!
//! `--features tpm` build = real `tss-esapi` backend (Phase B.2-hw).
//! Sealed objects are KeyedHash data objects under the Owner-hierarchy
//! SRK, bound to a SHA-256 PCR policy over PCRs 0 (firmware), 7
//! (Secure-Boot config) and 8 (kernel cmdline). Drift in any of those
//! PCRs causes `unseal` to refuse — the desired anti-tamper property.
//!
//! On-disk format (binary, all little-endian):
//!   u32 version=1
//!   u32 pcr_bitmask           (mock backend uses 0)
//!   u32 public_blob_len; [public_blob bytes]
//!   u32 private_blob_len; [private_blob bytes]
//!
//! Public API:
//!   pub fn seal_to_path(plain: &[u8], path: &Path) -> Result<()>
//!   pub fn unseal_from_path(path: &Path) -> Result<Zeroizing<Vec<u8>>>

use crate::error::{BrokerError, Result};
use std::io::{Read, Write};
use std::path::Path;
use zeroize::Zeroizing;

/// Wire format version. Bumped on any incompatible layout change.
const FORMAT_VERSION: u32 = 1;

/// Maximum size for a sealed blob field (1 MiB) — guards against
/// pathological / corrupt headers triggering huge allocations.
const MAX_BLOB_FIELD: u32 = 1024 * 1024;

// ─── Public API ────────────────────────────────────────────────────────

/// Seal `plain` and write the framed blob to `path`.
pub fn seal_to_path(plain: &[u8], path: &Path) -> Result<()> {
    #[cfg(not(feature = "tpm"))]
    let (pcr_bitmask, public_blob, private_blob) = mock::seal(plain)?;
    #[cfg(feature = "tpm")]
    let (pcr_bitmask, public_blob, private_blob) = tpm::seal(plain)?;

    write_framed(path, pcr_bitmask, &public_blob, &private_blob)
}

/// Read the framed blob at `path` and unseal it.
pub fn unseal_from_path(path: &Path) -> Result<Zeroizing<Vec<u8>>> {
    let (pcr_bitmask, public_blob, private_blob) = read_framed(path)?;

    #[cfg(not(feature = "tpm"))]
    {
        mock::unseal(pcr_bitmask, &public_blob, &private_blob)
    }
    #[cfg(feature = "tpm")]
    {
        tpm::unseal(pcr_bitmask, &public_blob, &private_blob)
    }
}

// ─── Frame I/O (shared by both backends) ───────────────────────────────

fn write_framed(
    path: &Path,
    pcr_bitmask: u32,
    public_blob: &[u8],
    private_blob: &[u8],
) -> Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let mut f = std::fs::File::create(path)?;
    f.write_all(&FORMAT_VERSION.to_le_bytes())?;
    f.write_all(&pcr_bitmask.to_le_bytes())?;
    f.write_all(&(public_blob.len() as u32).to_le_bytes())?;
    f.write_all(public_blob)?;
    f.write_all(&(private_blob.len() as u32).to_le_bytes())?;
    f.write_all(private_blob)?;
    f.sync_all()?;
    Ok(())
}

fn read_framed(path: &Path) -> Result<(u32, Vec<u8>, Vec<u8>)> {
    let mut f = std::fs::File::open(path)?;
    let version = read_u32(&mut f)
        .map_err(|_| BrokerError::SealFormat("file truncated before version field".into()))?;
    if version != FORMAT_VERSION {
        return Err(BrokerError::SealFormat(format!(
            "unsupported format version {version} (expected {FORMAT_VERSION})"
        )));
    }
    let pcr_bitmask = read_u32(&mut f)
        .map_err(|_| BrokerError::SealFormat("file truncated before pcr_bitmask".into()))?;
    let public_blob = read_len_prefixed(&mut f, "public_blob")?;
    let private_blob = read_len_prefixed(&mut f, "private_blob")?;
    Ok((pcr_bitmask, public_blob, private_blob))
}

fn read_u32(f: &mut std::fs::File) -> std::io::Result<u32> {
    let mut buf = [0u8; 4];
    f.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}

fn read_len_prefixed(f: &mut std::fs::File, name: &str) -> Result<Vec<u8>> {
    let len = read_u32(f)
        .map_err(|_| BrokerError::SealFormat(format!("file truncated before {name} length")))?;
    if len > MAX_BLOB_FIELD {
        return Err(BrokerError::SealFormat(format!(
            "{name} length {len} exceeds maximum {MAX_BLOB_FIELD}"
        )));
    }
    let mut buf = vec![0u8; len as usize];
    f.read_exact(&mut buf)
        .map_err(|_| BrokerError::SealFormat(format!("file truncated inside {name}")))?;
    Ok(buf)
}

// ─── Mock backend (default build) ──────────────────────────────────────

#[cfg(not(feature = "tpm"))]
mod mock {
    use super::*;
    use aes_gcm::aead::{Aead, KeyInit};
    use aes_gcm::{Aes256Gcm, Key, Nonce};
    use hkdf::Hkdf;
    use rand::RngCore;
    use sha2::Sha256;
    use std::path::PathBuf;

    /// HKDF salt — namespaces the derived key to this crate + format version.
    const HKDF_SALT: &[u8] = b"fido2-vault-broker-mock-v1";
    /// HKDF info — domain-separates the seal key.
    const HKDF_INFO: &[u8] = b"seal-key";
    /// AES-256-GCM nonce length.
    const NONCE_LEN: usize = 12;
    /// AES-256 key length.
    const KEY_LEN: usize = 32;

    fn machine_id_path() -> PathBuf {
        PathBuf::from("/etc/machine-id")
    }

    /// Derive the AES-256 key from `/etc/machine-id` (or `path` for tests).
    pub(super) fn derive_key(path: &Path) -> Zeroizing<[u8; KEY_LEN]> {
        let ikm = match std::fs::read(path) {
            Ok(b) => Zeroizing::new(b),
            Err(_) => {
                // PoC fallback for non-Linux test envs only.
                tracing::warn!(
                    "mock seal: {} unreadable; using ZERO key (PoC fallback, NOT secure)",
                    path.display()
                );
                Zeroizing::new(vec![0u8; 32])
            }
        };
        let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), &ikm);
        let mut out = Zeroizing::new([0u8; KEY_LEN]);
        hk.expand(HKDF_INFO, out.as_mut())
            .expect("HKDF expand of 32 bytes never fails");
        out
    }

    pub(super) fn seal(plain: &[u8]) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        seal_with_key(plain, &derive_key(&machine_id_path()))
    }

    pub(super) fn unseal(
        _pcr_bitmask: u32,
        public_blob: &[u8],
        private_blob: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>> {
        unseal_with_key(public_blob, private_blob, &derive_key(&machine_id_path()))
    }

    pub(super) fn seal_with_key(
        plain: &[u8],
        key: &Zeroizing<[u8; KEY_LEN]>,
    ) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key.as_ref()));
        let mut nonce_bytes = [0u8; NONCE_LEN];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext = cipher
            .encrypt(nonce, plain)
            .map_err(|e| BrokerError::Other(format!("AES-GCM seal failed: {e}")))?;
        // public_blob = nonce, private_blob = ciphertext+tag, pcr_bitmask = 0 (mock)
        Ok((0u32, nonce_bytes.to_vec(), ciphertext))
    }

    pub(super) fn unseal_with_key(
        public_blob: &[u8],
        private_blob: &[u8],
        key: &Zeroizing<[u8; KEY_LEN]>,
    ) -> Result<Zeroizing<Vec<u8>>> {
        if public_blob.len() != NONCE_LEN {
            return Err(BrokerError::SealFormat(format!(
                "mock backend expected {NONCE_LEN}-byte nonce in public_blob, got {}",
                public_blob.len()
            )));
        }
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key.as_ref()));
        let nonce = Nonce::from_slice(public_blob);
        let plain = cipher
            .decrypt(nonce, private_blob)
            .map_err(|e| BrokerError::SealFormat(format!("AES-GCM unseal failed: {e}")))?;
        Ok(Zeroizing::new(plain))
    }
}

// ─── Test-only helper: deterministic, parallel-safe roundtrips ─────────

#[cfg(all(test, not(feature = "tpm")))]
pub(crate) fn seal_to_path_with_machine_id_path(
    plain: &[u8],
    sealed_path: &Path,
    machine_id_path: &Path,
) -> Result<()> {
    let key = mock::derive_key(machine_id_path);
    let (pcr_bitmask, public_blob, private_blob) = mock::seal_with_key(plain, &key)?;
    write_framed(sealed_path, pcr_bitmask, &public_blob, &private_blob)
}

#[cfg(all(test, not(feature = "tpm")))]
pub(crate) fn unseal_from_path_with_machine_id_path(
    sealed_path: &Path,
    machine_id_path: &Path,
) -> Result<Zeroizing<Vec<u8>>> {
    let key = mock::derive_key(machine_id_path);
    let (_pcr, public_blob, private_blob) = read_framed(sealed_path)?;
    mock::unseal_with_key(&public_blob, &private_blob, &key)
}

// ─── Real TPM backend (feature-gated; tss-esapi v7) ────────────────────

#[cfg(feature = "tpm")]
#[allow(clippy::doc_overindented_list_items, clippy::doc_lazy_continuation)]
mod tpm {
    //! Real TPM2 sealing via tss-esapi 7.x.
    //!
    //! Concepts (per-line, so the next reader doesn't need the TCG spec):
    //!
    //! - **Hierarchy** — TPM2 has 4 fixed key trees (Owner, Endorsement,
    //!   Platform, Null). We use `Hierarchy::Owner` (a.k.a. Storage
    //!   Hierarchy / SH) which survives reboots but is wiped by a
    //!   `TPM2_Clear`. This is what tools like `tpm2-tools`/`clevis`
    //!   default to.
    //!
    //! - **Primary key (SRK)** — the root of a hierarchy's key tree, derived
    //!   deterministically from the hierarchy's seed + a public template.
    //!   We use the standard `decryption_key_pub` template from tss-esapi's
    //!   utils (RSA-2048 restricted-decrypt key, AES-256-CFB symmetric
    //!   wrap) which matches what `tpm2_createprimary -C o` produces. The
    //!   SRK is *never persisted* across calls — we re-derive it each
    //!   time, get the same key, then flush it.
    //!
    //! - **Sealed object** — a `KeyedHash` TPM object whose `sensitive`
    //!   slot holds our plaintext bytes (max 128 B per spec, but we use
    //!   `MAX_SYM_DATA = 128` worth — calling code is responsible for
    //!   chunking if needed). Sealed objects can never be loaded as keys;
    //!   they only round-trip through `TPM2_Unseal`.
    //!
    //! - **PCR policy** — instead of a password (`userWithAuth`), we bind
    //!   unsealing to the values of PCRs 0+7+8 in the SHA-256 bank:
    //!     * PCR 0 — UEFI/BIOS firmware code
    //!     * PCR 7 — Secure-Boot configuration + db/dbx + signing
    //!     * PCR 8 — kernel cmdline (measured by shim/sd-stub)
    //!   We compute the policy digest with a **trial session** at seal
    //!   time (no real TPM state involved — just a hash chain following
    //!   the policy commands), embed it as the object's `auth_policy`,
    //!   and at unseal time we run a **real policy session** that the
    //!   TPM only validates if the live PCR values still produce the
    //!   same digest. Drift (kernel update, secure-boot toggle, …) ⇒
    //!   policy mismatch ⇒ unseal refused. That's the security property.
    //!
    //! - **Transient handle hygiene** — every Esys_Create*, Esys_Load,
    //!   Esys_StartAuthSession allocates a transient handle slot. The
    //!   TPM has only 3-4 of those, so we MUST flush them before
    //!   returning, or the next call hits OUT_OF_MEMORY.
    //!     `Context` keeps a `HandleManager` that auto-flushes when
    //!     the `Context` drops, so the canonical pattern is to keep
    //!     the context narrowly scoped.

    use super::*;
    use std::convert::TryFrom;
    use tss_esapi::{
        attributes::{ObjectAttributesBuilder, SessionAttributesBuilder},
        constants::SessionType,
        handles::ObjectHandle,
        interface_types::{
            algorithm::{HashingAlgorithm, PublicAlgorithm},
            key_bits::RsaKeyBits,
            resource_handles::Hierarchy,
            session_handles::{AuthSession, PolicySession},
        },
        structures::{
            Digest, KeyedHashScheme, MaxBuffer, PcrSelectionList, PcrSelectionListBuilder, PcrSlot,
            Private, Public, PublicBuilder, PublicKeyedHashParameters, RsaExponent, SensitiveData,
            SymmetricDefinition,
        },
        tcti_ldr::{DeviceConfig, TctiNameConf},
        traits::{Marshall, UnMarshall},
        utils, Context,
    };

    /// Bitmask we bind to: PCRs 0, 7, 8 (matches the `auth_policy` we
    /// embed in the sealed object). On unseal we refuse blobs whose
    /// header advertises a different mask — defence in depth against
    /// somebody hand-rolling a blob with the policy stripped.
    pub(super) const PCR_BITMASK: u32 = (1 << 0) | (1 << 7) | (1 << 8);

    /// PCRs we lock the sealed object to, SHA-256 bank.
    fn pcr_selection() -> Result<PcrSelectionList> {
        PcrSelectionListBuilder::new()
            .with_selection(
                HashingAlgorithm::Sha256,
                &[PcrSlot::Slot0, PcrSlot::Slot7, PcrSlot::Slot8],
            )
            .build()
            .map_err(|e| BrokerError::TpmUnavailable(format!("PCR selection build failed: {e}")))
    }

    /// Open a TPM2 ESAPI context against `/dev/tpmrm0` (kernel resource
    /// manager — does NOT need root, unlike `/dev/tpm0`).
    fn open_context() -> Result<Context> {
        // `DeviceConfig::default()` points at `/dev/tpm0` (root-only).
        // We force `/dev/tpmrm0` so unprivileged users in the `tss`
        // group can use the resource manager.
        let tcti = TctiNameConf::Device(
            "/dev/tpmrm0"
                .parse::<DeviceConfig>()
                .map_err(|e| BrokerError::TpmUnavailable(format!("DeviceConfig parse: {e}")))?,
        );
        Context::new(tcti).map_err(|e| BrokerError::TpmUnavailable(format!("Esys_Initialize: {e}")))
    }

    /// Start an HMAC session, set encrypt/decrypt attrs, install it as
    /// session-1. Required by the spec for `create_primary`/`create`
    /// command audit + parameter encryption.
    fn install_hmac_session(ctx: &mut Context) -> Result<AuthSession> {
        let session = ctx
            .start_auth_session(
                None,
                None,
                None,
                SessionType::Hmac,
                SymmetricDefinition::AES_256_CFB,
                HashingAlgorithm::Sha256,
            )
            .map_err(|e| BrokerError::TpmUnavailable(format!("start HMAC session: {e}")))?
            .ok_or_else(|| {
                BrokerError::TpmUnavailable("start_auth_session returned NONE".into())
            })?;
        let (attrs, mask) = SessionAttributesBuilder::new()
            .with_decrypt(true)
            .with_encrypt(true)
            .build();
        ctx.tr_sess_set_attributes(session, attrs, mask)
            .map_err(|e| BrokerError::TpmUnavailable(format!("tr_sess_set_attributes: {e}")))?;
        ctx.set_sessions((Some(session), None, None));
        Ok(session)
    }

    /// SRK template: RSA-2048 restricted-decrypt parent under the Owner
    /// hierarchy (TCG-recommended storage primary). Same template as
    /// `tpm2_createprimary -C o -G rsa2048 -g sha256 -G aes128cfb`
    /// (within tss-esapi's defaults).
    fn srk_template() -> Result<Public> {
        utils::create_restricted_decryption_rsa_public(
            tss_esapi::abstraction::cipher::Cipher::aes_256_cfb()
                .try_into()
                .map_err(|e| BrokerError::TpmUnavailable(format!("SRK symmetric template: {e}")))?,
            RsaKeyBits::Rsa2048,
            RsaExponent::default(),
        )
        .map_err(|e| BrokerError::TpmUnavailable(format!("SRK Public template build: {e}")))
    }

    /// Compute the auth_policy digest for the seal step using a **trial
    /// session**. A trial session never touches actual PCR values — it
    /// just hashes the policy commands. We then read the resulting
    /// digest and embed it in the sealed object's `auth_policy`.
    fn compute_pcr_policy_digest(ctx: &mut Context) -> Result<Digest> {
        // Save & clear the HMAC session so the trial session starts clean.
        let saved = ctx.sessions();
        ctx.clear_sessions();

        let trial = ctx
            .start_auth_session(
                None,
                None,
                None,
                SessionType::Trial,
                SymmetricDefinition::AES_256_CFB,
                HashingAlgorithm::Sha256,
            )
            .map_err(|e| BrokerError::TpmUnavailable(format!("start trial session: {e}")))?
            .ok_or_else(|| BrokerError::TpmUnavailable("trial session NONE".into()))?;
        let (attrs, mask) = SessionAttributesBuilder::new()
            .with_decrypt(true)
            .with_encrypt(true)
            .build();
        ctx.tr_sess_set_attributes(trial, attrs, mask)
            .map_err(|e| BrokerError::TpmUnavailable(format!("trial set_attributes: {e}")))?;
        let trial_policy = PolicySession::try_from(trial)
            .map_err(|e| BrokerError::TpmUnavailable(format!("trial -> policy: {e}")))?;

        // For a trial session, `policy_pcr` requires the *expected*
        // concatenated PCR digest (per spec): hash(PCRs 0||7||8 in
        // selection order). We read live PCRs to compute it; that's
        // fine here because seal happens once and we WANT the policy
        // bound to current state.
        let pcr_sel = pcr_selection()?;
        let (_uc, _read_sel, pcr_data) = ctx
            .pcr_read(pcr_sel.clone())
            .map_err(|e| BrokerError::TpmUnavailable(format!("pcr_read for trial policy: {e}")))?;
        let bank = tss_esapi::abstraction::pcr::PcrData::create(&_read_sel, &pcr_data)
            .map_err(|e| BrokerError::TpmUnavailable(format!("PcrData::create: {e}")))?;
        let sha = bank
            .pcr_bank(HashingAlgorithm::Sha256)
            .ok_or_else(|| BrokerError::TpmUnavailable("SHA-256 PCR bank not present".into()))?;
        let mut concat = Vec::new();
        for slot in [PcrSlot::Slot0, PcrSlot::Slot7, PcrSlot::Slot8] {
            let d = sha.get_digest(slot).ok_or_else(|| {
                BrokerError::TpmUnavailable(format!("PCR slot {slot:?} not in bank"))
            })?;
            concat.extend_from_slice(d.value());
        }
        let (hashed, _ticket) = ctx
            .hash(
                MaxBuffer::try_from(concat)
                    .map_err(|e| BrokerError::TpmUnavailable(format!("hash buffer build: {e}")))?,
                HashingAlgorithm::Sha256,
                Hierarchy::Owner,
            )
            .map_err(|e| BrokerError::TpmUnavailable(format!("hash for policy_pcr: {e}")))?;

        ctx.policy_pcr(trial_policy, hashed, pcr_sel)
            .map_err(|e| BrokerError::TpmUnavailable(format!("policy_pcr (trial): {e}")))?;
        let digest = ctx
            .policy_get_digest(trial_policy)
            .map_err(|e| BrokerError::TpmUnavailable(format!("policy_get_digest: {e}")))?;

        // Trial session is now unused; flush + restore the HMAC session.
        ctx.flush_context(session_as_object_handle(trial))
            .map_err(|e| BrokerError::TpmUnavailable(format!("flush trial session: {e}")))?;
        ctx.set_sessions(saved);
        Ok(digest)
    }

    /// Convert an `AuthSession` (HMAC/Policy/Trial) to an `ObjectHandle`
    /// suitable for `flush_context`. tss-esapi 7 exposes
    /// `AuthSession -> SessionHandle -> ObjectHandle` chained `From`s.
    fn session_as_object_handle(s: AuthSession) -> ObjectHandle {
        let sh: tss_esapi::handles::SessionHandle = s.into();
        ObjectHandle::from(sh)
    }

    /// Build the `Public` template for a sealed `KeyedHash` data object
    /// bound to `policy_digest`.
    fn sealed_object_template(policy_digest: Digest) -> Result<Public> {
        // userWithAuth = false   -> no password auth, policy is mandatory
        // adminWithPolicy = true -> admin role also needs policy
        // fixedTPM + fixedParent -> can't migrate / re-parent
        // noDA                   -> not subject to dictionary-attack lockout
        let attrs = ObjectAttributesBuilder::new()
            .with_fixed_tpm(true)
            .with_fixed_parent(true)
            .with_no_da(true)
            .with_admin_with_policy(true)
            .with_user_with_auth(false)
            .build()
            .map_err(|e| BrokerError::TpmUnavailable(format!("sealed-obj attrs: {e}")))?;

        PublicBuilder::new()
            .with_public_algorithm(PublicAlgorithm::KeyedHash)
            .with_name_hashing_algorithm(HashingAlgorithm::Sha256)
            .with_object_attributes(attrs)
            .with_auth_policy(policy_digest)
            .with_keyed_hash_parameters(PublicKeyedHashParameters::new(KeyedHashScheme::Null))
            .with_keyed_hash_unique_identifier(Default::default())
            .build()
            .map_err(|e| BrokerError::TpmUnavailable(format!("sealed-obj template: {e}")))
    }

    pub(super) fn seal(plain: &[u8]) -> Result<(u32, Vec<u8>, Vec<u8>)> {
        let mut ctx = open_context()?;
        install_hmac_session(&mut ctx)?;

        // 1. Re-derive the SRK under Owner.
        let srk = ctx
            .create_primary(Hierarchy::Owner, srk_template()?, None, None, None, None)
            .map_err(|e| BrokerError::TpmUnavailable(format!("create_primary (SRK): {e}")))?
            .key_handle;

        // 2. Compute the PCR policy digest (trial session).
        let policy_digest = compute_pcr_policy_digest(&mut ctx)?;

        // 3. Create the sealed KeyedHash object under SRK with our
        //    plaintext as `sensitive_data`.
        let sensitive = SensitiveData::try_from(plain.to_vec()).map_err(|e| {
            BrokerError::SealFormat(format!(
                "plaintext too large for TPM2 sealed object ({} bytes): {e}",
                plain.len()
            ))
        })?;
        let create_res = ctx
            .create(
                srk,
                sealed_object_template(policy_digest)?,
                None,
                Some(sensitive),
                None,
                None,
            )
            .map_err(|e| BrokerError::TpmUnavailable(format!("create (seal): {e}")))?;

        // Marshall public; private has its own bytes.
        let public_blob = create_res
            .out_public
            .marshall()
            .map_err(|e| BrokerError::TpmUnavailable(format!("marshall public: {e}")))?;
        let private_blob = create_res.out_private.value().to_vec();

        // 4. Flush SRK transient handle (Context Drop also handles it,
        //    but be explicit so we don't OOM the TPM if callers stack
        //    seals in tight loops).
        ctx.flush_context(srk.into())
            .map_err(|e| BrokerError::TpmUnavailable(format!("flush SRK: {e}")))?;

        Ok((PCR_BITMASK, public_blob, private_blob))
    }

    pub(super) fn unseal(
        pcr_bitmask: u32,
        public_blob: &[u8],
        private_blob: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>> {
        // Defence-in-depth: refuse blobs not bound to the exact mask we
        // commit to. The TPM itself enforces the policy via the embedded
        // auth_policy digest, but a hand-edited header is cheaper to
        // catch up here.
        if pcr_bitmask != PCR_BITMASK {
            return Err(BrokerError::SealFormat(format!(
                "pcr_bitmask {pcr_bitmask:#b} != expected {PCR_BITMASK:#b}"
            )));
        }
        // Unmarshall public, wrap private bytes back into a Private.
        let public = Public::unmarshall(public_blob)
            .map_err(|e| BrokerError::SealFormat(format!("unmarshall public: {e}")))?;
        let private = Private::try_from(private_blob.to_vec())
            .map_err(|e| BrokerError::SealFormat(format!("Private::try_from: {e}")))?;

        let mut ctx = open_context()?;
        install_hmac_session(&mut ctx)?;

        // SRK re-derivation.
        let srk = ctx
            .create_primary(Hierarchy::Owner, srk_template()?, None, None, None, None)
            .map_err(|e| BrokerError::TpmUnavailable(format!("create_primary (SRK): {e}")))?
            .key_handle;

        // Load the sealed object.
        let sealed = ctx
            .load(srk, private, public)
            .map_err(|e| BrokerError::TpmUnavailable(format!("load sealed obj: {e}")))?;

        // Build a *real* Policy session bound to live PCR values.
        // If PCRs drift (firmware update, secure-boot toggle, kernel
        // cmdline change), `policy_pcr` succeeds but the digest no
        // longer matches what the sealed object was bound to ->
        // `unseal` returns POLICY_FAIL. That's the desired property.
        let policy_sess_handle = ctx
            .start_auth_session(
                None,
                None,
                None,
                SessionType::Policy,
                SymmetricDefinition::AES_256_CFB,
                HashingAlgorithm::Sha256,
            )
            .map_err(|e| BrokerError::TpmUnavailable(format!("start policy session: {e}")))?
            .ok_or_else(|| BrokerError::TpmUnavailable("policy session NONE".into()))?;
        let (attrs, mask) = SessionAttributesBuilder::new()
            .with_decrypt(true)
            .with_encrypt(true)
            .build();
        ctx.tr_sess_set_attributes(policy_sess_handle, attrs, mask)
            .map_err(|e| BrokerError::TpmUnavailable(format!("policy set_attributes: {e}")))?;
        let policy_session = PolicySession::try_from(policy_sess_handle)
            .map_err(|e| BrokerError::TpmUnavailable(format!("auth -> policy: {e}")))?;

        // For real (non-trial) policy sessions, passing an empty Digest
        // tells the TPM "compute the PCR digest yourself from current
        // values" — exactly what we want.
        ctx.policy_pcr(policy_session, Digest::default(), pcr_selection()?)
            .map_err(|e| BrokerError::TpmUnavailable(format!("policy_pcr (real): {e}")))?;

        // Swap the session set: the unseal call must run UNDER our
        // policy session, not the HMAC one. Save & restore.
        let saved = ctx.sessions();
        ctx.set_sessions((Some(policy_sess_handle), None, None));
        let unsealed = ctx
            .unseal(ObjectHandle::from(sealed))
            .map_err(|e| BrokerError::TpmUnavailable(format!("unseal: {e}")))?;
        ctx.set_sessions(saved);

        let plain = Zeroizing::new(unsealed.value().to_vec());

        // Flush transient handles eagerly — Context::drop would do this
        // too, but explicit is robust against panics later in the loop.
        let _ = ctx.flush_context(sealed.into());
        let _ = ctx.flush_context(srk.into());
        let _ = ctx.flush_context(session_as_object_handle(policy_sess_handle));

        Ok(plain)
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────

#[cfg(all(test, not(feature = "tpm")))]
mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom};

    /// Materialise a unique fake `machine-id` per test so parallel runs
    /// don't race on `/etc/machine-id` and roundtrips stay deterministic.
    fn fake_machine_id() -> tempfile::NamedTempFile {
        let mut f = tempfile::NamedTempFile::new().expect("temp machine-id");
        // Real machine-ids are 32 hex chars + newline; any stable bytes work.
        f.write_all(b"0123456789abcdef0123456789abcdef\n")
            .expect("write fake machine-id");
        f.flush().expect("flush fake machine-id");
        f
    }

    #[test]
    fn seal_unseal_roundtrip() {
        let plain = b"hello-fido2-vault-broker-roundtrip-test-2026";
        let mid = fake_machine_id();
        let sealed = tempfile::NamedTempFile::new().unwrap();
        seal_to_path_with_machine_id_path(plain, sealed.path(), mid.path()).unwrap();
        let got = unseal_from_path_with_machine_id_path(sealed.path(), mid.path()).unwrap();
        assert_eq!(plain, got.as_slice());
    }

    #[test]
    fn unseal_rejects_corrupt_blob() {
        let mid = fake_machine_id();
        let sealed = tempfile::NamedTempFile::new().unwrap();
        seal_to_path_with_machine_id_path(b"data", sealed.path(), mid.path()).unwrap();

        // Flip a byte well inside the private_blob (ciphertext+tag).
        // Header is 16 bytes (version+pcr+pub_len+priv_len) + 12-byte nonce
        // = 28 bytes. Anything past that is ciphertext/tag.
        let raw = std::fs::read(sealed.path()).unwrap();
        assert!(
            raw.len() > 30,
            "sealed file unexpectedly small: {}",
            raw.len()
        );
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .open(sealed.path())
            .unwrap();
        let target = raw.len() - 1; // flip the last byte (inside the GCM tag)
        f.seek(SeekFrom::Start(target as u64)).unwrap();
        f.write_all(&[raw[target] ^ 0xFF]).unwrap();
        f.sync_all().unwrap();
        drop(f);

        let res = unseal_from_path_with_machine_id_path(sealed.path(), mid.path());
        assert!(res.is_err(), "corrupt blob must not unseal");
    }

    #[test]
    fn unseal_rejects_truncated() {
        let sealed = tempfile::NamedTempFile::new().unwrap();
        // Only the version field, nothing else.
        std::fs::write(sealed.path(), FORMAT_VERSION.to_le_bytes()).unwrap();
        let mid = fake_machine_id();
        let err = unseal_from_path_with_machine_id_path(sealed.path(), mid.path())
            .expect_err("truncated file must error");
        assert!(
            matches!(err, BrokerError::SealFormat(_)),
            "expected SealFormat, got {err:?}"
        );
    }
}

// ─── Real-TPM tests ────────────────────────────────────────────────────
//
// Skip cleanly when /dev/tpmrm0 is missing (CI / VMs without TPM).
// Run with: `cargo test --features tpm` on a TPM2-equipped host.

#[cfg(all(test, feature = "tpm"))]
mod tpm_tests {
    use super::*;
    use rand::RngCore;

    /// `true` ⇒ caller should `return` early because no TPM is wired
    /// (device missing, or current user can't open it — typically the
    /// `tss` group on Linux). We treat both cases as "skip" so CI on a
    /// boxes-without-TPM and dev workstations without group membership
    /// stay green.
    fn skip_if_no_tpm() -> bool {
        let path = std::path::Path::new("/dev/tpmrm0");
        if !path.exists() {
            eprintln!("[skip] /dev/tpmrm0 not present — TPM tests skipped");
            return true;
        }
        // exists() is necessary but not sufficient — the resource manager
        // is typically mode 0660 root:tss. Probe with a bare open() so we
        // don't burn an Esys_Initialize round-trip on a permission failure.
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
        {
            Ok(_) => false,
            Err(e) => {
                eprintln!(
                    "[skip] cannot open /dev/tpmrm0 ({e}) — TPM tests skipped \
                     (add user to `tss` group to enable)"
                );
                true
            }
        }
    }

    #[test]
    fn tpm_seal_unseal_roundtrip() {
        if skip_if_no_tpm() {
            return;
        }
        // 32 bytes of fresh randomness — typical of a vault encryption key.
        let mut plain = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut plain);
        let sealed = tempfile::NamedTempFile::new().unwrap();

        seal_to_path(&plain, sealed.path()).expect("seal failed");
        let got = unseal_from_path(sealed.path()).expect("unseal failed");
        assert_eq!(plain.as_slice(), got.as_slice(), "round-trip mismatch");
    }

    #[test]
    fn tpm_unseal_rejects_wrong_pcr_bitmask() {
        if skip_if_no_tpm() {
            return;
        }
        // Seal first to grab a real public/private blob pair.
        let plain = [0xABu8; 32];
        let sealed = tempfile::NamedTempFile::new().unwrap();
        seal_to_path(&plain, sealed.path()).expect("seal failed");

        // Re-write the file with pcr_bitmask = 0 (mock-shaped).
        let raw = std::fs::read(sealed.path()).unwrap();
        // version u32 (offset 0..4), pcr_bitmask u32 (offset 4..8), rest unchanged.
        let mut tampered = raw.clone();
        tampered[4..8].copy_from_slice(&0u32.to_le_bytes());
        let bad = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(bad.path(), &tampered).unwrap();

        let err = unseal_from_path(bad.path()).expect_err("must reject wrong pcr_bitmask");
        assert!(
            matches!(err, BrokerError::SealFormat(_)),
            "expected SealFormat, got {err:?}"
        );
    }

    #[test]
    fn tpm_repeat_seal_produces_different_blob() {
        if skip_if_no_tpm() {
            return;
        }
        // Same plaintext, two seals: TPM samples a fresh nonce/symmetric
        // wrap each call, so the Private blob (and usually the Public's
        // unique field) MUST differ. If they don't, sealing is broken.
        let plain = [0x55u8; 32];
        let a = tempfile::NamedTempFile::new().unwrap();
        let b = tempfile::NamedTempFile::new().unwrap();
        seal_to_path(&plain, a.path()).expect("seal a failed");
        seal_to_path(&plain, b.path()).expect("seal b failed");

        let ra = std::fs::read(a.path()).unwrap();
        let rb = std::fs::read(b.path()).unwrap();
        assert_ne!(
            ra, rb,
            "two seals of the same plaintext produced identical blobs — TPM nonces missing?"
        );
    }
}
