# Assumes this file lives at ./monitor/monitor.nix with the Python
# scripts alongside it at ./monitor/scripts/*.py — adjust the readFile
# paths below if you put them somewhere else.
{ pkgs, ... }:

let
  # ===================================================================
  # Desired monitor layout — the only thing you should need to touch
  # when monitors, GPUs, or cables change.
  #
  # Physical identity comes from EDID (manufacturer/model/serial), not
  # from DRM connector names, GPU, or cable — see scripts/core.py.
  # ===================================================================
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

  # Written to the store as real JSON and read with json.load() at
  # runtime — never spliced into Python source as a text literal.
  # (`LAYOUT = ${builtins.toJSON monitor-layout}` looks convenient but
  # only works by accident: JSON's true/false/null aren't Python's
  # True/False/None, so it breaks the day this attrset gains a bool.)
  layoutJsonFile = pkgs.writeText "monitor-layout.json" (builtins.toJSON monitor-layout);

  # The logic shared by both backends — physical-monitor resolution,
  # error(), run_json(), load_layout(). Concatenated as plain text
  # above each backend script below.
  coreLib = builtins.readFile ./scripts/core.py;

  display-discovery = pkgs.writers.writePython3Bin "display-discovery" { }
    (builtins.readFile ./scripts/display-discovery.py);

  kscreen-backend = pkgs.writers.writePython3Bin "set-monitor-layout-kscreen" { } (''
    KSCREEN = "${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor"
    DISCOVERY = "${display-discovery}/bin/display-discovery"
    LAYOUT_PATH = "${layoutJsonFile}"

  '' + coreLib + "\n" + builtins.readFile ./scripts/kscreen-backend.py);

  sddm-kwin-backend = pkgs.writers.writePython3Bin "set-sddm-monitor-layout" { } (''
    DISCOVERY = "${display-discovery}/bin/display-discovery"
    LAYOUT_PATH = "${layoutJsonFile}"

  '' + coreLib + "\n" + builtins.readFile ./scripts/sddm-kwin-backend.py);

  # ===================================================================
  # Desktop-manager backend dispatcher.
  #
  # Today: KDE Plasma -> KScreen. Adding Niri/Hyprland/Sway later means
  # adding another scripts/<backend>.py that also starts from
  # `load_layout` + `resolve_physical` — the desired layout doesn't
  # change, and neither does the shared resolution logic.
  # ===================================================================
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
  # Generate SDDM's persistent KWin output config before SDDM starts.
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
