#!/usr/bin/env bash
# my-watchdog — fetch the GHA-built binary. Never compiles locally: the Rust
# build is heavy and the freeze-guard on this laptop exists because of exactly
# that kind of job.
set -euo pipefail
C='\033[0;36m'; N='\033[0m'
say() { printf "${C}[my-watchdog]${N} %s\n" "$*"; }

REPO=diegonmarcos/cloud-u-linux
TAG=my-watchdog-latest
BIN=my-watchdog
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/my-konsole"
LINK="$HOME/.local/bin/$BIN"

# The observation capabilities, and only those.
#
# Unprivileged, this daemon cannot read /proc/<pid>/io or smaps_rollup for a
# process it does not own, cannot map a socket to a pid that is not its own,
# and cannot read the firewall ruleset. On a box whose real workload runs as
# root in containers that is most of the machine: the panel showed 17% io.full
# and a column of dashes where the process causing it should have been.
#
# A file capability rather than running as root, and rather than a system unit.
# It is the same read powers with none of the rest of root, and — the part that
# matters operationally — the daemon keeps its uid, so the snapshot and the
# mailbox stay owned by the user who owns the session. The mailbox is appended
# to by the panel; a root-owned one would be a mailbox the panel cannot post to.
#
# cap_sys_ptrace       /proc/<pid>/io, smaps_rollup, /proc/<pid>/fd for any pid
# cap_dac_read_search  the paths guarding them
# cap_net_admin        the nft ruleset the firewall page reports as unreadable
CAPS="cap_sys_ptrace,cap_dac_read_search,cap_net_admin+ep"

grant_caps() { # host -> apply on a remote box, empty -> apply here
  local h="$1" cmd="setcap $CAPS \"\$1\" 2>/dev/null || sudo -n setcap $CAPS \"\$1\" 2>/dev/null"
  if [ -z "$h" ]; then
    # The real file, never the symlink: setcap follows nothing and an xattr on
    # a symlink is not read by anything.
    local target; target="$(readlink -f "$LINK" 2>/dev/null || echo "$LINK")"
    setcap "$CAPS" "$target" 2>/dev/null || sudo -n setcap "$CAPS" "$target" 2>/dev/null || {
      say "could not grant capabilities — run: sudo setcap $CAPS $target"
      say "  without them per-process io, PSS and the firewall page stay blank"
      return 0
    }
    say "granted $CAPS"
  else
    ssh -o BatchMode=yes "$h" bash -s <<EOF
      if sudo -n setcap '$CAPS' ~/.local/bin/$BIN 2>/dev/null; then
        echo "  capabilities granted"
      else
        echo "  NO capabilities — run: sudo setcap $CAPS ~/.local/bin/$BIN"
      fi
EOF
  fi
}


