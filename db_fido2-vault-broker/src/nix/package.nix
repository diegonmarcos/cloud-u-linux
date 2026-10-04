# fido2-vault-broker package — callPackage-able, single source of truth.
#
# Consumed two ways:
#   1. The subflake's own `packages.default` (flake.nix: pkgs.callPackage).
#   2. The surface host flake by PLAIN PATH IMPORT
#      (aa_desk-usr_x86_surface-linux_nixos/src/modules/
#       configuration_fido2-vault-broker.nix: pkgs.callPackage).
#
# WHY the host imports by path instead of a flake input: nix 2.24 cannot
# lock or re-fetch relative-path flake inputs inside a git flake — every
# `nix flake update` / eval of the host flake died with
# "lock file contains unlocked input" / "cannot fetch input ... because it
# uses a relative path" (2026-06-11/12). Plain Nix path imports within the
# same git repo have none of these problems. Proper relative-path flake
# inputs land in nix >= 2.26; revisit then.
{
  lib,
  rustPlatform,
  pkg-config,
  openssl,
  tpm2-tss,
}:

rustPlatform.buildRustPackage {
  pname = "fido2-vault-broker";
  version = "0.1.0";
  src = ../.;
  cargoLock.lockFile = ../Cargo.lock;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    openssl
    tpm2-tss
  ];
  doCheck = true;

  # Ship the udev rule alongside the binary so consumers using
  # `services.udev.packages = [ <this package> ]` pick it up declaratively
  # without touching extraRules.
  postInstall = ''
    install -Dm0644 ${../templates/70-fido2-vault-broker.rules} $out/lib/udev/rules.d/70-fido2-vault-broker.rules
  '';
}
