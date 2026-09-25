# Archipelago WebHost service. One process serves the whole local stack: web
# UI (seed generation, option pages, tracker), in-process room hosting
# (GAME_PORTS pool), and the web tracker.
# State: /var/lib/archipelago/ (config.yaml, ap.db3, uploads/, logs/, Players/)
# and ~/.local/share/Archipelago/ (user_path fallback; custom worlds load from
# ~/.local/share/Archipelago/worlds/).
{ config, pkgs, lib, ... }:

let
  cfg = config.services.archipelago;

  configTemplate = pkgs.writeText "archipelago-config.yaml" ''
    # WebHost config; seeded by archipelago-init only when missing, edit freely.
    # See the upstream docs/webhost sample.yaml for all options.

    # Web hosting port (Caddy fronts it at https://archipelago.local).
    PORT: ${toString cfg.port}

    # Address encoded into generated patches for client auto-connect.
    HOST_ADDRESS: ${cfg.hostAddress}

    # Ports used for in-process game hosting.
    GAME_PORTS: [49152-65535, 0]

    # Database (Pony ORM). The filename MUST be an absolute path.
    PONY:
      provider: "sqlite"
      filename: "/var/lib/archipelago/ap.db3"
      create_db: true

    # Maximum players rolled on the web UI (roll locally and upload above this).
    MAX_ROLL: 20

    # Abort queued generations after this many seconds (null disables).
    JOB_TIME: 600
  '';
in
{
  options.services.archipelago = {
    enable = lib.mkEnableOption
      "the Archipelago WebHost (multiworld server + web tracker + seed generator)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.archipelago;
      defaultText = lib.literalExpression "pkgs.archipelago";
      description = "Archipelago package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8090;
      description = "TCP port the WebHost listens on (loopback; Caddy fronts it at https://archipelago.local).";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "archipelago.local";
      description = "Address encoded into generated patches for client auto-connect.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "b";
      description = "User the WebHost runs as (owns /var/lib/archipelago and the custom-worlds directory).";
    };
  };

  config = lib.mkIf cfg.enable {
    # First-run seeding: config.yaml, the skeleton world, and the data tree
    # (sprites, lua connectors, Players, manifest.json). The cp steps are
    # idempotent (existence-guarded) so user edits survive; the final chmod
    # re-asserts owner write bits on every boot.
    #
    # Why the chmod: Nix strips write bits on store import, so WebHost's
    # one-time home copy (shutil.copytree/copy2, Utils.user_path) would
    # produce a read-only home tree, and a re-copy (triggered when the
    # manifest content changes, e.g. a version bump) would crash overwriting
    # it. Seeding with write bits keeps the home tree writable, makes the
    # custom world user-editable, and lets any re-copy overwrite cleanly.
    systemd.services.archipelago-init = {
      description = "Archipelago first-run state seeding (config.yaml, skeleton world, data tree)";
      wantedBy = [ "multi-user.target" ];
      before = [ "archipelago.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        StateDirectory = "archipelago";
      };
      script = ''
        set -euo pipefail

        if [ ! -f /var/lib/archipelago/config.yaml ]; then
          install -m 0644 ${configTemplate} /var/lib/archipelago/config.yaml
          echo "archipelago-init: seeded /var/lib/archipelago/config.yaml"
        fi

        home_ap="/home/${cfg.user}/.local/share/Archipelago"

        # Custom world: seed once, keep user-editable.
        if [ ! -d "$home_ap/worlds/skeleton" ]; then
          install -d -m 0755 "$home_ap/worlds"
          cp -r ${cfg.package}/share/archipelago/worlds/skeleton "$home_ap/worlds/"
          echo "archipelago-init: seeded $home_ap/worlds/skeleton"
        fi

        # Data tree that user_path() would otherwise copytree from the read-only store.
        for dn in data/sprites data/lua Players; do
          if [ ! -d "$home_ap/$dn" ]; then
            install -d -m 0755 "$home_ap/$(dirname "$dn")"
            cp -r "${cfg.package}/lib/archipelago/$dn" "$home_ap/$dn"
            echo "archipelago-init: seeded $home_ap/$dn"
          fi
        done

        # Marks a "proper install": present in the home dir, so user_path()
        # skips its one-time home copy.
        if [ ! -f "$home_ap/manifest.json" ]; then
          install -m 0644 ${cfg.package}/lib/archipelago/manifest.json "$home_ap/manifest.json"
          echo "archipelago-init: seeded $home_ap/manifest.json"
        fi

        chmod -R u+w "$home_ap"
      '';
    };

    systemd.services.archipelago = {
      description = "Archipelago WebHost (multiworld server + web tracker + seed generator)";
      after = [ "network.target" "archipelago-init.service" ];
      wants = [ "archipelago-init.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        StateDirectory = "archipelago";
        WorkingDirectory = "/var/lib/archipelago";
        ExecStart = "${cfg.package}/bin/archipelago-webhost";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
