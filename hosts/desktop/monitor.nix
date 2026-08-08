{ pkgs, ... }:

let

  # =====================================================================
  # Desired monitor layout
  #
  # This is the stable, human-facing part of the configuration.
  #
  # Nothing here knows about:
  #   - DRM connector names
  #   - GPUs
  #   - KScreen output IDs
  #   - KScreen mode IDs
  #   - desktop-manager configuration syntax
  #
  # The physical monitor identity comes from EDID.
  # =====================================================================

  monitor-layout = {
    samsung-g93sc = {
      manufacturer = "SAM";
      model = "Odyssey G93SC";
      serial = "HCSX801408";

      mode = {
        width = 5120;
        height = 1440;
        refresh = 240;
      };

      position = {
        x = 0;
        y = 0;
      };
    };

    dell-aw3423dw = {
      manufacturer = "DEL";
      model = "Dell AW3423DW";
      serial = "#GrMYMxgwAAkD";

      mode = {
        width = 3440;
        height = 1440;
        refresh = 175;
      };

      position = {
        x = 5120;
        y = 0;
      };
    };
  };


  # =====================================================================
  # Hardware discovery
  #
  # This is intentionally based on the existing working implementation.
  #
  # The EDID parser is not replaced with edid-decode, awk, card0/card1
  # assumptions, or any other discovery mechanism.
  #
  # Normal output:
  #
  #   1-DP-1: DEL Dell AW3423DW (serial #GrMYMxgwAAkD)
  #   1-DP-2: SAM Odyssey G93SC (serial HCSX801408)
  #
  # --json is the structured interface consumed by other programs.
  # =====================================================================

  display-discovery =
    pkgs.writeShellScriptBin "display-discovery" ''
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import glob
      import json
      import os
      import sys


      def edid_string(data, offset, length):
          """Decode an EDID ASCII descriptor, stripping padding/newlines."""
          raw = data[offset:offset + length]
          raw = raw.split(b"\n", 1)[0]
          raw = raw.split(b"\x00", 1)[0]
          return raw.decode("ascii", errors="replace").strip(" \r\n")


      def manufacturer(data):
          """Decode the 3-character EDID manufacturer ID."""
          value = (data[8] << 8) | data[9]

          chars = [
              (value >> 10) & 0x1f,
              (value >> 5) & 0x1f,
              value & 0x1f,
          ]

          if any(c < 1 or c > 26 for c in chars):
              return "UNKNOWN"

          return "".join(chr(ord("A") + c - 1) for c in chars)


      def parse_edid(data):
          if len(data) < 128:
              raise ValueError("EDID is shorter than 128 bytes")

          if data[0:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
              raise ValueError("invalid EDID header")

          # Base EDID checksum.
          if sum(data[0:128]) & 0xff:
              raise ValueError("invalid EDID checksum")

          mfr = manufacturer(data)

          # EDID descriptors live at 0x36, four 18-byte descriptors.
          product_name = None
          serial = None

          for i in range(4):
              off = 0x36 + i * 18
              descriptor = data[off:off + 18]

              if descriptor[0:2] != b"\x00\x00":
                  continue

              tag = descriptor[3]

              if tag == 0xff:
                  serial = edid_string(data, off + 5, 13)

              elif tag == 0xfc:
                  product_name = edid_string(data, off + 5, 13)

          # EDID product code. Useful as a fallback/debug identifier.
          product_code = data[10] | (data[11] << 8)

          # EDID physical serial number, if present in the base block.
          edid_serial = (
              data[12]
              | (data[13] << 8)
              | (data[14] << 16)
              | (data[15] << 24)
          )

          return {
              "manufacturer": mfr,
              "model": product_name or "UNKNOWN",
              "serial": serial or "",
              "product_code": product_code,
              "edid_serial": edid_serial,
          }


      def connectors():
          # The class directory gives us the stable DRM connector namespace.
          # Do not assume card0/card1 or a particular PCI topology.
          for path in sorted(glob.glob("/sys/class/drm/card*-DP-*")):
              connector = os.path.basename(path)

              # Ignore things that aren't actual DRM connectors.
              status_path = os.path.join(path, "status")
              edid_path = os.path.join(path, "edid")

              try:
                  with open(status_path) as f:
                      status = f.read().strip()
              except OSError:
                  continue

              if status != "connected":
                  continue

              try:
                  with open(edid_path, "rb") as f:
                      data = f.read()
              except OSError:
                  continue

              if not data:
                  continue

              try:
                  identity = parse_edid(data)
              except ValueError as e:
                  print(
                      f"warning: could not parse EDID for {connector}: {e}",
                      file=sys.stderr,
                  )
                  continue

              yield {
                  "connector": connector.removeprefix("card"),
                  "drm_path": os.path.realpath(path),
                  **identity,
              }


      displays = list(connectors())

      if "--json" in sys.argv[1:]:
          json.dump(displays, sys.stdout)
          print()
      else:
          for display in displays:
              print(
                  "{connector}: {manufacturer} {model}"
                  .format(**display)
                  + (
                      f" (serial {display['serial']})"
                      if display["serial"]
                      else ""
                  )
              )
      PY
    '';


  # =====================================================================
  # KScreen backend
  #
  # Input:
  #
  #   Desired monitor layout
  #           +
  #   Physical monitor discovery
  #
  # Output:
  #
  #   kscreen-doctor arguments
  #
  # KScreen's JSON output does NOT expose EDID manufacturer/model/serial
  # on this system. Therefore the hardware discovery connector is used
  # only as the runtime bridge:
  #
  #   EDID physical identity
  #       |
  #       +--> current DRM connector
  #                  |
  #                  +--> KScreen output name
  #
  # The connector is NEVER the monitor's identity.
  #
  # Example:
  #
  #   SAM Odyssey G93SC
  #       EDID -> 1-DP-2
  #       KScreen -> DP-2
  #
  #   DEL Dell AW3423DW
  #       EDID -> 1-DP-1
  #       KScreen -> DP-1
  #
  # No KScreen UUID or mode ID is stored here.
  # =====================================================================

  kscreen-backend =
    pkgs.writeShellScriptBin "set-monitor-layout-kscreen" ''
      exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
      import json
      import math
      import subprocess
      import sys
      import time


      KSCREEN = "${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor"
      DISCOVERY = "${display-discovery}/bin/display-discovery"


      # This is generated by Nix from the declarative layout above.
      LAYOUT = ${builtins.toJSON monitor-layout}


      def error(message):
          print(f"error: {message}", file=sys.stderr)
          sys.exit(1)


      def run_json(command):
          try:
              result = subprocess.run(
                  command,
                  check=True,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
              )
          except FileNotFoundError:
              error(f"command not found: {command[0]}")
          except subprocess.CalledProcessError as exc:
              detail = exc.stderr.strip()

              if detail:
                  error(f"{command[0]} failed: {detail}")

              error(
                  f"{command[0]} failed with exit status "
                  f"{exc.returncode}"
              )

          try:
              return json.loads(result.stdout)
          except json.JSONDecodeError as exc:
              error(
                  f"{command[0]} returned invalid JSON: {exc}"
              )


      # =================================================================
      # 1. Discover physical monitors.
      # =================================================================

      displays = run_json([
          DISCOVERY,
          "--json",
      ])


      def find_physical_monitor(name, desired):
          matches = [
              display
              for display in displays
              if display.get("manufacturer") == desired["manufacturer"]
              and display.get("model") == desired["model"]
          ]

          if not matches:
              error(
                  f'{desired["manufacturer"]} '
                  f'{desired["model"]} was not discovered'
              )

          serial = desired.get("serial", "")

          if serial:
              matches = [
                  display
                  for display in matches
                  if display.get("serial") == serial
              ]

              if not matches:
                  error(
                      f'{desired["manufacturer"]} '
                      f'{desired["model"]} was discovered, '
                      f'but serial {serial!r} was not found'
                  )

          if len(matches) != 1:
              found = ", ".join(
                  f'{m.get("connector")} '
                  f'{m.get("manufacturer")} '
                  f'{m.get("model")} '
                  f'{m.get("serial")!r}'
                  for m in matches
              )

              error(
                  f'physical monitor {name!r} is ambiguous: {found}'
              )

          return matches[0]


      physical = {}

      for name, desired in LAYOUT.items():
          physical[name] = find_physical_monitor(name, desired)


      # =================================================================
      # 2. Discover the live KScreen session.
      #
      # Autostart can happen before the KScreen service is completely
      # ready. Retry for a short period rather than failing immediately.
      # =================================================================

      kscreen = None

      for attempt in range(15):
          try:
              result = subprocess.run(
                  [
                      KSCREEN,
                      "--json",
                  ],
                  check=True,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
              )

              kscreen = json.loads(result.stdout)
              break

          except (
              FileNotFoundError,
              subprocess.CalledProcessError,
              json.JSONDecodeError,
          ):
              if attempt == 14:
                  error("KScreen session was not available")

              time.sleep(1)


      outputs = kscreen.get("outputs")

      if not isinstance(outputs, list):
          error("KScreen JSON does not contain an output list")


      # =================================================================
      # 3. Convert the DRM connector reported by display-discovery into
      #    the connector name exposed by KScreen.
      #
      # display-discovery:
      #
      #     1-DP-2
      #
      # KScreen:
      #
      #     DP-2
      #
      # We intentionally do NOT assume card0/card1.
      # =================================================================

      def kscreen_connector(display):
          connector = display.get("connector")

          if not connector:
              error(
                  "hardware discovery returned a monitor "
                  "without a connector"
              )

          if connector.startswith("DP-"):
              return connector

          parts = connector.split("-", 1)

          if len(parts) != 2 or not parts[1].startswith("DP-"):
              error(
                  f"unsupported DRM connector format: {connector!r}"
              )

          return parts[1]


      # =================================================================
      # 4. Resolve a physical monitor to a live KScreen output.
      # =================================================================

      def resolve_output(name, desired, display):
          connector = kscreen_connector(display)

          matches = [
              output
              for output in outputs
              if output.get("name") == connector
          ]

          if len(matches) == 1:
              return matches[0]

          if not matches:
              error(
                  f'could not resolve KScreen output for '
                  f'{desired["model"]} '
                  f'(runtime connector {connector})'
              )

          # Do not silently pick one if multiple GPUs expose the same
          # connector name. That could apply the layout to the wrong
          # physical monitor.
          error(
              f'KScreen connector {connector} is ambiguous for '
              f'{desired["model"]}; multiple outputs matched'
          )


      # =================================================================
      # 5. Resolve the desired mode.
      # =================================================================

      def resolve_mode(name, desired, output):
          desired_mode = desired["mode"]

          width = desired_mode["width"]
          height = desired_mode["height"]
          refresh = desired_mode["refresh"]

          matches = []

          for mode in output.get("modes", []):
              size = mode.get("size", {})

              if size.get("width") != width:
                  continue

              if size.get("height") != height:
                  continue

              actual_refresh = mode.get("refreshRate")

              if actual_refresh is None:
                  continue

              if not math.isclose(
                  float(actual_refresh),
                  float(refresh),
                  abs_tol=0.5,
              ):
                  continue

              matches.append(mode)


          if not matches:
              error(
                  f'could not find '
                  f'{width}x{height}@{refresh} mode for '
                  f'{desired["model"]}'
              )

          if len(matches) > 1:
              mode_ids = ", ".join(
                  str(mode.get("id"))
                  for mode in matches
              )

              error(
                  f'multiple '
                  f'{width}x{height}@{refresh} modes found for '
                  f'{desired["model"]}: {mode_ids}'
              )

          mode_id = matches[0].get("id")

          if mode_id is None:
              error(
                  f'matching mode for {desired["model"]} '
                  f'has no runtime mode ID'
              )

          return mode_id


      # =================================================================
      # 6. Resolve every monitor before changing anything.
      #
      # This is important: if one monitor is missing or invalid, we don't
      # partially apply the layout.
      # =================================================================

      resolved = []

      for name, desired in LAYOUT.items():
          display = physical[name]

          output = resolve_output(
              name,
              desired,
              display,
          )

          output_id = output.get("id")

          if output_id is None:
              error(
                  f'KScreen output for {desired["model"]} '
                  f'has no runtime output ID'
              )

          mode_id = resolve_mode(
              name,
              desired,
              output,
          )

          position = desired["position"]

          resolved.append({
              "name": name,
              "desired": desired,
              "physical": display,
              "output": output,
              "output_id": output_id,
              "mode_id": mode_id,
              "x": position["x"],
              "y": position["y"],
          })


      # =================================================================
      # 7. Construct ONE kscreen-doctor invocation.
      # =================================================================

      command = [KSCREEN]

      for monitor in resolved:
          command.extend([
              (
                  f'output.{monitor["output_id"]}.'
                  f'mode.{monitor["mode_id"]}'
              ),
              (
                  f'output.{monitor["output_id"]}.'
                  f'position.{monitor["x"]},{monitor["y"]}'
              ),
          ])


      # =================================================================
      # 8. Diagnostics.
      # =================================================================

      print(
          "Applying monitor layout:",
          file=sys.stderr,
      )

      for monitor in resolved:
          desired = monitor["desired"]
          physical = monitor["physical"]

          print(
              f'  {monitor["name"]}: '
              f'{desired["manufacturer"]} '
              f'{desired["model"]} '
              f'{desired["serial"]!r}',
              file=sys.stderr,
          )

          print(
              f'    DRM connector: {physical["connector"]}',
              file=sys.stderr,
          )

          print(
              f'    KScreen output: {monitor["output_id"]} '
              f'({monitor["output"].get("name")})',
              file=sys.stderr,
          )

          print(
              f'    KScreen mode: {monitor["mode_id"]}',
              file=sys.stderr,
          )

          print(
              f'    position: '
              f'{monitor["x"]},{monitor["y"]}',
              file=sys.stderr,
          )


      # =================================================================
      # 9. Apply everything atomically from the consumer's perspective:
      #    one kscreen-doctor process with all changes.
      # =================================================================

      try:
          subprocess.run(
              command,
              check=True,
          )
      except subprocess.CalledProcessError as exc:
          error(
              f"kscreen-doctor failed with exit status "
              f"{exc.returncode}"
          )
      PY
    '';


  # =====================================================================
  # Desktop-manager backend dispatcher
  #
  # Today:
  #
  #   KDE Plasma -> KScreen
  #
  # Future:
  #
  #   Niri
  #   Hyprland
  #   Sway
  #   etc.
  #
  # The desired monitor layout does not change when a backend is added.
  # =====================================================================

  set-monitor-layout =
    pkgs.writeShellScriptBin "set-monitor-layout" ''
      set -euo pipefail

      backend="''${MONITOR_LAYOUT_BACKEND:-kscreen}"

      case "$backend" in
        kscreen|plasma|kde)
          exec ${kscreen-backend}/bin/set-monitor-layout-kscreen "$@"
          ;;

        *)
          echo \
            "error: unsupported monitor layout backend: $backend" \
            >&2
          echo \
            "available backends: kscreen" \
            >&2
          exit 1
          ;;
      esac
    '';

in
{
  # =====================================================================
  # Public commands
  # =====================================================================

  environment.systemPackages = [
    display-discovery
    set-monitor-layout
  ];


  # =====================================================================
  # KDE autostart
  # =====================================================================

  environment.etc."xdg/autostart/set-monitor-layout.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Set monitor layout
    Exec=set-monitor-layout
    X-KDE-autostart-phase=1
  '';
}