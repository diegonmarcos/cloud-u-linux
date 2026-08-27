//! fido2-vault-broker entrypoint.
//!
//! Subcommands:
//!   * `run` — start the daemon: BW login + sync, register a virtual FIDO2
//!     device on /dev/uhid, dispatch CTAP2 commands.
//!   * `seal` — wrap input bytes via TPM2 (or mock), write framed blob.
//!   * `unseal` — unwrap framed blob to stdout.
//!   * `version` — print crate version.
//!
//! ## Daemon (`run`) requirements
//!
//! 1. `~/.config/fido2-vault-broker/config.toml` declares `vault.endpoint`
//!    and `vault.email` (no defaults committed — operator must set).
//! 2. Master vault password is read from `FVB_MASTER_PASSWORD` env var.
//!    PoC only — Phase B.7+ will swap this for a TPM2-sealed blob unsealed
//!    at daemon start, so the password never lives in process env.
//! 3. /dev/uhid must be present. systemd unit gates on it.
//!
//! ## Known caveats (today)
//!
//! * Newly-registered passkeys are persisted to Vaultwarden via
//!   `BwBackedKeyStore` (Phase B.8) and survive a daemon restart. Counter
//!   bumps on credentials synced FROM the vault also persist: bootstrap
//!   pre-seeds the credential_id → cipher_id index from each synced cipher's
//!   server ID, so `persist_counter_bump` can address the right row.
//! * `--features fido2` is required to build the daemon path; without it,
//!   `run` exits 0 immediately with a "not built with fido2 feature" log.
//! * End-to-end browser test loop has not been validated in CI; manual
//!   verification on a real Surface + webauthn.io is the acceptance gate.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use fido2_vault_broker::store::tpm_seal;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use tracing_subscriber::{fmt, EnvFilter};

#[derive(Parser, Debug)]
#[command(
    name = "fido2-vault-broker",
    version,
    about = "Virtual FIDO2/CTAP2 authenticator backed by a Bitwarden-API vault (Phase B.1+B.2 PoC)."
)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Run the daemon. Phase B.1 stub — logs readiness and exits 0.
    Run,
    /// Seal a file: read `--in`, write framed sealed blob to `--out`.
    Seal {
        #[arg(long = "in")]
        input: PathBuf,
        #[arg(long = "out")]
        output: PathBuf,
    },
    /// Unseal a framed blob from `--in` and write the plaintext to stdout.
    Unseal {
        #[arg(long = "in")]
        input: PathBuf,
    },
    /// Print the crate version and exit.
    Version,
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).with_target(false).init();
}

/// Read `--in <path>`. If `path == "-"`, slurp stdin instead — that is the
/// no-plaintext-on-disk path used by `build.sh seal-master`.
fn read_input_or_stdin(path: &Path) -> std::io::Result<Vec<u8>> {
    if path == Path::new("-") {
        let mut buf = Vec::new();
        std::io::stdin().read_to_end(&mut buf)?;
        Ok(buf)
    } else {
        std::fs::read(path)
    }
}

