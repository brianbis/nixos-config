# Jailed LLM tooling (crush/opencode/aider/claude/dsh) home-manager module for
# b: the jail packages + wrappers, the headroom proxy user services, and the
# shared agent-home config (./jail-home.nix).
#
# The shared model/LSP catalog lives in ./catalog.nix (single source of
# truth, also used by the doc build).
{ config, lib, pkgs, inputs, jail-nix, llm-agents, deepseekSecret, shared, ... }:

let
  userHome = config.home.homeDirectory;

  jail-config = import ./jails.nix {
    inherit lib pkgs jail-nix llm-agents deepseekSecret shared userHome;
    # Upstream dsh source (flakeless flake input); dsh is built from it.
    dshSrc = inputs.dsh;
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
