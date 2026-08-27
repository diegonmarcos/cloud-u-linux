# fido2-vault-broker

Linux daemon that exposes a virtual FIDO2/CTAP2 USB authenticator on
`/dev/uhid`, backed by a Bitwarden-API vault (Vaultwarden). Replaces a
hardware key + a per-browser Bitwarden extension when the only thing you
actually need from the extension is WebAuthn signing.

```
  ┌──────────┐    HID over /dev/uhid      ┌──────────────┐
  │ Browser  │ ◀───────────────────────▶  │ this daemon  │
  └──────────┘   CTAPHID frames + CBOR    └──────┬───────┘
                                                 │ Bitwarden REST + crypto
                                                 ▼
                                          ┌──────────────┐
                                          │ Vaultwarden  │
                                          └──────────────┘
```

## What's where

| | Where | Why |
|---|---|---|
| **Code, flake, build engine, templates** | `~/git/cloud-unix/da_fido2-vault-broker/` (public repo) | declarative + reproducible |
| **Real `config.toml`, sealed master, sealed cipher cache** | `~/git/cloud-vault/fido/` (private repo) | secrets live in vault, never in `~/.config/` directly |
| **Symlinks `~/.config/...` → `vault/fido/...`** | created by `build.sh deploy` | XDG paths point at the vault |

You **never** edit `~/.config/fido2-vault-broker/` by hand. You edit
`vault/fido/`; `build.sh deploy` projects it.

## Operator path (one shot)

```bash
cd ~/git/cloud-unix/da_fido2-vault-broker
./build.sh build              # cargo --release inside nix dev shell
./build.sh init-vault         # scaffold vault/fido/ from src/templates/
$EDITOR ~/git/cloud-vault/fido/config.toml   # set vault_endpoint + vault_email
./build.sh seal-master        # prompts for password, TPM-seals to vault/fido/master.tpm-sealed
./build.sh deploy             # symlinks vault/fido/* into XDG + udev rule
sudo usermod -aG uhid,tss $USER && newgrp uhid    # one-time group add
./build.sh install            # binary + systemd user unit
./build.sh enable             # systemctl --user enable --now
journalctl --user -u fido2-vault-broker -f        # watch
```

`./build.sh ship` runs `build → install → deploy → enable` in one go
(after `init-vault` + `seal-master` + groups).

## Browser smoke test

1. Open <https://webauthn.io>.
2. Pick a username, click *Register*.
3. Browser asks the OS for an authenticator → finds the virtual FIDO2 on
   `/dev/uhid` → daemon pops a `notify-send` confirm dialog.
4. Click *Confirm* → browser receives attestation → site shows green.
5. Reload, *Authenticate*, same flow → green again.

If step 3 doesn't trigger: check `journalctl --user -u fido2-vault-broker`
for "starting /dev/uhid server". If absent, you're not in the `uhid`
group or udev didn't reload — re-run `./build.sh deploy`.

## Status (2026-05-09)

| Phase | What | State |
|---|---|---|
| B.1 | scaffold + Config | done |
| B.2 | mock TPM seal/unseal | done |
| B.2-hw | real TPM2 seal/unseal (PCR 0+7+8) | done (`--features tpm`) |
| B.3 | Bitwarden REST client (PBKDF2/Argon2id, AES-CBC+HMAC) | done |
| B.4 | CTAP2 Authenticator (P-256 + AAGUID + InMemoryKeyStore) | done |
| B.5 | uhid HID server (CTAPHID frames, channels, fragmentation) | done |
| B.6 | DesktopUpProvider (notify-send confirm/cancel) | done |
| B.7 | daemon integration + TPM-unseal master | done |
| B.8 | passkey writeback to Vaultwarden | done |

B.8 has landed: registrations are pushed to Vaultwarden on `makeCredential`
and survive a daemon restart, and signature-counter bumps persist for both
session-registered and vault-synced passkeys (bootstrap pre-seeds the
credential_id → cipher_id index from each synced cipher's server ID).

## Tests

```bash
./build.sh test               # 43+ tests, default + --features fido2
./build.sh check              # fmt + clippy -D warnings + check
```

The `--features tpm` test set adds 3 hardware tests; they skip cleanly
when `/dev/tpmrm0` is absent or the user isn't in the `tss` group.

## Files

| Path | Role |
|---|---|
| `build.json` | Single source of truth — binary name, features, deploy paths, symlink table, udev rule |
| `build.sh` | Engine — every command consumes `build.json`; never hardcodes |
| `src/Cargo.toml`, `src/flake.nix` | Rust + nix dev shell (linux-headers, glibc.dev, libclang) |
| `src/src/main.rs` | Entrypoint: `run` (daemon), `seal --in - --out`, `unseal`, `version` |
| `src/src/config.rs` | XDG config + sealed/master blob path defaults |
| `src/src/store/bw_api.rs` | Bitwarden REST client, EncString crypto |
| `src/src/store/tpm_seal.rs` | Mock + real TPM2 backend (tss-esapi, PCR-bound) |
| `src/src/ctap2.rs` | Authenticator, KeyStore trait, AAGUID, P-256 sign |
| `src/src/uhid_dev.rs` | CTAPHID server over /dev/uhid (channels, frames) |
| `src/src/up_prompt.rs` | notify-send confirm/cancel UP provider |
| `src/templates/config.toml.example` | Operator template, copied into vault by `init-vault` |
| `src/templates/70-fido2-vault-broker.rules` | udev rule template, installed by `deploy` |
| `src/systemd/fido2-vault-broker.service` | User unit, `Type=notify`, `MemoryMax=64M` |

## Security notes

- **Master password**: TPM2-sealed at rest in `vault/fido/master.tpm-sealed`,
  PCR-bound (0+7+8) under `--features tpm`. Mock backend (default) uses
  HKDF-SHA256 over `/etc/machine-id` — **PoC only, not production**.
- **Vault CipherString crypto**: AES-256-CBC + HMAC-SHA256 (Bitwarden type 2),
  symmetric key derived via PBKDF2 (or Argon2id) + HKDF-stretch.
- **Plaintext lifetime**: master never reaches a process env or the shell
  history — `seal-master` reads stdin with `stty -echo` and pipes directly
  to the binary; the binary holds it in `Zeroizing<Vec<u8>>` then drops.
- **AAGUID**: deterministic, derived from `SHA-256(machine-id || vault_email)`
  → 16 bytes (UUID-v4 shape). Stable across reinstalls of the same machine.

## Why it's safer than a hardware key

Hardware keys are stolen physical objects — drop your laptop bag, lose your
passkeys. This daemon's secrets are PCR-bound to the boot chain: a different
kernel, a different bootloader, a different TPM, and unseal fails. Restoring
from a vault export brings the *passkeys* back; rebinding to a new TPM
needs a fresh `seal-master` + re-registration on each site.
