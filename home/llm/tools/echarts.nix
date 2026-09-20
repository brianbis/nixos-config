# ECharts: a rich, interactive chart library (Apache-2.0) — the FOSS
# "Tableau-feel" chart engine for the self-contained / declarative data path.
#
# Not a ready nixpkgs attr in this pin (nodePackages was removed and echarts is
# npm-only), so this is built from the flakeless `echarts` source input (see
# flake.nix): the version is read from the source's package.json, so
# `nix flake update echarts` re-pins the source and the version follows. The
# pre-built npm dist is fetched for that version (fixed-output; after a re-pin
# the first build reports the new sha512 — update it, see the AGENTS.md
# fetchFromGitHub-hash workflow), unpacked, and a small `echarts` CLI is bundled
# that turns an ECharts option (JSON) into a self-contained standalone HTML
# file. The UMD build is inlined, so the output needs no network and no
# dependencies — it just opens.
#
#   echo '{"xAxis":{...},"series":[...]}' | echarts deck.html
#   echarts option.json deck.html
#
# This is the "simple HTML, refreshable from datasets" counterpart to vega-cli
# (Vega-Lite): swap the option/dataset, re-render, no server.
{ lib, stdenvNoCC, nodejs, fetchurl, gnutar, writeShellScriptBin, src }:

let
  # Read the version from the source's package.json so a re-pin updates it
  # together (no hardcoded version to drift out of sync — mirrors knife.nix).
  pkg = builtins.fromJSON (builtins.readFile (src + "/package.json"));
  version = pkg.version;

  # Pre-built npm dist tarball for that version (fixed-output, pinned sha512).
  echartsTarball = fetchurl {
    url = "https://registry.npmjs.org/echarts/-/echarts-${version}.tgz";
    sha256 = "aBr/iMwQOMP6lBo6U9Gxd6UiULBTNe/GB9YQWuE75IE=";
  };

  # Unpack the tarball (npm layout: package/dist/..., package/package.json).
  echartsDist = stdenvNoCC.mkDerivation {
    pname = "echarts-dist";
    inherit version;
    src = echartsTarball;
    nativeBuildInputs = [ gnutar ];
    dontBuild = true;
    dontConfigure = true;
    installPhase = ''
      mkdir -p $out
      cp -r ./* $out/
    '';
  };
  echartsJs = "${echartsDist}/dist/echarts.min.js";
in
writeShellScriptBin "echarts" ''
  set -euo pipefail
  # usage: echarts [option.json] [out.html]   (option JSON also via stdin)
  OPT="$${1:-}"; OUT="$${2:-index.html}"
  if [ -n "$OPT" ] && [ -f "$OPT" ]; then OPTION="$(cat "$OPT")"; else OPTION="$(cat)"; fi
  {
    printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"><title>ECharts</title>'
    printf '%s\n' '<style>html,body{margin:0;height:100%}#c{width:100%;height:100%}</style></head><body><div id="c"></div>'
    printf '%s' '<script>'
    cat ${echartsJs}
    printf '%s' '</script><script>var c=echarts.init(document.getElementById("c"));c.setOption('
    printf '%s' "$OPTION"
    printf '%s\n' ');window.addEventListener("resize",function(){c.resize()});</script></body></html>'
  } > "$OUT"
  echo "wrote $OUT"
'' // {
  meta = {
    description = "ECharts interactive charts: render an ECharts option (JSON) to a self-contained standalone HTML file";
    homepage = "https://echarts.apache.org/";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
    mainProgram = "echarts";
    maintainers = [ ];
  };
}
