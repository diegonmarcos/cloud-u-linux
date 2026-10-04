{ lib, stdenv, fetchurl, autoPatchelfHook, gcc-unwrapped, libgcc }:

let
  version = "1.44.0";
  assets = {
    x86_64-linux = {
      url = "https://github.com/block/goose/releases/download/v${version}/goose-x86_64-unknown-linux-gnu.tar.bz2";
      hash = "sha256:0wydmsy5i32fyzwix3znsqsiqr9pfdkhivdiyyff8j1p5sskm247";
    };
    aarch64-linux = {
      url = "https://github.com/block/goose/releases/download/v${version}/goose-aarch64-unknown-linux-gnu.tar.bz2";
      hash = "sha256:1af2pni8dhfn79clb3znsqxqjdri7214hy6rs1j1n9dlwi24s3db";
    };
  };
  asset = assets.${stdenv.hostPlatform.system} or (throw "goose: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "goose";
  inherit version;

  src = fetchurl {
    inherit (asset) url hash;
  };

  sourceRoot = ".";
  unpackPhase = "tar xf $src";

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = [ gcc-unwrapped.lib libgcc ];

  installPhase = ''
    mkdir -p $out/bin
    cp goose $out/bin/
    chmod +x $out/bin/goose
  '';

  meta = with lib; {
    description = "Goose — AI-powered developer agent by Block (MCP-native)";
    homepage = "https://github.com/block/goose";
    license = licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "goose";
  };
}
