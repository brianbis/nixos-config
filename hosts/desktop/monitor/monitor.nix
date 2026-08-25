{ pkgs, ... }:

let
  # Desired monitor layout — the only thing to touch when monitors, GPUs,
  # or cables change. Identity is matched by EDID (manufacturer/model/
  # serial), not DRM connector names, GPU, or cable (see scripts/core.py).
  monitor-layout = {
    samsung-g93sc = {
      manufacturer = "SAM";
      model = "Odyssey G93SC";
      serial = "HCSX801408";
      mode = { width = 5120; height = 1440; refresh = 240; };
      position = { x = 0; y = 0; };
    };

    dell-aw3423dw = {
      manufacturer = "DEL";
      model = "Dell AW3423DW";
      serial = "#GrMYMxgwAAkD";
      mode = { width = 3440; height = 1440; refresh = 175; };
      position = { x = 5120; y = 0; };
    };
  };

  # Real JSON read with json.load() at runtime, never spliced into Python
  # source: JSON's true/false/null aren't Python's True/False/None, so
  # inlining breaks the day this attrset gains a bool.
  layoutJsonFile = pkgs.writeText "monitor-layout.json" (builtins.toJSON monitor-layout);

  # All scripts ship in one store directory: core.py is a shared module
  # the backends import, and PYTHONPATH points here.
  monitor-scripts = pkgs.stdenv.mkDerivation {
    pname = "monitor-scripts";
    version = "0.1.0";
    src = ./scripts;
    nativeBuildInputs = [ pkgs.python3Packages.flake8 ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out
      cp *.py $out/
    '';
    checkPhase = ''
      flake8 $out/*.py
    '';
  };

  display-discovery = pkgs.writeShellScriptBin "display-discovery" ''
    exec ${pkgs.python3}/bin/python3 ${monitor-scripts}/display-discovery.py "$@"
  '';

  # Desktop-manager backend dispatcher. Each backend script starts from
  # load_layout + resolve_physical; the desired layout and shared resolution
  # logic stay the same across backends.
  kscreen-backend = pkgs.writeShellScriptBin "set-monitor-layout-kscreen" ''
    export PYTHONPATH=${monitor-scripts}
    export KSCREEN=${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor
    export DISCOVERY=${display-discovery}/bin/display-discovery
    export LAYOUT_PATH=${layoutJsonFile}
    exec ${pkgs.python3}/bin/python3 ${monitor-scripts}/kscreen-backend.py "$@"
  '';

  sddm-kwin-backend = pkgs.writeShellScriptBin "set-sddm-monitor-layout" ''
    export PYTHONPATH=${monitor-scripts}
    export DISCOVERY=${display-discovery}/bin/display-discovery
    export LAYOUT_PATH=${layoutJsonFile}
    exec ${pkgs.python3}/bin/python3 ${monitor-scripts}/sddm-kwin-backend.py "$@"
  '';

  set-monitor-layout = pkgs.writeShellScriptBin "set-monitor-layout" ''
    set -euo pipefail
    backend="''${MONITOR_LAYOUT_BACKEND:-kscreen}"
    case "$backend" in
      kscreen|plasma|kde)
        exec ${kscreen-backend}/bin/set-monitor-layout-kscreen "$@"
        ;;
      *)
        echo "error: unsupported monitor layout backend: $backend" >&2
        echo "available backends: kscreen" >&2
        exit 1
        ;;
    esac
  '';

in
{
  systemd.services.set-sddm-monitor-layout = {
    description = "Set SDDM monitor layout";
    wantedBy = [ "display-manager.service" ];
    before = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${sddm-kwin-backend}/bin/set-sddm-monitor-layout";
    };
  };

  environment.systemPackages = [
    display-discovery
    set-monitor-layout
    sddm-kwin-backend
  ];

  environment.etc."xdg/autostart/set-monitor-layout.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Set monitor layout
    Exec=set-monitor-layout
    X-KDE-autostart-phase=1
  '';
}
