# chroot-into

Generic, host-agnostic chroot helper for the Surface Pro 8 multi-boot.

## Usage

```sh
sudo ./chroot-into.sh <target> [action]
```

### Targets

| Target | What | How resolved |
|---|---|---|
| `nixos` | NixOS root on LUKS pool, btrfs subvol `@nixos` | Auto-unlocks pool (UUID `3c75c6db-…`), mounts `/dev/mapper/pool` with `subvol=@nixos`. Also bind-mounts `@home-diego` at `/home/diego` inside the chroot. |
| `kali` | Kali root on p7 | `/dev/disk/by-uuid/509491e4-…` |
| `debian` | Debian rescue OS on p6 | `/dev/disk/by-label/rescue-os-debian` |
| ~~`kubuntu`~~ | Retired 2026-05-04 — p5 is now Shared-Lib (Docker data, not an OS) | n/a |

### Actions

- `--shell` (default) — mount + chroot into an interactive shell (prefers fish, falls back to bash/sh).
- `--mount-only` — set up mounts and exit. Lets you chroot manually.
- `--unmount` — tear down all mounts for the target.

### Examples

```sh
# Get into NixOS to fix configuration.nix
sudo ./chroot-into.sh nixos
cd ~/git/cloud-unix/aa_nixos-surface_host/src
nixos-rebuild build --flake .

# Mount Debian read-write without entering it
sudo ./chroot-into.sh debian --mount-only
ls /tmp/chroot-into/debian/

# Clean up
sudo ./chroot-into.sh debian --unmount
```

## Where it mounts

`$CHROOT_BASE/<target>` (default `/tmp/chroot-into/<target>`).

Each target gets its own subdirectory so multiple targets can be mounted concurrently without collision.

## Hosts

Tested from:
- Kali (p7)
- Debian (p6 — the rescue OS)
- NixOS (p4 LUKS pool)

The script doesn't care about the host distro — it only needs `mount`, `cryptsetup` (for nixos target), and `chroot`. All present in any base Linux.

## Overrides via env

| Variable | Default |
|---|---|
| `NIXOS_LUKS_UUID` | `3c75c6db-4d7c-4570-81f1-02d168781aac` |
| `NIXOS_MAPPER` | `/dev/mapper/pool` |
| `NIXOS_SUBVOL_ROOT` | `@nixos` |
| `NIXOS_SUBVOL_HOME` | `@home-diego` |
| `KALI_UUID` | `509491e4-d3a7-426d-9b78-4b024b24cc32` |
| `KUBUNTU_UUID` | `7e3626ac-ce13-4adc-84e2-1a843d7e2793` |
| `DEBIAN_LABEL` | `debian` |
| `CHROOT_BASE` | `/tmp/chroot-into` |

## Compared to `rescue-chroot-nixos.sh`

`rescue-chroot-nixos.sh` is the original NixOS-specific rescue helper — it sets up a minimal /etc, points at the nix store, and is meant for *building* NixOS from any Linux. This `chroot-into` is the lighter generic version: just mount + chroot, no nix-specific bootstrap. Use the rescue helper when you need to rebuild NixOS itself; use this when you just need a shell inside an installed distro.
