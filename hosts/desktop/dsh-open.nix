{ lib, pkgs, ... }:

let
  users = import ../../home/users.nix;

  b = users.b.username;
  bHome = users.b.homeDirectory;
  llmUser = users.llm.username;

  code = "${pkgs.vscode}/bin/code";

  handler = pkgs.writeShellApplication {
    name = "dsh-open-handler";

    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];

    text = ''
      set -u

      log() {
        echo "dsh-open: $*" >&2
      }

      # fd 3 is the connected socket created by Accept=true.
      IFS= read -r path <&3 || path=""

      if [ -z "$path" ]; then
        echo "err: empty path" >&3
        exit 0
      fi

      log "open request: $path"

      if [ ! -f "$path" ]; then
        echo "err: not a regular file" >&3
        exit 0
      fi

      # This service runs as b, so these refer to b's user manager.
      BUID=$(${pkgs.coreutils}/bin/id -u)
      RUNTIME="/run/user/$BUID"

      if [ ! -d "$RUNTIME" ]; then
        echo "err: no runtime dir $RUNTIME" >&3
        exit 0
      fi

      if [ ! -S "$RUNTIME/bus" ]; then
        echo "err: b's user bus does not exist: $RUNTIME/bus" >&3
        exit 0
      fi

      # These variables are needed by systemctl --user/systemd-run --user
      # themselves. They must be in the handler's environment, not merely
      # passed with --setenv to the transient service.
      export XDG_RUNTIME_DIR="$RUNTIME"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

      log "runtime: $XDG_RUNTIME_DIR"
      log "user bus: $DBUS_SESSION_BUS_ADDRESS"

      if ! ${pkgs.systemd}/bin/systemctl --user is-system-running >/dev/null 2>&1; then
        echo "err: b's user systemd manager is not reachable" >&3
        exit 0
      fi

      # The graphical desktop normally imports DISPLAY/WAYLAND_DISPLAY and
      # related variables into b's user manager. Query that environment
      # directly instead of trying to reconstruct it from loginctl.
      USER_ENV=$(
        ${pkgs.systemd}/bin/systemctl --user show-environment 2>/dev/null || true
      )

      if [ -z "$USER_ENV" ]; then
        echo "err: unable to read b's user-manager environment" >&3
        exit 0
      fi

      WAYLAND_DISPLAY=""
      DISPLAY=""
      XDG_CURRENT_DESKTOP=""
      XDG_SESSION_TYPE=""
      XAUTHORITY=""

      while IFS= read -r kv; do
        case "$kv" in
          WAYLAND_DISPLAY=*)
            WAYLAND_DISPLAY="''${kv#WAYLAND_DISPLAY=}"
            ;;
          DISPLAY=*)
            DISPLAY="''${kv#DISPLAY=}"
            ;;
          XDG_CURRENT_DESKTOP=*)
            XDG_CURRENT_DESKTOP="''${kv#XDG_CURRENT_DESKTOP=}"
            ;;
          XDG_SESSION_TYPE=*)
            XDG_SESSION_TYPE="''${kv#XDG_SESSION_TYPE=}"
            ;;
          XAUTHORITY=*)
            XAUTHORITY="''${kv#XAUTHORITY=}"
            ;;
        esac
      done <<EOF
      $USER_ENV
      EOF

      # Fall back to discovering the display sockets if the user manager
      # doesn't currently have the compositor variables.
      if [ -z "$WAYLAND_DISPLAY" ]; then
        for w in "$RUNTIME"/wayland-*; do
          if [ -S "$w" ]; then
            WAYLAND_DISPLAY="$(${pkgs.coreutils}/bin/basename "$w")"
            break
          fi
        done
      fi

      if [ -z "$DISPLAY" ]; then
        for x in "$RUNTIME"/X11-unix/X*; do
          if [ -S "$x" ]; then
            display="''${x##*/}"
            display="''${display#X}"
            DISPLAY=":$display"
            break
          fi
        done
      fi

      log "graphical environment:"
      log "  XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
      log "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
      log "  DISPLAY=$DISPLAY"
      log "  XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"

      SYSTEMD_ARGS=(
        "--user"
        "--quiet"
        "--collect"
        "--unit=dsh-open-code-$$-''${RANDOM}"
        "--setenv=XDG_RUNTIME_DIR=$RUNTIME"
        "--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME/bus"
        "--setenv=HOME=${bHome}"
      )

      if [ -n "$WAYLAND_DISPLAY" ]; then
        SYSTEMD_ARGS+=(
          "--setenv=WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
        )
      fi

      if [ -n "$DISPLAY" ]; then
        SYSTEMD_ARGS+=(
          "--setenv=DISPLAY=$DISPLAY"
        )
      fi

      if [ -n "$XDG_CURRENT_DESKTOP" ]; then
        SYSTEMD_ARGS+=(
          "--setenv=XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
        )
      fi

      if [ -n "$XDG_SESSION_TYPE" ]; then
        SYSTEMD_ARGS+=(
          "--setenv=XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
        )
      fi

      if [ -n "$XAUTHORITY" ]; then
        SYSTEMD_ARGS+=(
          "--setenv=XAUTHORITY=$XAUTHORITY"
        )
      fi

      ERRF="/tmp/dsh-open-err.$$"

      # systemd-run --user connects to b's user manager because the handler
      # itself is running as b and XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS
      # have been exported above.
      if ${pkgs.systemd}/bin/systemd-run \
          "''${SYSTEMD_ARGS[@]}" \
          ${code} "$path" \
          >"$ERRF" 2>&1
      then
        log "code launched for: $path"
        echo "ok" >&3
      else
        ERR=$(
          ${pkgs.coreutils}/bin/head -c 500 "$ERRF" 2>/dev/null || true
        )

        log "code launch failed: $ERR"

        if [ -n "$ERR" ]; then
          echo "err: code launch failed: $ERR" >&3
        else
          echo "err: code launch failed" >&3
        fi
      fi

      rm -f "$ERRF"
      exit 0
    '';
  };

in
{
  # The directory must exist before the socket is created.
  systemd.tmpfiles.rules = [
    "d /run/dsh-open 0755 ${llmUser} ${llmUser} -"
  ];

  # Agent-only Unix socket.
  systemd.sockets.dsh-open = {
    description =
      "dsh-open: agent-only Unix socket for opening files in b's graphical session";

    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "/run/dsh-open/open.sock";

      SocketUser = llmUser;
      SocketGroup = llmUser;
      SocketMode = "0600";

      DirectoryMode = "0755";

      # Each connection gets its own dsh-open@.service instance.
      Accept = true;
    };
  };

  # The handler runs as b so it can reach b's user systemd manager and
  # graphical-session resources.
  systemd.services."dsh-open@" = {
    description =
      "dsh-open: open a path in ${b}'s graphical session";

    serviceConfig = {
      Type = "simple";
      User = b;
      ExecStart = "${handler}/bin/dsh-open-handler";
    };
  };
}