# The one unit shape every on-demand LLM engine shares.
#
# An engine is the shared idle wrapper (./idle-wrapper) running in lifecycle
# mode: it binds no port and relays nothing, the gate starts it on demand, and
# the activity file it stamps is what keeps the model resident. What differs
# per engine — the child command, the environment, the timeouts, what the unit
# requires — is an argument; nothing else belongs in an engine module.
#
# The invariants this file owns:
#  - No wantedBy, ever: an engine must not be boot-resident. The gate starts it
#    with `systemctl start --no-block <unit>` when a request names the model
#    and the card has room; a boot-resident engine would pin VRAM for a model
#    nothing asked for.
#  - Lifecycle mode: the engine's loopback port is private plumbing the gate
#    forwards to (--child-port). A front socket or relay for one engine would
#    bypass the gate's load/redirect decision.
#  - <activityDir>/<unit> is the keep-alive contract: the gate stamps it on
#    every request, and the wrapper exits 0 once it ages past --idle-seconds.
#    That exit is what releases the model's VRAM.
#  - Restart = on-abnormal: the wrapper exits 0 on every normal path (idle
#    unload, SIGTERM, child failure), so only a wrapper crash — a signal or
#    coredump — restarts.
{ lib, pkgs, catalog }:

let
  idleWrapper = pkgs.callPackage ./idle-wrapper { };
in
{ unit
, wrapper
, childPort
, childCommand
, idleSeconds
, readyTimeoutSeconds
, shutdownTimeoutSeconds
, killTimeoutSeconds
, description
, requires ? [ ]
, after ? [ ]
, path ? [ ]
, environment ? [ ]
, extraServiceConfig ? { }
}:
{
  inherit description requires after path;

  serviceConfig = {
    Type = "simple";

    ExecStart = lib.concatStringsSep " " (
      [
        "${pkgs.python3}/bin/python3"
        "${idleWrapper}/${wrapper}"
        "--child-port"
        (toString childPort)
        "--idle-seconds"
        (toString idleSeconds)
        "--ready-timeout"
        (toString readyTimeoutSeconds)
        "--shutdown-timeout"
        (toString shutdownTimeoutSeconds)
        "--kill-timeout"
        (toString killTimeoutSeconds)
      ]
      ++ [
        "--lifecycle-only"
        "--activity-file"
        "${catalog.gate.activityDir}/${unit}"
        "--"
      ]
      ++ childCommand
    );

    Restart = "on-abnormal";
    RestartSec = "3";
    Environment = environment;
  } // extraServiceConfig;
}
