# zomboid/server.nix
# NixOS module: Project Zomboid dedicated server.
#
# The mod list (WorkshopItems=/Mods=) is rendered from the collection URL(s)
# at RUNTIME by the zomboid-plugins oneshot (plugins.nix); the rest of the
# .ini (Map=, extra settings) is static Nix baked into the same script. The
# game itself is installed by an opt-in steamcmd oneshot (installGame) — a
# single steamcmd call at install time.
#
# Lifecycle / failure domains:
#   * zomboid-install  (oneshot, boot): steamcmd installs/updates the game.
#   * zomboid-plugins  (oneshot, boot): fetches the collection and renders
#     the .ini. A failed fetch fails this unit only — the system still boots
#     and the server starts with the previous (or empty) mod list.
#   * zomboid          (service): the game. Starts after both oneshots.
#
# Verified facts this module relies on:
#   * Steam app id 108600 is the PZ dedicated server app; the game binary is
#     not fetchable from a public mirror, so the game files are installed at
#     runtime by the steamcmd oneshot (a systemd service, not a Nix
#     derivation — the correct place for that network side effect). The
#     steamcmd binary itself is the Nix package pkgs.steamcmd: it bundles the
#     steamcmd tarball at build time (fixed hash) and wraps the 32-bit binary
#     with steam-run (an FHS env providing the 32-bit glibc), so it runs on
#     this x86_64-only flake with no runtime download.
#   * The settings file is $HOME/Zomboid/Server/<SERVERNAME>.ini; the
#     -servername flag selects which .ini is used and the save folder, and
#     the server auto-generates it with defaults if absent (pzwiki
#     "Dedicated server"). Mods/saves/logs live under $HOME/Zomboid/{mods,
#     Saves,Logs}.
#   * WorkshopItems= (semicolon-separated numeric Workshop IDs) tells the
#     server which items to download; Mods= (semicolon-separated text Mod
#     IDs, the `name` field of each mod.info) is the actual enable list.
#     The server downloads + loads Workshop mods itself at boot.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.zomboid;

  # The rendering script: fetches the collection(s) at runtime and renders the
  # full <SERVERNAME>.ini into the target path given as $1.
  plugins = (import ./plugins.nix) {
    inherit pkgs;
    collectionUrls = cfg.collectionUrls;
    maps = cfg.maps;
    extraSettings = cfg.extraSettings;
  };

  # Faithful translation of the Pterodactyl egg's start line into a shell
  # wrapper so the relative LD_LIBRARY_PATH / LD_PRELOAD semantics are
  # preserved exactly.
  startScript = pkgs.writeShellScript "zomboid-start" ''
    # The game binary is installed by the zomboid-install oneshot. If it is
    # missing, that oneshot failed; fail with a clear diagnostic instead of
    # a bare 127 from `exec`.
    if [ ! -e "${cfg.dataDir}/ProjectZomboid64" ]; then
      echo "ERROR: ${cfg.dataDir}/ProjectZomboid64 not found; the zomboid-install oneshot likely failed. Check its log." >&2
      exit 1
    fi
    export PATH="${cfg.dataDir}/jre64/bin:$PATH"
    # The native launcher and bundled JVM need the C++ runtime (libstdc++,
    # libgcc_s) and glibc, which aren't in the game's own lib dirs on NixOS.
    export LD_LIBRARY_PATH="${cfg.dataDir}/linux64:${cfg.dataDir}/natives:${cfg.dataDir}:${cfg.dataDir}/jre64/lib/amd64:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.glibc}/lib"
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

  # steamcmd install/update oneshot. Uses the Nix-provided steamcmd
  # (pkgs.steamcmd), which bundles the steamcmd tarball at build time and
  # wraps the 32-bit binary with steam-run so it runs on this x86_64-only
  # flake — no runtime download, no 32-bit glibc LD_LIBRARY_PATH hacks.
  #
  # steamcmd is known to exit 0 even when the depot download never starts
  # ("Timed out waiting for update to start, bailing" -> "Success! App
  # fully installed"), typically because a stale app manifest makes it think
  # the app is already installed. So the script wipes the stale Steam state
  # when the binary is missing, verifies the binary actually exists, retries
  # a few times, and fails loudly if it still fails — so the zomboid.service
  # `requires=` stops the restart loop instead of looping on a missing binary.
  installScript = pkgs.writeShellScript "zomboid-install" ''
    set -euo pipefail
    # The steamcmd wrapper keeps its own state under $HOME/.local/share/Steam;
    # point HOME at dataDir so that state stays under dataDir.
    export HOME="${cfg.dataDir}"
    steamcmd_bin="${pkgs.steamcmd}/bin/steamcmd"

    run_steamcmd() {
      "$steamcmd_bin" \
        +force_install_dir "${cfg.dataDir}" \
        +login anonymous +app_update 108600 +quit
    }

    if [ ! -e "${cfg.dataDir}/ProjectZomboid64" ]; then
      # Force a fresh install: remove the stale app manifest and the Steam
      # client state that make steamcmd (buggily) report "fully installed"
      # without downloading the depot.
      rm -rf "${cfg.dataDir}/steamapps" "${cfg.dataDir}/.local/share/Steam"
    fi

    for attempt in 1 2 3; do
      run_steamcmd || true
      if [ -e "${cfg.dataDir}/ProjectZomboid64" ]; then
        echo "Project Zomboid installed/updated successfully."
        break
      fi
      echo "Attempt $attempt: ${cfg.dataDir}/ProjectZomboid64 missing; the depot download likely did not start. Retrying..." >&2
      if [ "$attempt" -eq 3 ]; then
        echo "ERROR: ${cfg.dataDir}/ProjectZomboid64 not found after 3 attempts; install failed." >&2
        exit 1
      fi
      sleep 15
    done

    # steamcmd SDK libs (mirrors the Pterodactyl egg install). The steamcmd
    # install lives under the Steam root ($HOME/.local/share/Steam).
    mkdir -p "${cfg.dataDir}/.steam/sdk32" "${cfg.dataDir}/.steam/sdk64"
    cp -f "${cfg.dataDir}/.local/share/Steam/linux32/steamclient.so" "${cfg.dataDir}/.steam/sdk32/" 2>/dev/null || true
    cp -f "${cfg.dataDir}/.local/share/Steam/linux64/steamclient.so" "${cfg.dataDir}/.steam/sdk64/" 2>/dev/null || true
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

    collectionUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://steamcommunity.com/sharedfiles/filedetails/?id=3434919617" ];
      description = ''
        Steam Workshop collection URL(s) whose mods the server loads. The mod
        list (WorkshopItems=/Mods=) is rendered from these at runtime by the
        zomboid-plugins oneshot. Supply only the collection URL(s); the
        per-mod IDs are resolved automatically. Set to [] for a vanilla
        server (no mods).
      '';
    };

    maps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Map folder names for the Map= line. Map mods listed in the collection
        will download and load but their map is only part of the world if its
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

    # Render the mod list from the collection URL(s) at runtime. This is a
    # network operation, so it lives in a systemd oneshot (not the Nix
    # build). If the fetch fails, this unit fails but the system still boots
    # and the server starts with the previous (or empty) mod list.
    systemd.services.zomboid-plugins = {
      description = "Render PZ mod list from Workshop collection";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "zomboid.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "zomboid";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${plugins} Zomboid/Server/${cfg.serverName}.ini";
      };
    };

    systemd.services.zomboid-install = lib.mkIf cfg.installGame {
      description = "Project Zomboid game install/update (steamcmd)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "zomboid.service" ];
      # The installScript uses coreutils (mkdir/cp); the steamcmd binary and
      # its steam-run FHS env are absolute store paths, so no other PATH
      # entries are needed.
      path = [ pkgs.coreutils pkgs.bash ];
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
        [ "network-online.target" "zomboid-plugins.service" ]
        ++ lib.optionals cfg.installGame [ "zomboid-install.service" ];
      wants = [ "network-online.target" "zomboid-plugins.service" ];
      # The game binary is a hard prerequisite: if the install oneshot fails,
      # the server must not start (and loop on a missing binary).
      requires = lib.optionals cfg.installGame [ "zomboid-install.service" ];
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

      # Ensure the config dir exists even if the zomboid-plugins oneshot
      # failed (its resolver only creates the dir after a successful fetch).
      # The PZ server auto-generates the .ini with defaults if it is absent.
      preStart = ''
        mkdir -p Zomboid/Server
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
