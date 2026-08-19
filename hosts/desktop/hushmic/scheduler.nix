{ pkgs, ... }:

# Static audio-core pinning for the 13900K. hushmic (DPDFNet ONNX inference in
# a real-time PipeWire thread) is pinned to cpu6/7, the two 5.8 GHz P-cores, by
# the hushmic user service's CPUAffinity (see audio.nix). Those cores are held
# at performance governor + EPP permanently so there is zero runtime flapping:
# no debounce, no watcher reacting to process start/stop, and no first-several
# seconds of low-clock artifacts when a session begins. Everything else stays
# on powersave/balance_power. TLP is disabled in host.nix; thermald only caps
# max frequency on thermal events and is left in place.
let
  # The dedicated audio cores: highest-turbo P-cores on this machine.
  setAudioCores = pkgs.writeShellScript "hushmic-audio-cores" ''
    ${pkgs.bash}/bin/bash -euo pipefail
    for cpu in /sys/devices/system/cpu/cpu6 /sys/devices/system/cpu/cpu7; do
      [ -e "$cpu/cpufreq/scaling_governor" ] && echo performance > "$cpu/cpufreq/scaling_governor"
      [ -e "$cpu/cpufreq/energy_performance_preference" ] && echo performance > "$cpu/cpufreq/energy_performance_preference"
    done
  '';

  # Re-asserts the pin every 60s in case an external actor (thermald, a
  # power-profiles-daemon revival, manual tinkering) drifts the cores. Cheap:
  # two sysfs reads/writes per minute.
  corePinGuard = pkgs.writeShellScript "hushmic-core-pin-guard" ''
    ${pkgs.bash}/bin/bash -euo pipefail
    sm=${setAudioCores}
    while :; do
      g=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_governor 2>/dev/null || true)
      e=$(cat /sys/devices/system/cpu/cpu6/cpufreq/energy_performance_preference 2>/dev/null || true)
      if [ "$g" != "performance" ] || [ "$e" != "performance" ]; then
        $sm
      fi
      sleep 60
    done
  '';

  probeDaemon = pkgs.writeShellScript "hushmic-probe-daemon" ''
    ${pkgs.bash}/bin/bash -uo pipefail
    export PATH="${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gawk}/bin:${pkgs.procps}/bin:${pkgs.jq}/bin:${pkgs.systemd}/bin:${pkgs.bash}/bin:$PATH"
    probe=/etc/nixos/hosts/desktop/hushmic/probe.sh
    ring=/var/log/hushmic/ring
    while :; do
      # Tolerate transient probe failures (set -e here used to kill the whole
      # daemon when a script edit was mid-flight or a command misbehaved).
      ${pkgs.bash}/bin/bash "$probe" || echo "probe failed: $?" >> /var/log/hushmic/errors
      cat /var/log/hushmic/latest >> "$ring" 2>/dev/null || true
      # Keep the ring bounded.
      if [ -s "$ring" ]; then
        tail -n 3000 "$ring" > "$ring.tmp" && mv -f "$ring.tmp" "$ring"
      fi
      sleep 2
    done
  '';
in
{
  systemd.services.hushmic-audio-cores = {
    description = "Pin audio cores (cpu6/7) to performance governor + EPP";
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setAudioCores;
    };
  };

  systemd.services.hushmic-core-pin = {
    description = "Re-assert audio core governor/EPP pin if drifted";
    wantedBy = [ "multi-user.target" ];
    requires = [ "hushmic-audio-cores.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = corePinGuard;
      Restart = "always";
      RestartSec = 2;
    };
  };

  systemd.services.hushmic-probe = {
    description = "hushmic/PipeWire state probe ring";
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = probeDaemon;
      Restart = "always";
      RestartSec = 2;
      # Probe output lives in /var/log/hushmic (tmpfiles below), not the
      # root-only crush-system state tree.
      LogsDirectory = "hushmic";
    };
  };

  systemd.tmpfiles.rules = [
    # World-readable so the jailed agents can read probe state without a
    # dedicated jail mount; only root writes it (probe daemon runs as root).
    "d /var/log/hushmic 0755 root root - -"
  ];
}