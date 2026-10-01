# home-manager module for the `llm` agent user — the home of the "system"
# jail variants, which run as this user via `sudo -u llm`. Tool configs come
# from the shared agent-home module (./jail-home.nix).
#
# No home.packages: the `jc`/`jcs`/`dsh`/`dshs` wrappers live in b's profile
# and the jail provides its own PATH via bwrap. No user services: the headroom
# proxies run in b's session and are reachable from any user over loopback.
{ lib, pkgs, inputs, jail-nix, llm-agents, shared, ... }:

let
  # The agent operating manual, installed as dsh's user-global instruction file
  # ($DSH_HOME/AGENTS.md): dsh-agent-instructions loads the user-global file
  # first, so every dsh session gets it as global context.
  agentsMd = pkgs.callPackage ./agents-gen/agents-md.nix {
    inherit jail-nix llm-agents;
    inherit shared;
    userHome = (import ../users.nix).b.homeDirectory;
    # Upstream dsh source (flakeless input); the doc renders the jail config,
    # which builds dsh from this tree.
    dshSrc = inputs.dsh;
  };
  # Embed the content as one single-quoted shell word so apostrophes in the
  # manual can never break the activation script's quoting.
  shellQuote = s: "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] s + "'";

  # PM Skills Marketplace (phuryn/pm-skills) flattened into dsh skill bundles
  # (see ./pm-skills.nix); materialized into dsh's user skill root below.
  pmSkillsSkills = pkgs.callPackage ./pm-skills.nix {
    src = inputs.pm-skills;
  };
in
{
  imports = [ ./jail-home.nix ];

  home.stateVersion = "26.05";

  # dsh's user-global instruction file ($HOME/.dsh/AGENTS.md). Plain file +
  # cmp-guard write (as in writeDshSettings): a symlink to the store path would
  # dangle inside the jail (it bind-mounts only its runtime closure of /nix/store), so the content must be materialized into the home.
  home.activation.writeDshAgentsMd =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/.dsh

      $DRY_RUN_CMD printf '%s' ${shellQuote (builtins.readFile agentsMd)} \
        > $HOME/.dsh/AGENTS.md.tmp
      if [ -f $HOME/.dsh/AGENTS.md ] \
        && cmp -s $HOME/.dsh/AGENTS.md.tmp $HOME/.dsh/AGENTS.md; then
        $DRY_RUN_CMD rm -f $HOME/.dsh/AGENTS.md.tmp
      else
        $DRY_RUN_CMD mv -f $HOME/.dsh/AGENTS.md.tmp $HOME/.dsh/AGENTS.md
      fi
    '';

  # PM Skills Marketplace (phuryn/pm-skills), flattened into dsh's user skill
  # root ($HOME/.dsh/skills): the dsh-skill-filesystem provider (dsh-base,
  # default roots + watch) scans one level of <name>/SKILL.md bundles and picks
  # the 69 PM skills up without a restart. Same materialization rationale as
  # the manual above (store symlinks dangle inside the jail). The flake owns
  # this directory wholesale — to add non-pm-skills skills, extend
  # ./pm-skills.nix rather than dropping folders by hand (activation rewrites
  # the directory from the store path).
  home.activation.writeDshPmSkills =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD rm -rf $HOME/.dsh/skills
      $DRY_RUN_CMD cp -r ${pmSkillsSkills} $HOME/.dsh/skills
      # cp -r from the store keeps the store's read-only modes (dirs 555, files
      # 444); the next activation's `rm -rf` then fails (no owner-write on the
      # bundle dirs). Make the tree owner-writable so it can be rewritten.
      $DRY_RUN_CMD chmod -R u+w $HOME/.dsh/skills
    '';
}
