{ config, lib, pkgs, inputs, ... }:

let
  imsg = inputs.imsg.packages.${pkgs.system}.default;
in
{
  # Why a timer: the GUI only re-reads the local store and never issues a new
  # Sync (the daemon does one initial sync at login, then stops), so this
  # timer runs `imsg sync` on an interval to keep the store fresh.

  # Plain per-user timer, not gated behind the linger daemon: at boot under
  # linger=true the Secret Service key is unavailable until login, and a
  # blocking wait there hung HM's user-unit restart during reloadSystemd.
  systemd.user.services.imsg-sync = {
    Unit = {
      Description = "imsg store refresh (fetch new messages from phone)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${imsg}/bin/imsg sync";
    };
    Install = { };
  };

  systemd.user.timers.imsg-sync = {
    Unit = {
      Description = "Periodic imsg store refresh";
    };
    Timer = {
      OnCalendar = "*:*:0/15";
      Persistent = false;
      Unit = "imsg-sync.service";
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Drop the wants symlink left by a previous `imsg daemon install`: it's a
  # foreign link Home Manager can't back up (check-link-targets.sh only backs
  # up regular files), so remove it before the collision check.
  home.activation.removeStaleImsgUnit = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    imsgDir="${config.xdg.configHome}/systemd/user"
    rm -f "$imsgDir/default.target.wants/imsg-daemon.service"
  '';

  # Stale autostart entry that ran bare `imsg` (no subcommand) at session
  # start and exited 2 (INVALIDARGUMENT). The GUI self-provisions its own
  # broker on launch.
  home.activation.removeImsgAutostart = ''
    rm -f "${config.home.homeDirectory}/.config/autostart/imsg.desktop" \
          "${config.home.homeDirectory}/.local/share/autostart/imsg.desktop"
  '';
}
