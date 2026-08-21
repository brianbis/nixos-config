{ pkgs, lib, jail-nix, llm-agents, shared, userHome }:

let
  manifest = import ../agents-manifest.nix {
    inherit lib pkgs shared jail-nix llm-agents userHome;
  };
  template = builtins.readFile ./agents-md-template.md;
  replacements = {
    "{{commonPackages}}" = manifest.formatted.commonPackages;
    "{{deniedCommands}}" = manifest.formatted.deniedCommands;
    "{{headroomLocalPort}}" = manifest.formatted.headroomLocalPort;
    "{{headroomCloudPort}}" = manifest.formatted.headroomCloudPort;
    "{{headroomClaudePort}}" = manifest.formatted.headroomClaudePort;
    "{{headroomLocalUrl}}" = manifest.formatted.headroomLocalUrl;
    "{{systemStateDir}}" = manifest.formatted.systemStateDir;
    "{{userHome}}" = manifest.formatted.userHome;
    "{{modelsDir}}" = manifest.formatted.modelsDir;
    "{{konsoleScrollback}}" = manifest.formatted.konsoleScrollback;
    "{{readonlyMountsUser}}" = manifest.formatted.readonlyMountsUser;
    "{{readonlyMountsSystem}}" = manifest.formatted.readonlyMountsSystem;
    "{{writablePathsSystem}}" = manifest.formatted.writablePathsSystem;
  };
  result = lib.replaceStrings (builtins.attrNames replacements) (builtins.attrValues replacements) template;
  # Fail loudly if any {{placeholder}} survived substitution, so a missing
  # manifest key can never silently leak into the generated doc. Detected by
  # checking whether removing "{{" changes the string length.
  hasLeftoverPlaceholder = builtins.stringLength (lib.replaceStrings [ "{{" ] [ "" ] result) != builtins.stringLength result;
in
pkgs.writeText "AGENTS.md" (
  assert ! hasLeftoverPlaceholder;
  result
)
