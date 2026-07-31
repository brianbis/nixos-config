{ pkgs, ... }:

let
  headphoneDevices = [
    "A4:C6:F0:CB:F3:52"
    "74:77:86:25:E5:18"
  ];

  bluetoothConnectScript = pkgs.writeShellScriptBin "bt-connect-headphones" ''
    #!${pkgs.bash}/bin/bash
    set -u
    MACS=(${builtins.concatStringsSep " " headphoneDevices})
    ATTEMPTS=''${1:-6}
    DELAY=''${2:-3}

    for mac in "''${MACS[@]}"; do
      if ${pkgs.bluez}/bin/bluetoothctl info "$mac" | grep -q "Connected: yes"; then
        continue
      fi

      for i in $(seq 1 "$ATTEMPTS"); do
        if ${pkgs.bluez}/bin/bluetoothctl connect "$mac" | grep -q "Connection successful"; then
          break
        fi
        sleep "$DELAY"
      done
    done
  '';
in
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;

    settings = {
      General = {
        # Force BlueZ to use Classic Bluetooth (BR/EDR) only for audio devices.
        # This prevents BlueZ from getting confused by AirPods BLE "Find My" addresses.
        ControllerMode = "bredr";

        Experimental = true;
        FastConnectable = true;
        JustWorksRepairing = "always";
      };

      Policy = {
        AutoEnable = true;
        ReconnectAttempts = 7;
        ReconnectIntervals = "1,2,4,8,16,32,64";
      };
    };
  };

  # Exposed on the system PATH so the KDE global shortcut (Ctrl+Shift+C)
  # and the .desktop-based command shortcut can both call it by name.
  environment.systemPackages = [ bluetoothConnectScript ];

  services.blueman.enable = false;

  systemd.services.bluetooth-trust-headphones = {
    description = "Trust & auto-connect AirPods & Bluetooth Headphones on boot";
    after = [ "bluetooth.service" ];
    wants = [ "bluetooth.service" ];
    wantedBy = [ "bluetooth.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart =
        (map
          (mac: "${pkgs.bash}/bin/bash -c '${pkgs.bluez}/bin/bluetoothctl trust ${mac} || true'")
          headphoneDevices)
        ++ [ "${bluetoothConnectScript}/bin/bt-connect-headphones 10 3" ];
    };
  };

  systemd.services.bluetooth-reconnect-on-resume = {
    description = "Reconnect Bluetooth headphones after resume";
    after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      ExecStart = "${bluetoothConnectScript}/bin/bt-connect-headphones 10 3";
    };
  };
}