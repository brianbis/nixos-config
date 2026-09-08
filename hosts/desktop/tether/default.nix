{ config, lib, pkgs, ... }:
let
  cfg = config.services.tether;
in
{
  options.services.tether = {
    enable = lib.mkEnableOption ''
      Tether (Linux + iPhone Continuity bridge) Bluetooth support.

      Enables the BlueZ experimental bearer API required for ANCS notification
      mirroring over LE, and declares the tether-btclass@.service unit that
      sets the Bluetooth Class of Device so MAP/PBAP profile sessions work
      with iPhones.
    '';

    # Which Bluetooth adapter(s) to manage.  Usually just hci0.
    adapters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "hci0" ];
      description = ''
        List of BlueZ adapter names (e.g. hci0) for which the
        tether-btclass@.service will be instantiated.
      '';
    };
  };

  config = let
    btmgmt = "${pkgs.bluez}/bin/btmgmt";
    tetherServiceCfg = adapter: {
      description = "Set Bluetooth Class of Device to A/V Hands-Free on ${adapter} for Tether";
      documentation = [ "https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md" ];

      after = [ "bluetooth.service" ];
      partOf = [ "bluetooth.service" ];

      wantedBy = [ "bluetooth.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };

      # bluetoothd resets the class to its own default on every start, so
      # set it (major 4, minor 8 = A/V Hands-Free) and verify, retrying
      # for ten seconds — mirroring the packaged tether-btclass@.service.
      # The iPhone only offers "Show Message Notifications" / "Sync
      # Contacts" to a device presenting this class, so without it ANCS
      # notification mirroring never engages.
      #
      # Uses the `script` attribute (nixpkgs writes this to its own file and
      # points ExecStart at it) rather than an inline multi-line ExecStart,
      # which systemd rejects as unbalanced quoting.
      script = ''
        for i in $(seq 1 10); do
          ${btmgmt} --index ${adapter} class 4 8 >/dev/null 2>&1
          if ${btmgmt} --index ${adapter} info 2>/dev/null \
             | grep -q "class 0x..0408"; then
            exit 0
          fi
          sleep 1
        done
        exit 1
      '';
    };
  in lib.mkMerge [
    # ANCS needs BlueZ's experimental bearer API (org.bluez.Bearer.LE1),
    # which must be active *before* pairing. main.conf's Experimental=true
    # is equivalent to running bluetoothd with --experimental; it is the
    # declarative way to get it (overriding the nixpkgs module's ExecStart
    # instead is fragile and dropped the -f /etc/bluetooth/main.conf arg).
    (lib.mkIf cfg.enable {
      hardware.bluetooth.settings.General.Experimental = true;
    })

    # Declare tether-btclass@.service units unconditionally; only enable
    # when services.tether.enable is true. This avoids attrset merge conflicts
    # when the module is imported but tether is disabled.
    {
      systemd.services = lib.foldl' (acc: adapter:
        acc // lib.optionalAttrs cfg.enable
          { "tether-btclass@${adapter}" = tetherServiceCfg adapter; })
        {} cfg.adapters;
    }
  ];
}