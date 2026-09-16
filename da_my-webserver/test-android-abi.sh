#!/usr/bin/env bash
# test-android-abi.sh — can this binary actually START on Android?
#
# THE BUG THIS WAS WRITTEN FOR (#288).
#
# The plan for the cloud-webserver APK was to take the aarch64 SEA binary this
# project already publishes, drop it into jniLibs/arm64-v8a/libmywebserver.so,
# and exec it from nativeLibraryDir. Every part of that reasoning is correct
# except the binary. ship-my-webserver-app.yml builds on the official
# nodejs.org Linux tarball, and that tarball is GLIBC:
#
#   PT_INTERP  /lib/ld-linux-aarch64.so.1
#   DT_NEEDED  libc.so.6 libstdc++.so.6 libm.so.6 libgcc_s.so.1
#              libpthread.so.0 libdl.so.2 ld-linux-aarch64.so.1
#
# Android is bionic. Its loader is /system/bin/linker64, its libc is libc.so,
# and /lib is on the read-only system partition, so no APK can put an
# interpreter there either. The file is a perfectly valid aarch64 ELF that
# cannot start on any Android device, rooted or not.
#
# What makes this worth a permanent guard rather than a one-line fix is the
# error. execve() of a binary whose PT_INTERP is missing fails with ENOENT, and
# the ENOENT NAMES THE BINARY, not the interpreter. On Android that reads
# exactly like "the .so was never extracted from the APK", which sends the
# reader back to extractNativeLibs and useLegacyPackaging — the two settings
# that were right all along. Nothing in a green build, a correct manifest or a
# successful install says otherwise.
#
# It also explains why nobody noticed: the same binary runs fine in
# Nix-on-Droid, because proot supplies a glibc root filesystem. The terminal
# was never merely the launcher. It was the runtime.
#
# The rule itself is DATA — build.json::android_abi — so the allowed loader and
# the shippable sonames can move without editing this file.
#
# ── WHY THIS READS THE FIXTURES OVER HTTP RANGE ────────────────────────────
# The first version of this guard fetched the first 64 KiB of each fixture and
# parsed that, on the usual assumption that program headers sit at the front of
# a file. They do not here: postject's injection rewrites the layout, and the
# real SEA binary carries e_phoff at 0x62a0bcd — 103 MB in. So the guard threw
# "truncated", counted the fixture as rejected, and printed PASS. It was right
# by accident, for a reason that had nothing to do with glibc, and it would
# have gone on printing PASS for a genuinely Android-native binary served from
# a flaky mirror. A guard that cannot say WHY is not a guard.
#
# Every read is therefore a seek to an offset the ELF itself names, served
# either by the local file or by a Range request. Total bytes pulled per
# fixture: a few KiB, out of 122 MB.
#
# Usage:
#   ./test-android-abi.sh <binary> [...]   assert each file is Android-loadable
#   ./test-android-abi.sh                  self-test against the two fixtures
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }

python3 - "$SELF_DIR" "$@" <<'PY'
import json, os, struct, subprocess, sys

SELF_DIR = sys.argv[1]
ARGS     = sys.argv[2:]
RULE     = json.load(open(os.path.join(SELF_DIR, "build.json")))["android_abi"]
LOADERS  = {RULE["system_loader_64"], RULE["system_loader_32"]}
ALLOWED  = set(RULE["allowed_needed"])


class LocalReader:
    def __init__(self, path):
        self.f = open(path, "rb")
    def pread(self, off, n):
        self.f.seek(off)
        return self.f.read(n)
    def close(self):
        self.f.close()


class RangeReader:
    """Random access to a release asset over HTTP. GitHub redirects release
    downloads to a CDN and the Range header survives the redirect, so this
    pulls kilobytes rather than the 122 MB the real artifact weighs."""
    def __init__(self, url):
        self.url = url
    def pread(self, off, n):
        r = subprocess.run(
            ["curl", "-fsSL", "-r", f"{off}-{off + n - 1}", self.url],
            capture_output=True)
        if r.returncode != 0:
            raise IOError(f"range {off}-{off + n - 1} failed: "
                          f"{r.stderr.decode(errors='replace').strip()}")
        return r.stdout
    def close(self):
        pass


