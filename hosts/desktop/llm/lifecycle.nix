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
