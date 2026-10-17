#!/usr/bin/env bash
# fish_greeting must print NOTHING to stderr on an Android/proot-like host: no hostname, free, ip,
# ss, lspci, systemctl, last on PATH, and /proc/uptime + /proc/loadavg unreadable (SELinux).
# Also checks the desktop path still renders without errors.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
G="$here/fish-functions/fish_greeting.fish"
FISH="$(command -v fish)" || { echo "SKIP: no fish"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
mkdir -p "$T/bin" "$T/home/cloud-shared-store/git" "$T/denied_uptime" "$T/denied_loadavg"
for c in awk cat date uname df nproc grep sed head sort id whoami env; do
  p="$(command -v "$c")" && ln -s "$p" "$T/bin/$c"
done
for c in hostname free ip ss lspci systemctl last; do
  [ ! -e "$T/bin/$c" ] || { echo "FAIL: stub PATH has $c"; exit 1; }
done
# Unreadable /proc files: a missing path (non-root) and a directory (cat fails even as root).
sed -e "s|/proc/uptime|$T/denied_uptime|g" -e "s|/proc/loadavg|$T/no-such-loadavg|g" "$G" > "$T/g.fish"
run() { # <name> <env...>
  local name="$1"; shift
  env -i PATH="$T/bin" HOME="$T/home" TERM=dumb "$@" "$FISH" --no-config -c "source $T/g.fish; fish_greeting" >"$T/$name.out" 2>"$T/$name.err"
  local rc=$?
  if [ -s "$T/$name.err" ]; then
    echo "FAIL [$name]: rc=$rc, stderr:"; sed 's/^/    /' "$T/$name.err"; fail=1
  else
    echo "ok   [$name]: no stderr"
  fi
}
run android ANDROID_ROOT=/system
grep -q 'cloud-shared-store' "$T/android.out" || { echo "FAIL [android]: tree does not show ~/cloud-shared-store"; fail=1; }
sed -n '/── Tree/,/── Env Vars/p' "$T/android.out" | grep -q 'Mounts/Git' && { echo "FAIL [android]: tree shows the desktop ~/Mounts/Git"; fail=1; }
grep -q 'SSH 8023' "$T/android.out" || { echo "FAIL [android]: no SSH 8023 status"; fail=1; }
run bare
grep -q 'Mounts/Git' "$T/bare.out" || { echo "FAIL [bare]: desktop tree missing"; fail=1; }
[ "$fail" = 0 ] && echo "OK: fish_greeting is stderr-clean" || exit 1