def read_elf(rd):
    """→ (interp, needed, static).

    Fails LOUDLY on a short read rather than treating missing bytes as an
    absent header: 'I could not tell' and 'there is nothing there' are the two
    answers this guard must never confuse, because confusing them is how the
    first version of it passed for the wrong reason."""
    d = rd.pread(0, 64)
    if len(d) < 64:
        raise ValueError("short read on the ELF header")
    if d[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if d[4] != 2:
        raise ValueError("not 64-bit ELF")

    e_phoff = struct.unpack_from("<Q", d, 32)[0]
    e_shoff = struct.unpack_from("<Q", d, 40)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", d, 54)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 58)

    ph = rd.pread(e_phoff, e_phentsize * e_phnum)
    if len(ph) < e_phentsize * e_phnum:
        raise ValueError(f"short read on the program headers at {hex(e_phoff)}")

    interp, dynseg = None, None
    for i in range(e_phnum):
        p_type = struct.unpack_from("<I", ph, i * e_phentsize)[0]
        p_off, _, _, p_filesz = struct.unpack_from("<QQQQ", ph, i * e_phentsize + 8)
        if p_type == 3:                      # PT_INTERP
            raw = rd.pread(p_off, p_filesz)
            if len(raw) < p_filesz:
                raise ValueError("short read on PT_INTERP")
            interp = raw.rstrip(b"\0").decode()
        elif p_type == 2:                    # PT_DYNAMIC
            dynseg = (p_off, p_filesz)

    # No PT_INTERP at all is a STATIC binary: nothing to resolve, so it runs
    # anywhere the kernel and the architecture agree. That is the shape
    # my-watchdog already ships and execs from nativeLibraryDir today.
    if interp is None:
        return None, [], True

    needed = None
    if dynseg and e_shnum:
        sh = rd.pread(e_shoff, e_shentsize * e_shnum)
        if len(sh) == e_shentsize * e_shnum:
            g = lambda i: struct.unpack_from("<IIQQQQIIQQ", sh, i * e_shentsize)
            so = g(e_shstrndx)
            st = rd.pread(so[4], so[5])
            nm = lambda o: st[o:st.index(b"\0", o)].decode()
            dynstr = next((g(i) for i in range(e_shnum)
                           if nm(g(i)[0]) == ".dynstr"), None)
            if dynstr:
                ds = rd.pread(dynstr[4], dynstr[5])
                dd = rd.pread(dynseg[0], dynseg[1])
                needed = []
                for i in range(0, len(dd), 16):
                    tag, val = struct.unpack_from("<qQ", dd, i)
                    if tag == 0:
                        break
                    if tag == 1:
                        needed.append(ds[val:ds.index(b"\0", val)].decode())
    return interp, needed, False


def verdict(rd):
    """→ (ok, [reasons]). Fails CLOSED: anything unreadable is a failure, not a
    pass, because the whole point is that this file's problems are invisible."""
    try:
        interp, needed, static = read_elf(rd)
    except Exception as e:
        return False, [f"could not be judged: {e}"]

    if static:
        return True, ["static — no PT_INTERP, nothing to resolve"]

    why = []
    if interp not in LOADERS:
        why.append(f"PT_INTERP is {interp} — Android's loader is "
                   f"{RULE['system_loader_64']}, and "
                   f"{os.path.dirname(interp) or '/'} is not writable by any "
                   f"APK. execve() returns ENOENT naming the BINARY, not this "
                   f"interpreter.")
    if needed is None:
        why.append("PT_DYNAMIC present but .dynamic could not be read — "
                   "DT_NEEDED unverified, refusing to call it loadable")
    else:
        bad = [n for n in needed if n not in ALLOWED]
        if bad:
            why.append("DT_NEEDED not resolvable on a stock device and not "
                       "shippable in jniLibs (PackageManager extracts lib*.so "
                       "only): " + ", ".join(bad))
    if why:
        return False, why
    return True, [f"PT_INTERP {interp}; DT_NEEDED all resolvable: "
                  + ", ".join(needed)]


def self_test():
    print("=== android ABI guard: self-test against published artifacts ===")
    bad = skipped = 0
    for key, want_ok in (("must_pass", True), ("must_fail", False)):
        fx = RULE["fixtures"][key]
        url = (f"https://github.com/{fx['repo']}/releases/download/"
               f"{fx['tag']}/{fx['asset']}")
        rd = RangeReader(url)
        try:
            ok, why = verdict(rd)
        except Exception as e:
            print(f"  SKIP — {fx['asset']} unreachable ({e})")
            skipped += 1
            continue
        # An unreachable fixture must not read as a verdict. "could not be
        # judged" is what a network failure produces, and for must_fail that
        # would look identical to a correct rejection — the exact accident
        # this guard was rewritten to stop making.
        if not ok and why and why[0].startswith("could not be judged"):
            print(f"  SKIP — {fx['asset']}: {why[0]}")
            skipped += 1
            continue
        hit = (ok == want_ok)
        bad += 0 if hit else 1
        print(f"  {'ok  ' if hit else 'FAIL'} — {fx['asset']} ({fx['tag']}) "
              f"expected {'LOADABLE' if want_ok else 'REJECTED'}, "
              f"got {'LOADABLE' if ok else 'REJECTED'}")
        for w in why:
            print(f"           {w}")
    if bad:
        print("=== android ABI guard: FAIL ===")
        return 1
    if skipped:
        print(f"=== android ABI guard: INCONCLUSIVE ({skipped} fixture(s) "
              f"unreachable) ===")
        return 1
    print("=== android ABI guard: PASS ===")
    print("    Observed REJECTING this project's own glibc aarch64 binary and")
    print("    ACCEPTING my-watchdog's static one, each for the stated reason,")
    print("    so a pass on a future Android artifact means something.")
    return 0


if not ARGS:
    sys.exit(self_test())

rc = 0
for path in ARGS:
    rd = LocalReader(path)
    ok, why = verdict(rd)
    rd.close()
    print(f"  {'ok  ' if ok else 'FAIL'} — {path}")
    for w in why:
        print(f"           {w}")
    if not ok:
        rc = 1
sys.exit(rc)
PY
