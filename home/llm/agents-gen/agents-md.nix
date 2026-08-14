{ pkgs, lib, jail-nix, llm-agents }:

let
  manifest = import ../agents-manifest.nix {
    inherit lib pkgs jail-nix llm-agents;
  };
  template = builtins.readFile ./agents-md-template.md;
  replacements = {
    "{{commonPackages}}" = manifest.formatted.commonPackages;
    "{{deniedCommands}}" = manifest.formatted.deniedCommands;
  };
in
pkgs.writeText "agents.md" (lib.replaceStrings (builtins.attrNames replacements) (builtins.attrValues replacements) template)