case "${1:-fetch}" in
  fetch)
    mkdir -p "$DEST" "$(dirname "$LINK")"
    say "Fetching $BIN from $TAG…"
    # mktemp + mv: writing over a running binary is ETXTBSY, and rename(2) is
    # the only way to swap one out from under a live process safely.
    tmp="$(mktemp "$DEST/.$BIN.XXXXXX")"
    gh release download "$TAG" --repo "$REPO" --pattern "$BIN" --output "$tmp" --clobber
    chmod +x "$tmp"
    mv -f "$tmp" "$DEST/$BIN"
    ln -sf "$DEST/$BIN" "$LINK"
    # THE NAME THE MACHINE ACTUALLY RUNS. my-watchdog.service has always said
    # ExecStart=%h/.local/bin/watchdog-d and my-konsole's `watchdog` launcher
    # has always exec'd ~/.local/bin/watchdog-tui, while the release artifacts
    # are my-watchdog and my-watchdog-tui — so fetch installed two files
    # nothing started and left the two that everything starts frozen at
    # whatever build first put them there. A daemon from September ran for a
    # day after four successful updates, and the panel kept rendering a fixed
    # bug. Linking the names here means one artifact, every caller.
    ln -sf "$DEST/$BIN" "$(dirname "$LINK")/watchdog-d"
    # The panel, beside the daemon it reads. Best-effort: the fleet artifacts
    # are the sampler alone (no tui feature), so a box that has no panel to
    # download is a normal headless box and not a failure.
    tui_tmp="$(mktemp "$DEST/.$BIN-tui.XXXXXX")"
    if gh release download "$TAG" --repo "$REPO" --pattern "$BIN-tui" --output "$tui_tmp" --clobber 2>/dev/null; then
      chmod +x "$tui_tmp"
      mv -f "$tui_tmp" "$DEST/$BIN-tui"
      ln -sf "$DEST/$BIN-tui" "$(dirname "$LINK")/$BIN-tui"
      ln -sf "$DEST/$BIN-tui" "$(dirname "$LINK")/watchdog-tui"
      say "panel: $BIN-tui"
    else
      rm -f "$tui_tmp"
      say "no $BIN-tui in $TAG (headless build) — daemon only"
    fi
    # A file capability is an xattr on the INODE, so replacing the binary drops
    # it — every fetch silently un-privileges the daemon. That is why the
    # firewall page went blank after an update and stayed blank: nft list
    # ruleset needs CAP_NET_ADMIN, and the new inode had none. Re-granted here
    # rather than only in `install`, because fetch is what people actually run
    # to update, and a capability that survives installation but not updates is
    # one nobody has for long.
    grant_caps ""
    # The policy travels with the binary. One source of truth means every
    # machine resolves the same document, so it has to actually arrive on
    # every machine.
    mkdir -p "$HOME/.config/my-watchdog"
    install -m644 "$(dirname "$0")/configs/watchdog-policy.json" \
      "$HOME/.config/my-watchdog/watchdog-policy.json" 2>/dev/null || true
    say "Fetched → $DEST/$BIN (restart my-watchdog to load it)"
    ;;
  install)
    # Fetch, then run it as a user service. Separate from `fetch` because
    # fetching a binary and enrolling it in systemd are different decisions,
    # and the second one should be asked for.
    "$0" fetch
    mkdir -p "$HOME/.config/systemd/user"
    unit=my-watchdog.service
    # A headless box has no graphical-session.target to hang off, and a unit
    # that WantedBy a target which never activates simply never starts.
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || unit=my-watchdog-headless.service
    install -m644 "$(dirname "$0")/$unit" "$HOME/.config/systemd/user/my-watchdog.service"
    systemctl --user daemon-reload
    grant_caps ""
    systemctl --user enable --now my-watchdog.service
    say "Installed and started ($unit)."
    ;;

  deploy)
    # Push it to every mesh peer in ~/.ssh/config. The peers are aarch64 and
    # x86_64 both, so the right artifact is chosen per host from uname -m
    # rather than assumed.
    shift || true
    # One host per ADDRESS: the config gives several aliases per machine
    # (a -dropbear twin, a claude_ prefix), and deploying to the same box four
    # times under four names is four copies of the same scp.
    hosts="${*:-$(awk '/^Host /{h=$2}
      /HostName[ =]+10\.0\.0\./{ if (h !~ /dropbear/ && !(seen[$2]++)) print h }' "$HOME/.ssh/config")}"
    for h in $hosts; do
      arch=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$h" 'uname -m' 2>/dev/null) || {
        say "$h: unreachable, skipped"; continue; }
      case "$arch" in
        aarch64|arm64) asset="$BIN-aarch64" ;;
        x86_64)        asset="$BIN-x86_64" ;;
        *) say "$h: no build for $arch, skipped"; continue ;;
      esac
      tmp="$(mktemp)"
      gh release download "$TAG" --repo "$REPO" --pattern "$asset" --output "$tmp" --clobber
      # Same ETXTBSY dance as fetch: write beside it, then rename over.
      ssh -o BatchMode=yes "$h" 'mkdir -p ~/.local/bin' </dev/null
      scp -q "$tmp" "$h:.local/bin/.$BIN.new"
      ssh -o BatchMode=yes "$h" "chmod +x ~/.local/bin/.$BIN.new && mv -f ~/.local/bin/.$BIN.new ~/.local/bin/$BIN" </dev/null
      # Replace the PROCESS, not just the file on disk.
      #
      # Deploy used to overwrite the binary and walk away, which upgrades
      # nothing: the old process keeps running from the unlinked inode until
      # something restarts it, and nothing does. oci-mail carried an instance
      # from a build two days old, re-parented to init and outside the unit, so
      # `systemctl --user restart` started a SECOND daemon beside it rather
      # than replacing it. Both then sampled all 154 processes every two
      # seconds and wrote the same snapshot path, racing each other — 8GB read
      # off a throttled volume, and a file whose contents depended on which
      # daemon flushed last.
      #
      # The flock singleton guard cannot catch this on its own. It only
      # excludes daemons that take the lock, and an instance older than the
      # guard never did. Killing what is there before starting what we shipped
      # is the part that does not depend on what the old binary knew.
      # Piped to `bash -s` rather than passed as a command string: ssh runs a
      # command string through the LOGIN shell, and not every box in this fleet
      # logs in to bash — one runs fish, which rejects `n=$(...)` outright and
      # took the whole deploy down after the first host.
      ssh -o BatchMode=yes "$h" bash -s <<EOF
        systemctl --user stop my-watchdog 2>/dev/null || true
        # Kill by pid found with ps, not `pkill -x`. Not every box in this
        # fleet ships full procps — oci-apps rejects `ps -o uid` and ignores
        # pkill's -x — so the pattern matched nothing, `|| true` swallowed it,
        # and the old daemon kept running from its now-unlinked inode beside
        # the new one. Two samplers, one snapshot path, racing.
        pids() { ps -eo pid,comm= 2>/dev/null | awk -v b="$BIN" '\''\$2==b{print \$1}'\''; }
        for q in \$(pids); do kill -TERM "\$q" 2>/dev/null || true; done
        sleep 2
        for q in \$(pids); do kill -KILL "\$q" 2>/dev/null || true; done
        systemctl --user start my-watchdog 2>/dev/null || true
        # Counted with ps, not `pgrep -c`: that flag is not everywhere, and on
        # the box that lacks it pgrep prints its usage and exits 1, which this
        # check read as "zero instances" and reported a healthy daemon as down.
        n=\$(ps -eo comm= 2>/dev/null | grep -cx $BIN || true)
        [ "\$n" = 1 ] || echo "  WARNING: \$n instances of $BIN running"
        # The check that would have caught this from the start. A process whose
        # /proc/<pid>/exe reads "(deleted)" is running a binary that no longer
        # exists on disk — which IS the failure deploy is for: the file was
        # replaced and the process was not. Counting instances alone cannot see
        # it, because one stale daemon is still exactly one daemon.
        d=0
        for q in \$(pids); do
          case "\$(readlink /proc/\$q/exe 2>/dev/null)" in *"(deleted)") d=\$((d+1));; esac
        done
        [ "\$d" = 0 ] || echo "  WARNING: \$d instance(s) of $BIN still running the OLD binary (deleted inode)"
EOF
      # Same policy document to every peer — that is what makes it one source
      # of truth rather than one file per machine that happens to agree today.
      ssh -o BatchMode=yes "$h" 'mkdir -p ~/.config/my-watchdog' </dev/null
      scp -q "$(dirname "$0")/configs/watchdog-policy.json" "$h:.config/my-watchdog/watchdog-policy.json"
      rm -f "$tmp"
      grant_caps "$h" || say "$h: capability grant failed, continuing"
      say "$h ($arch): installed"
    done
    ;;

  check)
    say "Nothing to check locally — this product builds on GHA only."
    ;;
  *)
    echo "usage: build.sh [fetch|install|deploy [host...]|check]" >&2
    exit 2
    ;;
esac
