# Project Zomboid dedicated server, managed declaratively.
#
# Modelled on nixpkgs' services/games/minecraft-server.nix:
#   * immutable config (the <SERVERNAME>.ini) is rendered from options and
#     copied into the mutable data dir by the service's preStart;
#   * a .declarative sentinel marks the file as Nix-owned so we back up the
#     first server-generated copy and never fight the panel's file editor;
#   * mutable state (saves, mods, logs, the game itself) lives in dataDir,
#     outside the store, owned by a dedicated system user.
#
# Verified facts this module relies on (see conversation for sources):
#   * Steam app id 108600 is the PZ *dedicated server* app (Steam store API,
#     pzwiki). The game binary is not fetchable from a public mirror, so the
#     game files are installed at runtime by an opt-in steamcmd oneshot
#     (services.zomboid.installGame) — a systemd service, not a Nix
#     derivation, which is the correct place for that network side effect.
#   * The settings file is $HOME/Zomboid/Server/<SERVERNAME>.ini; the
#     -servername flag selects which .ini is used and the save folder, and
#     the server auto-generates it with defaults if absent (pzwiki
#     "Dedicated server"). Mods/saves/logs live under $HOME/Zomboid/{mods,
#     Saves,Logs}.
#   * WorkshopItems= (semicolon-separated numeric Workshop IDs) tells the
#     server which items to download; Mods= (semicolon-separated text Mod
#     IDs, the `name` field of each mod.info) is the actual enable list.
#     The server downloads + loads Workshop mods itself at boot, so no
#     steamcmd loop is needed for mods.
#
# The default `mods` list is the "B42 Mods" Steam Workshop collection
# (3434919617), resolved via the Steam Web API. Override it per-host with:
#   services.zomboid.mods = { "<workshopId>" = [ "<modId>" ... ]; };

{ config, lib, pkgs, ... }:

let
  cfg = config.services.zomboid;

  # Workshop item IDs (the attr names) -> WorkshopItems= line.
  workshopItems = builtins.attrNames cfg.mods;

  # All Mod IDs, flattened across items and de-duplicated -> Mods= line.
  modIds = lib.unique (lib.concatLists (lib.attrValues cfg.mods));

  # Render the <SERVERNAME>.ini. Nix owns this file; the server only needs
  # the mod/map lines plus whatever the user adds via extraSettings.
  serverIniFile = pkgs.writeText "zomboid-server.ini" (
    ''
      # <SERVERNAME>.ini — managed by NixOS (services.zomboid).
      # Edit the module options, not this file; it is re-applied on every
      # service start and any hand edits are overwritten.
    ''
    + lib.optionalString (workshopItems != [ ])
        ("WorkshopItems=" + (lib.concatStringsSep ";" workshopItems) + "\n")
    + lib.optionalString (modIds != [ ])
        ("Mods=" + (lib.concatStringsSep ";" modIds) + "\n")
    + lib.optionalString (cfg.maps != [ ])
        ("Map=" + (lib.concatStringsSep ";" cfg.maps) + "\n")
    + (lib.concatStringsSep "\n"
        (lib.mapAttrsToList (k: v: "${k}=${v}") cfg.extraSettings))
    + "\n"
  );

  # Faithful translation of the Pterodactyl egg's start line into a shell
  # wrapper so the relative LD_LIBRARY_PATH / LD_PRELOAD semantics are
  # preserved exactly.
  startScript = pkgs.writeShellScript "zomboid-start" ''
    export PATH="${cfg.dataDir}/jre64/bin:$PATH"
    export LD_LIBRARY_PATH="${cfg.dataDir}/linux64:${cfg.dataDir}/natives:${cfg.dataDir}:${cfg.dataDir}/jre64/lib/amd64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_PRELOAD="${cfg.dataDir}/libjsig.so"
    cd "${cfg.dataDir}"
    exec ./ProjectZomboid64 \
      -port ${toString cfg.serverPort} \
      -udpport ${toString cfg.steamPort} \
      -cachedir="${cfg.dataDir}/.cache" \
      -servername "${cfg.serverName}" \
      -adminusername "${cfg.adminUser}" \
      -adminpassword "${cfg.adminPassword}"
  '';

  # steamcmd install/update of the game into dataDir. Mirrors the egg's
  # install script (force_install_dir, anonymous login, app_update validate,
  # sdk32/sdk64 copy). Runs as a oneshot so it is a runtime side effect, not
  # a build-time one.
  installScript = pkgs.writeShellScript "zomboid-install" ''
    set -euo pipefail
    export HOME="${cfg.dataDir}"
    mkdir -p "${cfg.dataDir}/steamcmd" "${cfg.dataDir}/steamapps"
    cd "${cfg.dataDir}/steamcmd"
    if [ ! -x ./steamcmd.sh ]; then
      curl -fsSL -o steamcmd.tar.gz \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
      tar -xzf steamcmd.tar.gz
    fi
    ./steamcmd.sh +force_install_dir "${cfg.dataDir}" \
      +login anonymous +app_update 108600 validate +quit
    # steamcmd SDK libs (mirrors the Pterodactyl egg install).
    mkdir -p "${cfg.dataDir}/.steam/sdk32" "${cfg.dataDir}/.steam/sdk64"
    cp -f linux32/steamclient.so "${cfg.dataDir}/.steam/sdk32/" 2>/dev/null || true
    cp -f linux64/steamclient.so "${cfg.dataDir}/.steam/sdk64/" 2>/dev/null || true
  '';
