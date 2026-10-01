{ lib, pkgs, catalog }:

# The gate's runtime payload: one python file plus its routing table rendered
# to JSON at build time. The table is DATA — the stub reads it at runtime and
# never names a model, a port, or a systemd unit itself, so the fleet can
# change without touching gate.py.

let
  table = import ../../../../catalog/lib.nix lib catalog;

  tableJson = builtins.toJSON {
    gate = {
      port = table.gate.port;
      # Only the id matters at runtime; the rest is looked up by id.
      default = table.defaultRow;
      # Where the gate touches a unit's keep-alive stamp; the service's tmpfiles
      # line creates this directory, the stub only writes inside it.
      activityDir = table.gate.activityDir;
      cardFreeMib = table.gate.cardFreeMib;
      readyTimeoutSeconds = table.gate.readyTimeoutSeconds;
      liveGraceSeconds = table.gate.liveGraceSeconds;
    };
    rows = table.rows;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "llm-gate";
  version = "1";

  src = ./.;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out

    cp $src/gate.py $out/gate.py

    # writeText rather than a heredoc: the table is JSON and model names are
    # free text, so quoting it through a shell string is a trap.
    cp ${pkgs.writeText "table.json" tableJson} $out/table.json
  '';
}
