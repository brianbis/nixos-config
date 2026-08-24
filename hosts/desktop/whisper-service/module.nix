{ config, options, pkgs, lib, ... }:

let
  cfg = config.services.whisper-service;
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.whisper-service = {
    enable = mkEnableOption "whisper-service: GPU-accelerated Whisper transcription with on-demand VRAM residency";

    package = mkOption {
      type = types.package;
      # No default: point this at the flake's package, e.g. via a flake input
      #   inputs.whisper-service.url = "path:./hosts/desktop/whisper-service";
      #   services.whisper-service.package = inputs.whisper-service.packages.${system}.whisper-service;
      description = "The whisper-service derivation (this flake's default package).";
    };

    model = mkOption {
      type = types.str;
      default = "large-v3";
      description = "Default Whisper model (tiny/base/small/medium/large-v3 or a local path).";
    };

    port = mkOption {
      type = types.port;
      default = 8790;
      description = "HTTP port.";
    };

    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Bind address.";
    };

    idleTimeout = mkOption {
      type = types.int;
      default = 120;
      description = "Seconds of idle before the model is unloaded from VRAM (0 = keep loaded).";
    };

    autoStop = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Exit the whole service process (code 0) once the model is released —
        by the idle reaper or an explicit /unload — so that neither VRAM nor
        host memory is held between requests ("reduce to almost 0"). The
        socket unit keeps the port bound and re-activates the service on the
        next connection. Set to false to keep the process resident between
        requests (only VRAM is released when idle).
      '';
    };

    device = mkOption {
      type = types.str;
      default = "auto";
      description = "Inference device: auto | cuda | cpu.";
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra WHISPER_* environment variables.";
    };

    # Groups that own the NVIDIA device nodes (/dev/nvidia*). The service
    # user must be a member to open them; without it ctranslate2's CUDA init
    # fails and it silently reports 0 devices (CPU fallback). On NixOS the
    # nodes are in the `video` group; override if your host uses another.
    gpuGroups = mkOption {
      type = types.listOf types.str;
      default = [ "video" ];
      description = "Groups owning the GPU device nodes, added to the service user so it can open /dev/nvidia*.";
    };

    # The host's NVIDIA *driver* package (e.g. config.hardware.nvidia.package).
    # libctranslate2 dlopen()s libcuda.so.1 (the driver stub) at runtime; it is
    # neither in the wheel's RUNPATH nor in the store's ldconfig cache, so the
    # service needs the driver's lib dir on LD_LIBRARY_PATH or CUDA init fails
    # and ctranslate2 falls back to CPU.
    nvidiaDriver = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "NVIDIA driver package providing libcuda.so.1; its /lib is added to the service's LD_LIBRARY_PATH.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.whisper = {
      isSystemUser = true;
      group = "whisper";
      description = "whisper-service";
      # Membership in the GPU device group(s) so the service can open
      # /dev/nvidia* and ctranslate2 can initialise CUDA.
      extraGroups = cfg.gpuGroups;
    };
    users.groups.whisper = { };

    # Socket activation: the *socket* unit (kernel-held, ~0 memory) owns the
    # port. The service process only exists between a connection and the
    # model's release — with autoStop it exits (code 0) after the idle
    # window, leaving nothing running until the next request.
    systemd.sockets.whisper-service = {
      description = "Whisper transcription service socket (socket activation)";
      wantedBy = [ "sockets.target" ];
      # Deliberately no After=network.target here: this socket is pulled in
      # by sockets.target (ordered *before* basic.target), while
      # network.target on this host sits after wpa_supplicant.service, which
      # sits after basic.target. Ordering the socket after network.target
      # creates a cycle (socket -> network.target -> wpa_supplicant ->
      # basic.target -> sockets.target -> socket) and systemd breaks it by
      # deleting the socket's start job. Binding a TCP socket needs no
      # network to be up: the service only starts when a client connects.

      socketConfig = {
        # host:port so the module's `host` option keeps controlling the bind
        # address; the service itself binds nothing when socket-activated.
        ListenStream = "${cfg.host}:${toString cfg.port}";
        # The service user owns the socket and its accepted connections.
        User = "whisper";
        Group = "whisper";
      };
    };

    systemd.services.whisper-service = {
      description = "Whisper transcription service (socket-activated, on-demand VRAM residency)";
      # No wantedBy: the service is started by the socket unit on demand and
      # stops again after the idle window (autoStop). It must not be pulled
      # in at boot — that would keep the process (and its base RSS) resident.
      after = [ "whisper-service.socket" ];

      serviceConfig = {
        User = "whisper";
        Group = "whisper";
        # The clean exit after an idle release is exit code 0 (success), so
        # "on-failure" would not restart a crash either way; "on-abnormal"
        # restarts only on signal/coredump and never after an auto-stop.
        Restart = "on-abnormal";
        RestartSec = 5;
        # systemd creates /var/cache/whisper-service owned by the service
        # user before ExecStart. (A preStart script runs as whisper and
        # cannot mkdir/chown under the root-owned /var/cache.)
        CacheDirectory = [ "whisper-service" ];
        ExecStart = "${cfg.package}/bin/whisper-serve";
        # systemd's Environment option is a list of KEY=VALUE strings.
        # Note: the service reads WHISPER_IDLE_TIMEOUT (underscore), so the
        # names are written explicitly rather than derived from option names.
        Environment =
          (lib.mapAttrsToList (name: value: "${name}=${toString value}") cfg.extraEnv)
          ++ [
            "WHISPER_MODEL=${cfg.model}"
            "WHISPER_PORT=${toString cfg.port}"
            "WHISPER_HOST=${cfg.host}"
            "WHISPER_IDLE_TIMEOUT=${toString cfg.idleTimeout}"
            "WHISPER_DEVICE=${cfg.device}"
            "WHISPER_AUTO_STOP=${lib.boolToString cfg.autoStop}"
          ]
          # libcuda.so.1 (driver stub) is dlopen()ed by libctranslate2 but is
          # not in its RUNPATH or the ldconfig cache, so point LD_LIBRARY_PATH
          # at the host driver's lib dir.
          ++ lib.optionals (cfg.nvidiaDriver != null) [
            "LD_LIBRARY_PATH=${cfg.nvidiaDriver}/lib"
          ];
      };

      environment = {
        # config.py appends "/whisper-service" to XDG_CACHE_HOME, so the cache
        # root becomes /var/cache/whisper-service (matching CacheDirectory).
        XDG_CACHE_HOME = "/var/cache";
      };
    };
  };
}