in
{
  options.services.zomboid = {
    enable = lib.mkEnableOption "the Project Zomboid dedicated server";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/zomboid";
      description = ''
        Persistent directory holding the game files and the $Zomboid config
        tree (Server/, mods/, Saves/, Logs/). Also the service user's home.
        Lives outside the Nix store.
      '';
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      default = "zomboid";
      description = ''
        Server name. Selects which <SERVERNAME>.ini file and save folder the
        server uses (passed as -servername).
      '';
    };

    mods = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {
        "3789069683" = [ "CarltonsBetterBanks" ];
        "3786236842" = [ "ArmorySpawnTableFix" "ArmystorageSpawnTableFix" "VanillaSpawnTableFix" ];
        "3772052709" = [ "SpawnSelector" ];
        "2713257456" = [ "OSL" ];
        "3391145494" = [ "RUNE" ];
        "3539691958" = [ "91fordRanger" ];
        "3008795514" = [ "91geoMetro" ];
        "2799152995" = [ "78amgeneralM35A2" "78amgeneralM35A2extra" "78amgeneralM49A2C" "78amgeneralM50A3" "78amgeneralM62" ];
        "3670064951" = [ "KI5campers" ];
        "2897390033" = [ "97bushmaster" ];
        "3320947974" = [ "82firebird" "82firebirdKITT" ];
        "2642541073" = [ "92amgeneralM998" ];
        "2952802178" = [ "90fordF350ambulance" ];
        "2566953935" = [ "86oshkoshP19A" ];
        "2870394916" = [ "86fordE150" "86fordE150dnd" "86fordE150mm" "86fordE150pd" "86fordE150expanded" ];
        "3642935062" = [ "70roadRunner" ];
        "3171167894" = [ "damnlib" ];
        "2625625421" = [ "isoContainers" ];
        "3451167732" = [ "ModernStatus" ];
        "3470659758" = [ "TheShortcut" ];
        "3536052310" = [ "Neat_Building" "Neat_Building_Buildables_SESCompat" "Neat_Building_Railings" "Neat_Building_UIOnly" ];
        "3502080466" = [ "Neat_Crafting" ];
        "3490188370" = [ "Project_Cook" "Project_Cook_Pixel_Icon_Pack" ];
        "3461263912" = [ "CleanHotBar" ];
        "3434653631" = [ "AWCWF_42" ];
        "3569050120" = [ "Kill" ];
        "3183820077" = [ "guns93" ];
        "3508537032" = [ "NeatUI_Framework" ];
        "3437629766" = [ "CleanUI" ];
        "3397635749" = [ "ThereGoesMyHero" ];
        "3779561845" = [ "LGExtendedPlumbing" ];
        "3763470184" = [ "PropaneExchangeCabinet" ];
        "3631306028" = [ "ParanormalZ" ];
        "2503622437" = [ "SkillRecoveryJournal" ];
        "3077900375" = [ "ChuckleberryFinnAlertSystem" ];
        "2896041179" = [ "errorMagnifier" ];
        "3426448380" = [ "stanks_suicide" ];
        "2920899878" = [ "ReloadAllMagazines" ];
        "2286124931" = [ "CombatText" ];
        "2769706949" = [ "P4TidyUpMeister" ];
        "2684285534" = [ "SpnCloth" ];
        "2714198296" = [ "NoLighterNeeded" ];
        "3378304610" = [ "RepairableWindows" ];
      };
      description = ''
        Mapping of Workshop item ID (numeric, the attr name) to the list of
        Mod IDs it enables (the `name` field of each mod.info). Rendered into
        the WorkshopItems= and Mods= lines of the server .ini. One Workshop
        item may bundle several mods, hence the list.

        Default is the "B42 Mods" Steam Workshop collection (3434919617).
      '';
    };

    maps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Map folder names for the Map= line. Map mods listed in `mods` will
        download and load but their map is only part of the world if its
        folder name is here. Defaults to the vanilla map (no Map= line).
      '';
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Additional raw key=value pairs appended to the server .ini, e.g.
        { "MaxPlayers" = "10"; "PVP" = "False"; }.
      '';
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 16261;
      description = "TCP game port (-port).";
    };

    steamPort = lib.mkOption {
      type = lib.types.port;
      default = 16261;
      description = "UDP Steam/query port (-udpport).";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "In-game admin username (-adminusername).";
    };

    adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        In-game admin password (-adminpassword). For a real deployment source
        this from an age secret, e.g.
        `adminPassword = (builtins.readFile config.age.secrets.zomboid-admin.path);`
      '';
    };

    installGame = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run a steamcmd oneshot at boot to install/update the game (app id
        108600) into dataDir. The game binary is not fetchable from a public
        mirror, so this runtime side effect is the only way to obtain it.
        Set to false if you install the game into dataDir by other means.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    users.users.zomboid = {
      description = "Project Zomboid dedicated server user";
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = true;
      group = "zomboid";
    };
    users.groups.zomboid = { };

    systemd.services.zomboid-install = lib.mkIf cfg.installGame {
      description = "Project Zomboid game install/update (steamcmd)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "zomboid.service" ];
      path = [ pkgs.curl pkgs.gnutar pkgs.bash ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "zomboid";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${installScript}";
      };
    };

    systemd.services.zomboid = {
      description = "Project Zomboid dedicated server";
      wantedBy = [ "multi-user.target" ];
      after =
        [ "network-online.target" ]
        ++ lib.optionals cfg.installGame [ "zomboid-install.service" ];
      wants =
        [ "network-online.target" ]
        ++ lib.optionals cfg.installGame [ "zomboid-install.service" ];
      serviceConfig = {
        User = "zomboid";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${startScript}";
        Restart = "on-failure";
        RestartSec = "5";

        # Safe hardening. The game writes to its home/dataDir (saves, mods,
        # logs, .cache), so ProtectSystem/ProtectHome are intentionally not
        # applied; tighten further once the layout is known to be stable.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        UMask = "0022";
      };

      # Apply the Nix-rendered .ini into the mutable data dir. The
      # .declarative sentinel (same pattern as minecraft-server.nix) means we
      # back up the first server-generated copy and simply refresh on later
      # starts, so Nix owns the file without clobbering a pre-existing one
      # silently.
      preStart = ''
        mkdir -p Zomboid/Server
        if [ -e Zomboid/Server/.declarative ]; then
          cp -f ${serverIniFile} Zomboid/Server/${cfg.serverName}.ini
        else
          if [ -e Zomboid/Server/${cfg.serverName}.ini ]; then
            cp -b --suffix=.stateful Zomboid/Server/${cfg.serverName}.ini
          fi
          cp -f ${serverIniFile} Zomboid/Server/${cfg.serverName}.ini
          echo "This server.ini is managed declaratively by NixOS (services.zomboid)" \
            > Zomboid/Server/.declarative
        fi
        chmod +w Zomboid/Server/${cfg.serverName}.ini
      '';
    };

    networking.firewall = {
      allowedTCPPorts = [ cfg.serverPort ];
      allowedUDPPorts = [ cfg.steamPort ];
    };

    assertions = [
      {
        assertion = cfg.serverName != "";
        message = "services.zomboid.serverName must be non-empty.";
      }
    ];
  };
}