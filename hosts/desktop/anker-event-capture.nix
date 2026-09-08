# Anker SOLIX MQTT event capture — a long-running, real-time record of the
# device-telemetry (dt) + command (cmd) MQTT stream for the five units (all
# product codes; currently all A1763 / PPS SOLIX C1000 Gen 2), saved as
# daily-rotated NDJSON for future event debugging. When something misbehaves
# (a TOU plan that won't update, a price that jumps, a state that lags), the
# NDJSON under
# /home/llm/anker-solix/data/event_capture/ is the time-stamped source of truth
# for exactly what the cloud reported and what commands were sent.
#
# Runs as the llm user, which owns the venv, the cached MQTT connection info
# (data/anker_mqtt_info.json, with the X.509 cert/key), and the output dir.
# The capture process itself is
#   /home/llm/anker-solix/capture/event_capture.py
# (self-contained; needs no HA). It auto-reconnects on drops and systemd
# Restart=always is the backstop if the process dies.
#
# Note: this is a *runtime-state* service — it reads the MQTT cert/thing from
# the cached cloud-API response in the user's home, so it is intentionally not
# a pure Nix derivation. If the cert or thing name ever changes (e.g. after a
# re-login), refresh data/anker_mqtt_info.json and `systemctl restart
# anker-event-capture`.
{ config, lib, ... }:

let
  cfg = config.services.anker-event-capture;
  users = import ../../home/users.nix;
  llm = users.llm;
  home = llm.homeDirectory;
  venvPython = "${home}/venv/bin/python";
  script = "${home}/anker-solix/capture/event_capture.py";
  mqttInfo = "${home}/anker-solix/data/anker_mqtt_info.json";
  outDir = "${home}/anker-solix/data/event_capture";
in
{
  options.services.anker-event-capture = {
    enable = lib.mkEnableOption "Anker SOLIX MQTT event capture (real-time dt+cmd, daily NDJSON)";

    mode = lib.mkOption {
      type = lib.types.enum [ "events" "full" ];
      default = "events";
      description = ''
        "events" records every command plus only real state transitions of the
        curated event fields (~90% smaller than full). "full" records every
        message verbatim (the firehose) — use it when you need the raw stream.
      '';
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "AXDDJWU0F38500392"  # unit-392
        "AXDDJWU0F38500715"  # office
        "AXDDJWU0F38500093"  # kitchen
        "AXDDJWU0F38500371"  # living-room (TEST)
        "AXDDJWU0F38500609"  # bedroom
      ];
      description = "Device serial numbers to subscribe to (dt + cmd topics).";
    };

    pn = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Product number in the MQTT topic. Empty (default) = wildcard: capture
        every model for the listed serials and decode each message with the
        model from its own topic. Set a specific code (e.g. "A1763") to pin to
        one model.
      '';
    };

    app = lib.mkOption {
      type = lib.types.str;
      default = "anker_power";
      description = "App name in the MQTT topic.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = "Delete NDJSON files older than this many days (~96 MB/day at the current rate).";
    };

    heartbeatSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds between liveness log lines in the journal.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.anker-event-capture = {
      description = "Anker SOLIX MQTT event capture (real-time dt+cmd, daily NDJSON)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = llm.username;
        WorkingDirectory = "${home}/anker-solix";
        ExecStart = "${venvPython} ${script}";
        # Long-running capture: restart on any exit (crash, OOM, cert rotation).
        # systemd's default start limits (5 starts / 10s) prevent a tight loop
        # if a persistent config error (e.g. missing info file) makes it exit
        # immediately.
        Restart = "always";
        RestartSec = "5";
        Environment = [
          "ANKER_MQTT_INFO=${mqttInfo}"
          "ANKER_CAPTURE_OUT=${outDir}"
          "ANKER_CAPTURE_MODE=${cfg.mode}"
          "ANKER_CAPTURE_UNITS=${lib.concatStringsSep "," cfg.units}"
          "ANKER_CAPTURE_PN=${cfg.pn}"
          "ANKER_CAPTURE_APP=${cfg.app}"
          "ANKER_CAPTURE_RETENTION_DAYS=${toString cfg.retentionDays}"
          "ANKER_CAPTURE_HEARTBEAT=${toString cfg.heartbeatSec}"
        ];
      };
    };
  };
}