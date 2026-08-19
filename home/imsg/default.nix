{ config, lib, pkgs, inputs, ... }:

let
  imsg = inputs.imsg.packages.${pkgs.system}.default;
in
{
  # imsg message fetch + a periodic auto-refresh timer.
  #
  # Why a timer: the imsg GUI's refresh button and its interval polling only
  # re-read the local sqlite store (`list_messages` / `threads`). Nothing in
  # the GUI ever issues a new `Sync` request to the broker, and the daemon
  # does one initial sync at login then stops. So new messages never appear
  # until `imsg sync` runs. That CLI subcommand drives the real MAP fetch
  # into the store; this timer runs it on an interval so the store stays
  # fresh and the GUI displays new messages without any manual step.
  #
  # It is a plain per-user systemd service+OnCalendar timer (runs in a
  # normal desktop session, where KWallet/Secret Service is unlocked). It is
  # intentionally NOT gated behind the systemd `default.target`-enabled
  # linger daemon: at boot under `linger = true` the store key (Secret
  # Service / ksecretd) is unavailable until login, and a blocking wait there
  # hung Home Manager's user-unit restart during `reloadSystemd`. The timer
  # unit only starts once the user session is up (session bus present).
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

  # Clean up the hand-written unit + wants synlink from a previous
  # `imsg daemon install`. The main file becomes a .bak; the wants
  # symlink is a foreign link Home Manager cannot back up
  # (check-link-targets.sh only backs up regular files), so drop it
  # before the collision check. HM-owned links are kept.
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
