{ config, lib, pkgs, catalog, ... }:

# The LLM gate: the one boot-resident front door for the whole model fleet.
#
# One port (the ledger's `gate`, registered as llm.local), one process, and the
# engines' own loopback ports stay private plumbing that only the gate forwards
# to — the per-engine front sockets and their TCP relays are gone.
#
# What the gate adds is the decision the per-engine relays could not make:
# which model actually serves a request (see gate.py — load on demand,
# redirect silently when the card cannot fit the named model, fall back to a
# hosted row). The engines keep their idle-unload lifecycle; it is triggered
# here instead of by a connection.

let
  table = import ../../../../catalog/lib.nix lib catalog;

  gatePkg = pkgs.callPackage ./package.nix { inherit catalog; };
in
{
  # One row per engine, rendered into the stub's table at build time.
  systemd.services.llm-gate = {
    description = "LLM gate: the single front door for the model fleet (127.0.0.1:${toString table.gate.port})";

    # Boot-resident on purpose: the gate is the thing agents talk to, and it
    # holds no VRAM. The models behind it stay on demand.
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = "${pkgs.python3}/bin/python3 ${gatePkg}/gate.py --table ${gatePkg}/table.json";

      # The stub exits 0 only on SIGTERM (a stop), so a restart is a crash.
      Restart = "always";
      RestartSec = "5";
    };

    # systemctl starts/stops the engine units; nvidia-smi is the VRAM reading
    # that decides whether a model can be loaded at all. nvidia-smi ships in
    # the driver package's `bin` output (its `out` carries only nvidia-sleep.sh)
    # and the service's default PATH lacks both — the NixOS `path` option, not
    # a serviceConfig.EnvironmentPATH lvalue (not a systemd directive).
    path = [ pkgs.systemd config.hardware.nvidia.package.bin ];
  };

  # One activity file per engine unit, touched by the gate on every request it
  # routes to that unit. The idle wrappers watch the mtime: it is what keeps
  # their model resident, and its ageing is what releases the VRAM.
  systemd.tmpfiles.rules = [
    "d ${catalog.gate.activityDir} 0755 root root -"
  ];
}
