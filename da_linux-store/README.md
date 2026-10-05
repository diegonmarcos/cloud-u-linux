# da_linux-store — nix-store semantics for the Linux userlands

One engine, two profiles, never mixed:

| Profile   | Machine                                   | Detected by                                          |
|-----------|-------------------------------------------|------------------------------------------------------|
| `termux`  | the phone's proot Debian                  | `uname -r` contains `android`, `TERMUX_VERSION`, or a `com.termux` `$PREFIX` |
| `desktop` | everything else that is Linux             | default                                              |

`LINUX_STORE_PROFILE` overrides detection. `cloud-store` is the **Android** app
terminal's engine and shares no code with this one: linux-store is allowed to
depend on GNU coreutils/find/mv, util-linux `flock`, `jq` and `sha256sum`, and
refuses to start without them.

## Layout

```
~/.linux-store/
├── store/<hash32>-<name>        immutable, content-addressed, shared by both profiles
├── generations/<profile>-<n>/
│   ├── bin/                     PATH: host binaries, store objects, or generated wrappers
│   ├── lib/                     .so files + script libs (never exported globally)
│   ├── etc/                     config mirrored into $HOME
│   ├── activate/                rendered files / key fragments, applied as REAL files
│   └── manifest.json            profile, every entry, every store object, declaration sha
├── current -> generations/<profile>-<n>     switched with one rename (mv -T)
├── env.sh / env.fish            put current/bin on PATH
├── dev.list                     etc paths currently linked out-of-store
└── lock                         flock: one mutating run at a time

$HOME/.claude/agents -> ~/.linux-store/current/etc/.claude/agents   (stable; the switch moves it)
```

## The declaration

The declaration is config, so it lives with the rest of the user's config in
**cloud-me_configs**, not beside the engine:

```
<git base>/cloud-me_configs/configs.json                         binds configs-user id → directory
<git base>/cloud-me_configs/A_CONFIGS-USER/a0-diego-admin/
    deb-user-configs/linux-store.json                            ← this user's declaration
```

The engine resolves it in this order:

1. `LINUX_STORE_DECLARATION`, if set.
2. `configs.json` → `LINUX_STORE_USER` (default `diego-admin`) → `<path>/deb-user-configs/linux-store.json`.
3. The path the last `apply` recorded, so `verify` and `rollback` still work while the checkout is unmounted.

The git base is `GIT_BASE`, or else the first of `~/git` (desktop) and `~/cloud-drive-shared-store/git` (phone).


`common` applies to both profiles, and `termux` / `desktop` overlay it per key:

- a profile value of `null` **removes** a common entry
- `activate.*.render` lists are concatenated, common first (so base ⊕ overlay)
- keys starting with `_` are documentation, and unknown keys or layers are errors

Each `bin` / `lib` / `etc` entry has exactly one source:

| Source  | Example                                                | Meaning |
|---------|--------------------------------------------------------|---------|
| `path`  | `{"path": "claude:agents"}`                            | copy from a repo into the store. `root:rest` resolves via `settings.roots`, a bare path via the git base, and `/abs` as is |
| `fetch` | `{"fetch": "https://…", "sha256": "…"}`                | download; refused unless the sha256 matches |
| `host`  | `{"host": "jq"}`                                       | the host provides it (apt/nix/cargo). Linked, never copied, resolved through every symlink. Not allowed in `etc`. |

Options: `exe: true` (set +x on the store copy), `entry: "bin/foo"` (path inside a
directory object), and for `bin` only `env: {…}` and `libs: [lib names]`. Either
of the last two makes linux-store generate a wrapper (makeWrapper): exported env
plus an `LD_LIBRARY_PATH` that lists store paths only. Directory libs go on the
path as they are, and single `.so` files are gathered into a `<tool>-libs` farm object.

`activate` entries are for files programs rewrite at runtime, so they are **written, not linked**:

- `render: [json…]`: deep merge (objects merged, arrays replaced), `@HOME@`
  substituted, written whole. This is the same semantics as `da_my-ai/build.sh assets` and the flakes.
- `keys: file`: that file's `.keys` object, set one top-level key at a time into
  an existing file, atomically. A missing file is left for its first run.

## Secrets (`secret` layer)

SSH keys and tokens are decrypted with **sops** while `$HOME` is being set up,
on the machine itself, using **your** age key (`SOPS_AGE_KEY_FILE`). They are
written as real files with mode `600`, and `~/.ssh` is set to `700`.

