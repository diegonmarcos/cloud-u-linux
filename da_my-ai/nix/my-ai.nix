# Fetch my-ai and my-ai-dash prebuilt binaries from the GH release,
# apply autoPatchelfHook so they run, and install them.
# Hashes live in ./hashes.json (bumped by ship-my-ai-app.yml GHA).
{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, gcc-unwrapped, libgcc }:
let
  hashes  = builtins.fromJSON (builtins.readFile ./hashes.json);
  archMap = { "x86_64-linux" = "x86_64"; "aarch64-linux" = "aarch64"; };
  arch    = archMap.${stdenv.hostPlatform.system}
              or (throw "my-ai: unsupported platform ${stdenv.hostPlatform.system}");
  baseUrl = "https://github.com/diegonmarcos/unix/releases/download/my-ai-latest";
  sys     = hashes.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname   = "my-ai";
  version = hashes.version or "latest";

  src = fetchurl {
    url  = "${baseUrl}/my-ai-${arch}";
    hash = sys.my-ai;
  };

  dashSrc = fetchurl {
    url  = "${baseUrl}/my-ai-dash-${arch}";
    hash = sys.my-ai-dash;
  };

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ gcc-unwrapped.lib libgcc ];

  dontUnpack = true;

  installPhase = ''
    install -Dm755 $src     $out/bin/my-ai
    install -Dm755 $dashSrc $out/libexec/my-ai/my-ai-dash

    # MY_AI_DASH_BIN lets core::dash_bin() find the internal binary from the nix store.
    wrapProgram $out/bin/my-ai \
      --set MY_AI_DASH_BIN "$out/libexec/my-ai/my-ai-dash"
  '';

  meta = with lib; {
    description  = "my-ai — Claude Code via the Headroom compression proxy";
    homepage     = "https://github.com/diegonmarcos/unix/tree/main/da_my-ai";
    platforms    = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram  = "my-ai";
  };
}
