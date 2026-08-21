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
  # Formatted strings for template substitution
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

    # Model directory from hosts/desktop/llamacpp.nix (single source of truth)
    modelsDir = "/var/lib/llama/models";

    # Konsole scrollback is set in dotfiles/konsole/OLED.profile
    konsoleScrollback = "500000";

    # Read-only mounts for user jails (system jails get extra mounts).
    # Deliberately excludes secretMounts: the agenix secret path is rendered
    # separately via {{secretMounts}} so it can be kept out of this list.
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

    # Tool contracts (unchanged)
    headroomNote = "Compression is lossy for repeated tokens; keep hash for retrieval";
  };

  # Keep original sections for compatibility
  tools.headroom.compress = "headroom_compress(content) → compressed + hash + token metrics";
  tools.headroom.retrieve = "headroom_retrieve(hash, query?) → original";
  tools.headroom.stats = "headroom_stats";
  tools.edit.success = "silent";
  tools.edit.requires = "exact match including whitespace";
  tools.edit.verify = "view or git diff";
}