```json
"secret": {
  ".ssh/id_ed25519":      { "sops": "vault:<path>/ssh.sops.yaml", "extract": "[\"id_ed25519\"]" },
  ".config/gh/hosts.yml": { "template": "vault:<path>/gh-hosts.yml.tpl",
                            "values": { "GH_TOKEN": { "sops": "vault:<path>/github.sops.yaml",
                                                      "extract": "[\"token\"]" } } }
}
```

- **`sops`**: the decrypted value *is* the file.
- **`template`**: each `@NAME@` is replaced with its decrypted value.
- **`mode`**: defaults to `600`.

Guarantees, each covered by a test:

- **Fails before switching.** `build` decrypts every value to `/dev/null`, so a missing key or a wrong path fails before anything switches. The error names the file, never the value.
- **No secret in `~/.linux-store`.** A value is never written to `store/`, a manifest, the logs or argv. The store root is `700`, and generations record only *where* each secret comes from. A `600` `secrets.state` file holds each file's sha256, which `verify` checks along with the mode, without decrypting.
- **`repair` and `rollback` re-decrypt.** If you remove a declared secret, it is left in place with a warning. linux-store never deletes your keys.


```
linux-store apply [--backup]     build + switch + realise $HOME + verify
linux-store build [--profile p]  build only (any profile, on any machine)
linux-store verify               links, store hashes, host binaries, activated files
linux-store repair               verify, else apply
linux-store rollback             previous generation of this profile
linux-store switch <gen>         e.g. termux-3, or 3
linux-store generations | diff <a> [<b>] | gc | profile
linux-store dev [--off] <etc path>   link straight to the repo source while editing
```

## Rules it enforces

- **Atomic switch.** A generation is sealed by rename before `current` can point at it,
  and `current` changes by one `mv -T`. There is no non-atomic fallback. The test
  suite injects faults at `populate`, `seal`, `switch` and `activate` to check this.
- **Integrity by hash, not permissions.** Objects are `a-w`, but on the phone
  everything runs as root, so `verify` re-hashes every object of the live
  generation. An object edited in place is reported, and `repair` replaces it.
- **One manager per file.** A `$HOME` path that links into `/nix/store` (or sits
  under a directory that resolves there) is refused, even with `--backup`. A
  foreign real file blocks `apply` before anything switches, and `--backup` moves it aside.
- **Profiles don't cross.** You can build a desktop generation on the phone, but
  switching to it there is refused.
- **Undeclared means unlinked.** An `etc` entry dropped from the declaration is
  removed from `$HOME` on the next apply (unless it is in dev mode).

## Setup

```sh
sh da_linux-store/linux-store apply          # from the repo; afterwards it is on PATH:
echo 'source ~/.linux-store/env.fish' >> ~/.config/fish/config.fish   # or env.sh for sh/bash
```

The first apply on a machine with existing `~/.claude/agents` etc. as real
directories stops and names them. Re-run with `--backup` to move them aside.

## Tests

```sh
sh test/test-linux-store.sh     # sandboxed $HOME; never touches the real ~/.claude
```

68 checks covering profiles, every layer, idempotence (a re-apply adds zero
objects), diff/rollback/switch, fault injection at each stage, tamper detection
and repair, ownership refusals, cross-profile refusal, the fetch hash, dev mode,
removal, gc, the lock, finding the declaration through cloud-me_configs, and secrets (throwaway age key: refusal without the key, modes, no value under the store root, tamper and mode drift, repair). It takes about 5 minutes on the phone, almost all of
it jq start-up.

## Known gaps

- `activate.keys` never removes a key that was dropped from the declaration, and
  `render` replaces the whole file, so runtime edits to `settings.json` are
  reverted by `repair`. Both behave the same as the flakes.
- Wrappers `exec` the real path, so a multi-call binary that dispatches on
  `argv[0]` (busybox) should be a plain `host` entry, not wrapped.
- Names containing whitespace are not supported in entries or source paths.
- `desktop` has only been run as `build --profile desktop` on the phone. Its
  first real apply should happen on the desktop, where home-manager currently
  owns `~/.claude`. Either drop those entries from `desktop` with `null`, or
  remove them from the flake first. linux-store will refuse to take them otherwise.