/// Convert a B.3 `PasskeyCipher` (the on-vault representation) into the
/// B.4 `PasskeyCredential` (the in-memory CTAP2 representation). Discards
/// fields the CTAP2 layer doesn't consume (rp_name, key_algorithm,
/// key_curve, discoverable). The PKCS#8 buffer is moved out of the
/// `Zeroizing` wrapper — the new owner (`PasskeyCredential`) zeroes on Drop.
#[cfg(feature = "fido2")]
fn cipher_to_credential(
    p: fido2_vault_broker::store::bw_api::PasskeyCipher,
) -> fido2_vault_broker::ctap2::PasskeyCredential {
    fido2_vault_broker::ctap2::PasskeyCredential {
        credential_id: p.credential_id,
        rp_id: p.rp_id,
        user_handle: p.user_handle,
        user_name: p.user_name.unwrap_or_default(),
        user_display_name: p.user_display_name.unwrap_or_default(),
        key_pkcs8: (*p.private_key_pkcs8).clone(),
        counter: p.counter,
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();
    let cli = Cli::parse();
    match cli.command {
        Cmd::Run => run_daemon().await,
        Cmd::Seal { input, output } => {
            // `--in -` reads stdin (used by `build.sh seal-master` so the
            // master password never touches disk in plaintext).
            let plain = read_input_or_stdin(&input)
                .with_context(|| format!("read input {}", input.display()))?;
            tpm_seal::seal_to_path(&plain, &output)
                .with_context(|| format!("seal -> {}", output.display()))?;
            tracing::info!(?output, bytes = plain.len(), "sealed");
            Ok(())
        }
        Cmd::Unseal { input } => {
            let plain = tpm_seal::unseal_from_path(&input)
                .with_context(|| format!("unseal {}", input.display()))?;
            std::io::stdout()
                .write_all(plain.as_slice())
                .context("write plaintext to stdout")?;
            Ok(())
        }
        Cmd::Version => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Daemon path (Phase B.7 — wire up B.3 + B.4 + B.5/B.6 + TPM2/mock from B.1).
//
// Default builds (no `fido2` feature) ship a stub that logs and exits 0
// so `cargo build` works on systems without libudev/libclang. The real
// path is gated behind `--features fido2`.
// ─────────────────────────────────────────────────────────────────────

#[cfg(not(feature = "fido2"))]
async fn run_daemon() -> Result<()> {
    tracing::info!(
        "fido2-vault-broker daemon path requires `--features fido2`; \
         today's build only exposes seal/unseal/version. \
         Rebuild with: cargo build --release --features fido2"
    );
    Ok(())
}

#[cfg(feature = "fido2")]
async fn run_daemon() -> Result<()> {
    use fido2_vault_broker::config::Config;
    use fido2_vault_broker::ctap2::{derive_aaguid, Authenticator, KeyStore};
    use fido2_vault_broker::store::bw_api::BwClient;
    use fido2_vault_broker::store::bw_keystore::{BwBackedKeyStore, BwPersist};
    use fido2_vault_broker::uhid_dev::UhidServer;
    use fido2_vault_broker::up_prompt::DesktopUpProvider;
    use secrecy::SecretString;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::Mutex;

    // ── 1. Load operator-side config (vault endpoint + account identifier) ──
    let cfg = Config::load().context("load config (~/.config/fido2-vault-broker/config.toml)")?;
    if cfg.vault_endpoint.trim().is_empty() {
        anyhow::bail!(
            "vault.endpoint is empty — set it in ~/.config/fido2-vault-broker/config.toml"
        );
    }
    if cfg.vault_email.trim().is_empty() {
        anyhow::bail!("vault.email is empty — set it in ~/.config/fido2-vault-broker/config.toml");
    }
    tracing::info!(endpoint = %cfg.vault_endpoint, "config loaded");

    // ── 2. Master password — TPM-unseal preferred, env-var fallback ──
    //
    //   * Preferred: `cfg.master_blob_path` (created by `build.sh seal-master`,
    //     symlinked from `vault/fido/master.tpm-sealed`). Plaintext never
    //     touches a process env or the shell history.
    //   * Fallback (PoC / first-boot): `FVB_MASTER_PASSWORD` env var.
    //
    // The fallback path stays so the daemon is bootstrappable on a machine
    // without a sealed blob yet — operator runs once with the env var, then
    // `build.sh seal-master` writes the blob and removes the env-var crutch.
    let master = if cfg.master_blob_path.exists() {
        let plain = tpm_seal::unseal_from_path(&cfg.master_blob_path).with_context(|| {
            format!(
                "unseal master blob {} (TPM unavailable? wrong PCRs? corrupt?)",
                cfg.master_blob_path.display()
            )
        })?;
        String::from_utf8(plain.as_slice().to_vec()).context("sealed master blob is not UTF-8")?
    } else {
        tracing::warn!(
            path = %cfg.master_blob_path.display(),
            "master blob missing; falling back to FVB_MASTER_PASSWORD env var (run `build.sh seal-master` to remove this fallback)"
        );
        std::env::var("FVB_MASTER_PASSWORD").context(
            "FVB_MASTER_PASSWORD env var not set and no TPM-sealed master blob \
             found at the configured path — run `build.sh seal-master` first",
        )?
    };
    if master.is_empty() {
        anyhow::bail!("master password is empty");
    }

    // ── 3. Login + sync vault. The BwClient must be shared between the
    //       (eventual) sync loop and the keystore write-through hooks, so we
    //       wrap it in `Arc<Mutex<_>>` from the outset. ──
    let mut bw = BwClient::new(&cfg.vault_endpoint, &cfg.vault_email);
    bw.login(SecretString::new(master))
        .await
        .context("vault login")?;
    let ciphers = bw.sync().await.context("vault sync")?;
    tracing::info!(count = ciphers.len(), "synced passkey ciphers");
    let bw_arc: Arc<Mutex<dyn BwPersist>> = Arc::new(Mutex::new(bw));

    // ── 4. Build the write-through keystore and seed it with the synced
    //       ciphers via the in-memory `inner` borrow. Ciphers loaded from
    //       sync are ALREADY in the vault, so we go through `inner_mut` to
    //       skip the `persist_new_credential` round-trip and avoid creating
    //       a duplicate row server-side. ──
    let mut keystore = BwBackedKeyStore::new(bw_arc.clone());
    for c in ciphers {
        // Pre-seed the credential_id → cipher_id index BEFORE `c` is consumed
        // by `cipher_to_credential`. Without this, a counter bump on a passkey
        // synced from the vault (i.e. every passkey after a restart) would fail
        // `persist_counter_bump` with "no cipher_id recorded" — the index is
        // how the write-through hook addresses the right server row.
        match c.cipher_id.clone() {
            Some(cipher_id) => {
                keystore.record_existing_cipher_id(c.credential_id.clone(), cipher_id);
            }
            None => {
                tracing::warn!(
                    rp_id = %c.rp_id,
                    "synced passkey has no server cipher_id; counter bumps will not persist for it"
                );
            }
        }
        let cred = cipher_to_credential(c);
        if let Err(e) = keystore.inner_mut().store_new_credential(cred) {
            tracing::warn!(error = ?e, "failed to load credential into keystore — skipping");
        }
    }

    // ── 5. AAGUID = SHA-256(machine_id || vault_email) → 16 bytes (UUID-v4 shape) ──
    let machine_id = std::fs::read_to_string("/etc/machine-id")
        .context("read /etc/machine-id (required for stable AAGUID)")?;
    let aaguid = derive_aaguid(machine_id.trim().as_bytes(), &cfg.vault_email);

    // ── 6. Wire authenticator + UP prompt ──
    let up = Box::new(DesktopUpProvider::new(Duration::from_secs(30)));
    let auth = Arc::new(Mutex::new(Authenticator::new(
        aaguid,
        Box::new(keystore),
        up,
    )));

    // ── 7. Run uhid HID server with a callback that delegates CTAP2
    //       commands to the authenticator. The callback is sync; we bridge
    //       to async via Handle::block_on under block_in_place (multi-thread
    //       runtime — see #[tokio::main] above). ──
    let auth_for_cb = auth.clone();
    let on_cbor = move |cmd: u8, payload: &[u8]| -> Vec<u8> {
        let auth = auth_for_cb.clone();
        let payload = payload.to_vec();
        tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(async move {
                let mut a = auth.lock().await;
                a.handle_command(cmd, &payload).await
            })
        })
    };

    let mut uhid = UhidServer::new(aaguid);
    tracing::info!("starting /dev/uhid server — register with browser via webauthn.io to test");
    uhid.run(on_cbor).await.context("uhid server")?;

    Ok(())
}
