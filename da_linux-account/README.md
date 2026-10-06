# da_linux-account — cloud-superapp's Account tab, for the Linux userlands

`linux-account` is `aa_cloud-superapp`'s **ProfileFragment** as a CLI + TUI:
the same five tabs, the same four-step journey, the same cockpit rows and
lights, the same two-pass apply. It sits on top of `linux-store` the way the
app sits on top of its prefs: everything it declares is realised, checked,
rolled back and repaired by the store.

```
linux-account tui
┌─ linux-account ─ Account ──────────────────────┐
  ● 1 Sign in        vault checkout
  ● 2 Who            me@diegonmarcos.com
  ● 3 Which device   galaxy
  ● 4 Get everything applied 2026-10-05T18:30:00Z on galaxy
└────────────────────────────────────────────────┘
  1) Fleet      2) Connect      3) Infos      4) WireGuard  5) AI  6) Apps
```

## The bundle

`cloud-me_vault/C_A1-configs/profile-secrets.json` — the ONE consolidated
profile (schema 1): `mesh`, `mail`, `ai`, `git`, `about`, `autocomplete`,
`electronics`, `settings`. The same file the phone imports.

| Route | Verb | Like the app's |
|---|---|---|
| sibling checkout | `connect` / `connect --vault` | — (the phone has no checkout) |
| decrypted export | `connect --file <p>` | Import from a file |
| GitHub contents API, with gh's token | `connect --github` | the GitHub token tile |
| Authelia bearer | `connect --bearer <t>` | sign in · bearer |
| mailed one-time code | `connect --code`, then `--code <c>` | Vault connect |

Gates, as in `VaultFile.classify` / `VaultConnect`: a sops-encrypted file is
refused, `schema_version` must be known (`1`), nothing is applied by a fetch.

## The journey (Connect)

1. **Sign in** — `connect …` finds the bundle.
2. **Who** — `who [<email>]`: identities from `cloud-infra`'s `superapp-users.json` registry (or the bundle's `about.profile`). Only the email is stored.
3. **Which device** — `device [<id>]`: the peers of `electronics.fleet`; defaults from the linux-store profile (termux → `galaxy`, desktop → `surface`).
4. **Get everything** — `plan` shows every section's write; `apply` does it.

## Apply: plan, then commit (ConfigAutoImport)

`plan` prints one line per intended write and touches nothing. `apply`:

- **Declares** every secret that is a *file in the vault*: `.ssh/id_rsa(.pub)`,
  `.config/gh/hosts.yml` (template + the token file), the device's WireGuard
  profiles (`<PROVIDED_BY_DEVICE>` spliced from the device's `privatekey`, as
  the app splices its stored key). These go into
  `deb-user-configs/account.json` — **paths only, committable** — which
  `linux-store.json` includes (`settings.include`). Then `linux-store switch`.
- **Writes directly** (0600 under `~/.config/linux-account/`) what exists only
  in the bundle: `secrets/ai.env`, `secrets/mail.env` (the identity's account),
  `secrets/autocomplete/*.json`, `fleet.json`, `repos.json`, the contact card
  seed; plus `~/.ssh/config.d/fleet` (Host entries for every mesh node — the
  fleet "DNS" of a Linux box). Each file's sha256 is recorded for the cockpit.
- Reports `settings` (all pending), `apps` (staged), unknown sections — never dropped silently.
- **Tokens** (`deb-user-configs/tokens.json`, the ONE declaration of ALL my
  tokens, by provider — github, oci, cloudflare, nocodb, c3-api, resend,
  crawlee, authelia (one per bearer), anthropic, google-oauth, wireguard
  (this device's key, `{device}`), ssh): every real entry is DECLARED through
  the store's secret layer — keyfiles at their `~/path` (0600 unless `mode`),
  env-file and value entries spliced by linux-store into ONE
  `~/.config/linux-account/secrets/tokens.env` (0600, `export NAME=value`)
  from the names-only template `src/tokens.env.tpl` (values with
  `"export": true` turn a vault `.env` into export lines). Entries whose
  vault file is a stub (`***REMOVED***`, empty, a `../` link stub with no
  target) or declared `pending: true` are reported with their reason and
  never written. Interactive shells source tokens.env when readable
  (`src/env.json` `source`); `AUTHELIA_OIDC_*_DIR` point at the realised
  files. `dash tokens` lists names + pending reasons; nothing ever prints a value.

## Fleet: the cockpit

`fleet [-v]` draws one card per section, rows `MATCH / DIFFERS / ABSENT /
PENDING`, light per `VaultCockpit.sectionLight`: not observed → UNVERIFIABLE,
no rows → UNKNOWN, any DIFFERS/ABSENT → OFF, any MATCH → ON. Comparison is by
sha256 only; no value is ever printed. Drawing never writes.

| Card | Declared vs device |
|---|---|
| Mail | the identity's account env; JMAP host |
| Keyboard & Clipboards | autocomplete lists (unverifiable, as in the app) |
| Mesh | each WireGuard profile of this device; fleet ssh hosts |
| Drive (private repos) | github token in `gh`, ssh key, repos checked out |
| AI | tokens env; `ANTHROPIC_API_KEY` in this shell |
| Tokens | every tokens.json entry: keyfile or its name in tokens.env, by sha256 against linux-store's secrets.state; stubs PENDING with the reason |
| Apps | linux-store `bin` entries resolvable |
| Raw | settings, peers |

## Infos: the contact card

`infos` / `infos set name=… email=… birth=DD-MM-YYYY …` (8 fields, DOB
converted to ISO on set). `infos push` POSTs the ProfileSync document
(`X-Install-Id` + bearer install secret, generated once, 8-field allowlist)
to `c3-infra-api/fleet/profile`; 429/5xx/offline are queued, `infos flush`
retries; `infos erase` DELETEs with the credential first, then rotates the
install id. No credential ever enters the document.

## Bootstrap: the engine that clones, authenticates and fetches

A box with nothing on it:

```sh
linux-account signin            # GitHub device flow (gh auth login -w); or --token <ghp_…>
linux-account connect --github  # the bundle, over the contents API with that login
linux-account who / device
linux-account apply             # ssh key + github token + WireGuard land, declaratively, via linux-store
linux-account repos clone       # every private repo of the fleet into the git base (ssh once the key is in)
```

`repos list|clone|pull` covers `cloud-me_configs`, `cloud-me_vault`, `cloud-u-linux` plus the bundle's
`git.repos`; on a FUSE git base it sets `core.createObject=rename` on each clone.

## Links

`wg [list|up|down]`, `ai`, `apps [compare|export]` (AppInventory-shaped
`linux-account.app-inventory`).

## The page

`linux-account html` writes `~/.linux-store/ui/account.html` beside the Store page — the journey's four
lights, every cockpit card with its rows and light, the contact card — reusing the Store page's stylesheet.
`linux-store serve` serves both.

## Tests

```sh
sh test/test-linux-account.sh
```

A sandboxed HOME with a fake bundle, fake vault files and a fake
cloud-me_configs: refusals (encrypted, unknown schema), the journey, plan
writes nothing, apply declares + writes + switches, no value leaks into the
store or the config repo, cockpit states and lights, tamper → DIFFERS, remove →
ABSENT, `linux-store repair` → MATCH, infos set/push-queue/erase, apps export,
tui.
