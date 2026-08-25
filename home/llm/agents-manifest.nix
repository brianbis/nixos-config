{ lib, pkgs, shared, jail-nix, llm-agents, userHome }:

let
  # Import jail config with a dummy deepseek secret; we only need the pure
  # helpers for rendering the doc. The real jails use the same values, so the
  # doc stays in sync with the actual mounts / denied commands.
  jailCfg = import ./jails.nix {
    inherit lib pkgs jail-nix llm-agents shared userHome;
    deepseekSecret = "";
  };

  forbiddenNixCmds = jailCfg.forbiddenNixCmds;
  baseMounts = jailCfg.baseMounts;
in
{
  formatted = {
    # Ports are canonical in catalog.nix
    headroomLocalPort = toString shared.headroomPort;
    headroomCloudPort = toString shared.headroomCloudPort;
    headroomClaudePort = toString shared.headroomClaudePort;
    headroomLocalUrl = "http://127.0.0.1:${toString shared.headroomPort}/health";

    # System paths from catalog
    agentHome = shared.agentHome;
    agentUsername = shared.agentUsername;

    # User home directory (same value the real jails use, passed in by the caller)
    userHome = userHome;

    # Must match modelsDir in hosts/desktop/llamacpp.nix.
    modelsDir = "/var/lib/llama/models";

    # Must match ScrollbackLines in dotfiles/konsole/OLED.profile.
    konsoleScrollback = "500000";

    # Read-only mounts for user jails (system jails get extra mounts).
    # Deliberately excludes secretMounts so the agenix secret path stays out
    # of the generated doc.
    readonlyMountsUser = lib.concatStringsSep ", " (map (p: "`${p}`") (baseMounts false));
    readonlyMountsSystem = lib.concatStringsSep ", " (map (p: "`${p}`") (baseMounts true));

    # Writable paths for system jails, from the same list that builds the
    # actual jails. User jails get $PWD at runtime (mount-cwd), which is not
    # a static path and so stays a literal in the template.
    writablePathsSystem = lib.concatStringsSep ", " (map (p: "`${p}`") jailCfg.writablePathsSystem);

    # Common packages, unversioned (doc names from jails.nix commonPkgSpecs)
    # for stable diffs. Single source of truth: edit jails.nix only.
    commonPackages = lib.concatStringsSep ", " jailCfg.commonPkgNames;

    # Denied commands from the single source of truth in jails.nix
    deniedCommands = lib.concatStringsSep ", " (map (c: "`${c}`") (builtins.attrNames forbiddenNixCmds));
  };
}
