# Jailed LLM tooling (crush/opencode/aider) home-manager module for b: the
# jail packages + wrappers, the headroom proxy user services, and the shared
# agent-home config (./jail-home.nix). The llm agent user's home (system
# jails) gets the same shared config via ./agent-home.nix.
#
# The shared model/LSP catalog lives in ./catalog.nix (single source of
# truth, also used by the doc build).
{ config, lib, pkgs, jail-nix, llm-agents, deepseekSecret, shared, ... }:

let
  userHome = config.home.homeDirectory;

  jail-config = import ./jails.nix {
    inherit lib pkgs jail-nix llm-agents deepseekSecret shared userHome;
  };
  services = import ./services.nix {
    inherit lib pkgs shared;
    headroomDeepseekWrapper = jail-config.headroomDeepseekWrapper;
  };
in
{
  imports = [ ./jail-home.nix ];

  home.packages = jail-config.jails ++ [ jail-config.jc jail-config.jcs jail-config.dsh jail-config.dshs ];

  systemd.user.services = services.systemd.user.services;
}