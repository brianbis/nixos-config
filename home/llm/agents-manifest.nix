{ lib, pkgs, jail-nix, llm-agents, ... }:

let
  # Import jail config to extract common packages and mounts, only if jail-nix is available
  jailCfgTry = if jail-nix != null then builtins.tryEval (import ./jails.nix {
    inherit lib pkgs jail-nix llm-agents;
    deepseekSecret = null;
    shared = { rtkRewriteHook = ""; };
    userHome = "/home/b";
  }) else { success = true; value = { commonPkgs = []; }; };
  jailCfg = if jailCfgTry.success then jailCfgTry.value else { commonPkgs = []; };
in
rec {
  # System model
  headroomPortsCfg = {
    local = 8787;
    cloud = 8788;
    claude = 8789;
  };

  # Jail contract
  jail = {
    commonPackages = jailCfg.commonPkgs or [];
    writablePaths = {
      user = [
        "~/.config/crush"
        "~/.local/share/crush"
        "~/.config/opencode"
        "~/.local/share/opencode"
        "~/.claude"
      ];
      system = [
        "/var/lib/crush-system/.config"
        "/var/lib/crush-system/.local/share"
      ];
    };
    deniedCommands = [ "nixos-rebuild" "nixos-install" "home-manager" "nix-env" "nix-channel" ];
  };

  # Tool contracts
  tools = {
    headroom = {
      compress = "headroom_compress(content) → compressed + hash + token metrics";
      retrieve = "headroom_retrieve(hash, query?) → original";
      stats = "headroom_stats";
      note = "Compression is lossy for repeated tokens; keep hash for retrieval";
    };
    edit = {
      success = "silent";
      requires = "exact match including whitespace";
      verify = "view or git diff";
    };
  };

  # Asset policy
  assetPolicy = "Prefer raw files in dotfiles/ referenced via mkOutOfStoreSymlink. Nix stays declarative.";

  # Formatted strings for template substitution
  formatted = {
    headroomPortsStr = ":${toString headroomPortsCfg.local} local, :${toString headroomPortsCfg.cloud} cloud, :${toString headroomPortsCfg.claude} Claude";
    commonPackages = let
      names = map (p:
        if p ? name then p.name
        else if p ? pname then p.pname
        else "pkg"
      ) jail.commonPackages;
    in lib.concatStringsSep ", " names;
    deniedCommands = lib.concatStringsSep ", " (map (c: "`${c}`") jail.deniedCommands);
  };
}
