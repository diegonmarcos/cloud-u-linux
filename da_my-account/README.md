# da_my-account: the desktop counterpart of cloud-account.apk

my-account HOLDS the user's config data, one folder per application, and DEPLOYS it
into non-mobile applications: the user-scope job Nix home-manager does today
(not OS/system config). Sibling of `da_linux-account` (the CLI of the Account journey)
and `da_my-ai`.

**Redundant for now.** The home-manager flakes (`cloud-me-pvt-configs`:
`A_CONFIGS-USER/a1-diego-user/nix-hm-flakes/ba_flakes_desktop` and
`B_CONFIGS-MACHINES/_shared/nix-os-flakes/bb_flakes_termux`) keep deploying and are
unchanged. Everything here is a COPY; nothing was moved. A target that is a symlink into
`/nix/store` is skipped ("managed by home-manager"), a differing plain file is reported
and left alone unless `--force` (then backed up as `<file>.my-account.bak`).

## Use

```
sh my-account                    # dry-run: prints the plan, writes nothing
sh my-account --apply            # write new files
sh my-account --apply --force    # also replace differing files (with backup)
sh my-account --profile termux --app fish
```

Profile is `termux` when `$PREFIX` is a Termux prefix, else `desktop`; `MY_ACCOUNT_HOME`
overrides `$HOME` (tests use it). Plain POSIX sh; no build step.

## Layout

`<app>/manifest` plus the app's files. Apps: fish, git, tmux, starship, vim, gh, goose,
gemini, node, kde (incl. plasmoids), konsole, dev-shell, hm-auto-update,
home-manager-command-catcher, wg-dns, wireguard-wstunnel, flakes-switch, mem-reclaim,
my-webserver, curl-wget-wrapper, sops, tokens, claude.

Manifest = TAB-separated: `kind  variants  source  target  flake_src`.

| kind | meaning |
|---|---|
| `file` / `dir` | deployed to `$HOME/<target>`; `variants` = `desktop`, `termux` or both |
| `inline` | held only: home-manager inlines or nix-wraps it, so there is no direct file target yet |
| `secret` | private file in the private repo `cloud-me-pvt`; only its path is here (`me:<path>`) |
| `sops` | reference to a sops-encrypted path of the flakes; never copied |
| `canon` | held copy whose canonical home and deployer is elsewhere |

`flake_src` is where the content comes from: `cmc:<path in cloud-me-pvt-configs>` (comma
list when desktop and termux are byte-identical, otherwise two entries, the termux
source under `<app>/termux/`) or `lin:<path in cloud-u-linux>`.

## Secrets (this repo is public)

Nothing private is stored here: no tokens, keys, ssh/gpg material, passwords, private
hostnames or IPs (mesh bootstrap, wg-dns, goose and gemini MCP endpoints, the fish init
with the auth host, the tokens template were left out and are `secret` entries), no
sops-encrypted files. A `secret` entry names `me:my-account/<app>/<file>` in `cloud-me-pvt`.
At `--apply` the value is resolved, first match wins:

1. local clone of `cloud-me-pvt`: `$MY_ACCOUNT_ME_DIR`, else `$GIT_BASE`, `~/git`,
   `~/git-repos`, `~` + `/cloud-me-pvt`;
2. `cloud-me-api` (read-only; contract in `infra-api_cloud-me-api` of cloud-u-containers):
   `GET <base>/repos/cloud-me-pvt/file?path=<path>` returns the file as `text/plain`, with
   `Authorization: Bearer $MY_ACCOUNT_ME_TOKEN` (the fleet bearer; a GitHub token is not
   accepted). `<base>` = `$MY_ACCOUNT_ME_API` alone when set, else mesh first
   (`http://cloud-me-api.mesh.diegonmarcos.com:8124/me`), then c3-pvt
   (`https://c3-pvt.diegonmarcos.com/cloud-me-api/me`). The token goes to curl on stdin,
   never argv. The service must declare the `cloud-me-pvt` repo and serve `my-account/` paths
   (owner step, see ticket); until then only the local clone resolves.

The dry-run only names the source that would be used (`cloud-me-pvt clone`, `cloud-me-pvt api`
or `UNRESOLVED`). Values are written 0600 and never printed. The paths exist in `cloud-me-pvt` as
placeholders (`# owner: fill in`); the owner fills in the values.

## claude/ (canonical copy: my-ai)

`claude/` is a copy of `da_my-ai/data/claude`. **The canonical copy is my-ai**, which
stays the deployer (engine `claude-config`) until the owner says otherwise; edit there,
then refresh this copy. The test fails on drift.

## Tests

`sh da_my-account/test/test-my-account.sh`: every manifest entry has a source (secret
entries must have none), every held file is declared, no secret-like file, drift against
`lin:` sources (always) and `cmc:` sources (when a `cloud-me-pvt-configs` checkout is found
via `MY_ACCOUNT_CMC` or a sibling dir; otherwise SKIP with a notice, FAIL with
`MY_ACCOUNT_STRICT=1`), a sandboxed deploy round trip, and the secret resolution
(fake local `cloud-me-pvt`, mocked API, values never printed). CI (`test-my-account.yml`)
runs it without the `cmc:` checkout.
