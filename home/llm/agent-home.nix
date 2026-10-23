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
  # VulnHunter (capitalone/VulnHunter) security skills flattened into dsh skill
  # bundles (see ./vulnhunter-skills.nix); materialized into the same skill root
  # below, alongside pm-skills.
  vulnhunterSkills = pkgs.callPackage ./vulnhunter-skills.nix {
    src = inputs.vulnhunter;
    version = inputs.vulnhunter.shortRev;
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

  # dsh's user skill root ($HOME/.dsh/skills): the dsh-skill-filesystem provider
  # (dsh-base, default roots + watch) scans one level of <name>/SKILL.md bundles
  # and picks them up without a restart. The flake owns this directory wholesale
  # — it is materialized from the store-built bundle sets (pm-skills plus
  # vulnhunter-skills), so to add skills extend those derivations rather than
  # dropping folders by hand (activation rewrites the directory from the store
  # paths). Same materialization rationale as the manual above (store symlinks
  # dangle inside the jail).
  home.activation.writeDshSkills =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # The previous generation's tree is store-copied (bundle dirs 555, no
      # owner-write), so `rm -rf` cannot recurse into it and aborts the script
      # under set -e. Make any existing tree owner-writable first so the rewrite
      # below can always proceed (no-op when the root is absent).
      $DRY_RUN_CMD chmod -R u+w $HOME/.dsh/skills 2>/dev/null || true
      $DRY_RUN_CMD rm -rf $HOME/.dsh/skills
      # pm-skills first: the store dir is renamed to $HOME/.dsh/skills (it was
      # just removed), so its bundles become the root's contents.
      $DRY_RUN_CMD cp -r ${pmSkillsSkills} $HOME/.dsh/skills
      # cp -r preserved the store's read-only modes (root dir 555, no owner-write),
      # so the merge below cannot create entries inside the root. Make the tree
      # owner-writable now, before the vulnhunter merge.
      $DRY_RUN_CMD chmod -R u+w $HOME/.dsh/skills
      # vulnhunter-skills merged into the same root (its three bundle names -
      # vulnhunt, vulnhunter-fix, vulnhunt-fix-verify - never collide with a
      # pm-skills bundle).
      $DRY_RUN_CMD cp -r ${vulnhunterSkills}/. $HOME/.dsh/skills/
      # cp -r from the store keeps the store's read-only modes (dirs 555, files
      # 444); make the tree owner-writable so the next activation can rewrite it.
      $DRY_RUN_CMD chmod -R u+w $HOME/.dsh/skills
    '';
}
