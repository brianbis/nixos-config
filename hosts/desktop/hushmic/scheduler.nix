{ lib, pkgs, ... }:

# hushmic (real-time DPDFNet inference) runs on cpu6/7, pinned via the user
# service's CPUAffinity. Hold those cores at performance governor + EPP
# statically so there is no runtime flapping or low-clock artifacts.
let
  # The dedicated audio cores: the two 5.8 GHz P-cores (highest turbo on
  # this machine).
  audioCores = [ "cpu6" "cpu7" ];

  # -u without -e: a failed sysfs write (read-only fs, transient race) must
  # not abort the script mid-loop; the core-pin guard re-checks every 60s and
  # self-heals any drift.
  setAudioCores = pkgs.writeShellScript "hushmic-audio-cores" ''
    ${pkgs.bash}/bin/bash -uo pipefail
    for cpu in /sys/devices/system/cpu/${lib.concatStringsSep " " audioCores}; do
      if [ -e "$cpu/cpufreq/scaling_governor" ]; then
        echo performance > "$cpu/cpufreq/scaling_governor" || true
      fi
      if [ -e "$cpu/cpufreq/energy_performance_preference" ]; then
        echo performance > "$cpu/cpufreq/energy_performance_preference" || true
      fi
    done
  '';

  # Fallback for runtime drift: the udev rule in host.nix is the primary
  # mechanism, this re-asserts the pin every 60s. If sysfs is read-only
  # (HWP lock) it logs once and gives up instead of spamming the journal.
  corePinGuard = pkgs.writeShellScript "hushmic-core-pin-guard" ''
    ${pkgs.bash}/bin/bash -uo pipefail
    export PATH="${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:$PATH"
    sm=${setAudioCores}
    warned_ro=0
    while :; do
      drifted=0
      for cpu in /sys/devices/system/cpu/${lib.concatStringsSep " " audioCores}; do
        g=$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null || true)
        e=$(cat "$cpu/cpufreq/energy_performance_preference" 2>/dev/null || true)
        if [ "$g" != "performance" ] || [ "$e" != "performance" ]; then
          drifted=1
          break
        fi
      done
      if [ "$drifted" -eq 1 ]; then
        $sm
        for cpu in /sys/devices/system/cpu/${lib.concatStringsSep " " audioCores}; do
          g=$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null || echo "?")
          if [ "$g" != "performance" ]; then
            if [ "$warned_ro" -eq 0 ]; then
              logger -t hushmic-core-pin "WARN: $(basename $cpu) governor=$g (sysfs read-only, HWP lock; giving up)"
              warned_ro=1
            fi
          fi
        done
      fi
      sleep 60
    done
  '';

  probeDaemon = pkgs.writeShellScript "hushmic-probe-daemon" ''
    ${pkgs.bash}/bin/bash -uo pipefail
    export PATH="${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gawk}/bin:${pkgs.procps}/bin:${pkgs.jq}/bin:${pkgs.systemd}/bin:${pkgs.util-linux}/bin:${pkgs.pipewire}/bin:${pkgs.bash}/bin:$PATH"
    probe=/etc/nixos/hosts/desktop/hushmic/probe.sh
    out=$LOGS_DIRECTORY
    ring=$out/ring
    errors=$out/errors
    while :; do
      # Tolerate transient probe failures so one bad run cannot kill the daemon.
      ${pkgs.bash}/bin/bash "$probe" || echo "$(date -u +%FT%TZ) probe failed: $?" >> "$errors"
      cat "$out/latest" >> "$ring" 2>/dev/null || true
      # Keep the ring bounded: truncate only when over the cap, not every tick.
      if [ -s "$ring" ] && [ "$(wc -l < "$ring")" -gt 3000 ]; then
        tail -n 3000 "$ring" > "$ring.tmp" && mv -f "$ring.tmp" "$ring"
      fi
      # Same for the error log, so a persistent probe bug cannot grow it forever.
      if [ -s "$errors" ] && [ "$(wc -l < "$errors")" -gt 500 ]; then
        tail -n 500 "$errors" > "$errors.tmp" && mv -f "$errors.tmp" "$errors"
      fi
      sleep 2
    done
  '';
in
{
  systemd.services.hushmic-audio-cores = {
    description = "Pin audio cores (cpu6/7) to performance governor + EPP";
    # sysinit.target: must run before intel_pstate HWP init locks cpufreq
    # sysfs; multi-user.target is too late (files are 644). No Before=: a
    # RemainAfterExit oneshot ordered before its wantedBy target cycles.
    wantedBy = [ "sysinit.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setAudioCores;
    };
  };

  systemd.services.hushmic-core-pin = {
    description = "Re-assert audio core governor/EPP pin if drifted";
    wantedBy = [ "sysinit.target" ];
    wants = [ "hushmic-audio-cores.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = corePinGuard;
      Restart = "always";
      RestartSec = 5;
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
      # World-readable (0755) so jailed agents can read probe state without a
      # dedicated jail mount.
      LogsDirectory = "hushmic";
    };
  };
}