# Builds the (user, system) jail pair for each jailed agent (crush, opencode,
# aider, claude). This is the sandboxing layer: it wires bubblewrap mounts, injected
# packages, HOME pinning and the shared LSP set from the catalog.
{ lib, pkgs, jail-nix, llm-agents, deepseekSecret, shared, userHome }:

let
  inherit (shared)
    headroomCloudUpstreamUrl
    headroomCloudPort
    lspAdds
    systemStateDir
    ;

  jail = jail-nix.lib.init pkgs;

  # Headroom context-compression proxy for DeepSeek (cloud). Reads the API key
  # from the agenix secret at runtime.
  headroomDeepseekWrapper = pkgs.writeShellScriptBin "headroom-deepseek" ''
    KEY="''$(cat ${deepseekSecret} | tr -d '\n')"
    HEADER="{\"Authorization\":\"Bearer $KEY\"}"
    exec ${pkgs.headroom}/bin/headroom proxy \
      --openai-api-url ${headroomCloudUpstreamUrl} \
      --openai-extra-headers "$HEADER" \
      --host 127.0.0.1 --port ${toString headroomCloudPort}
  '';

  withDeepSeekKey = pkg: name:
    pkgs.writeShellScriptBin name ''
      export DEEPSEEK_API_KEY="$(cat /run/agenix/deepseek-api-key)"
      export OPENAI_API_KEY="$DEEPSEEK_API_KEY"
      exec ${pkg}/bin/${name} "$@"
    '';

  # Shadow the system-activating nix CLIs inside the jail with stubs that
  # refuse to run. This is deterministic (no command-string parsing, no
  # regex, robust against quoting / `sudo` / `env` prefixes): the real
  # binaries are simply absent, so the agent can edit /etc/nixos but can
  # never switch/build/install a system configuration. Each stub prints a
  # plain message and exits non-zero.
  forbiddenNixCmds = {
    "nixos-rebuild" = "building or switching a NixOS system is not allowed inside a jailed agent";
    "nixos-install" = "installing a NixOS system is not allowed inside a jailed agent";
    "home-manager" = "home-manager is not allowed inside a jailed agent";
    "nix-env" = "nix-env profile mutation is not allowed inside a jailed agent";
    "nix-channel" = "nix-channel operations are not allowed inside a jailed agent";
  };
  nixGuard = pkgs.symlinkJoin {
    name = "nix-guard";
    paths = lib.mapAttrsToList (name: msg:
      pkgs.writeShellScriptBin name ''
        echo "denied: ${msg}. Edit config files only; do not activate." >&2
        exit 1
      ''
    ) forbiddenNixCmds;
  };

  commonPkgs = with pkgs; [
    bashInteractive
    curl
    wget
    jq
    git
    which
    ripgrep
    gnugrep
    gnused
    gawkInteractive
    ps
    findutils
    gzip
    unzip
    gnutar
    diffutils
    strace
    openssl
    cfr
    tcpdump
    mitmproxy
    jdk21

    # rtk: Rust Token Killer, compresses noisy command output before it hits
    # the context window, usable by any jailed agent (in nixpkgs).
    rtk
    # headroom: context optimization layer that compresses everything an agent
    # reads. Not in nixpkgs / llm-agents; built from ./packages/headroom.nix.
    headroom

    # Nix CLI so jailed agents can search nixpkgs (`nix search nixpkgs <term>`)
    # and eval packages against the source mounted read-only below.
    nix

    # Shadow system-activating nix CLIs (nixos-rebuild, home-manager, nix-env,
    # nix-channel, nixos-install) with stubs that refuse to run.
    nixGuard

    # Database CLI clients shared by every jailed tool.
    sqlite
    postgresql
    mariadb.client

    (python3.withPackages (ps: [
      ps.cryptography
      ps.dnslib
      ps.requests
    ]))
  ];

  # Base jail options: user (cwd, no /etc/nixos) vs system (/etc/nixos rw).
  # The shared LSP set (host-installed copies, from the `lsps` catalog) is
  # mounted here, once per jail, so we don't bundle a fresh per-tool closure.
  baseJailOptions = system: with jail.combinators; [
    network
    time-zone
    no-new-session
    # Pin HOME to the user's real home (not the invoking shell's $HOME, which
    # sudo would reset to /root). This keeps fwd-env HOME and all the ~/ bind
    # mounts below in agreement no matter how the jail is launched.
    (set-env "HOME" (if system then systemStateDir else userHome))
  ] ++ (if system
    then [ (readwrite "/etc/nixos") (readwrite systemStateDir) ]
    else [ mount-cwd ]) ++ [
    # Mount the pinned nixpkgs source read-only so `nix search nixpkgs <term>`
    # (which resolves nixpkgs via the default channels registry) and direct
    # grepping of the source in $NIXPKGS both work. Enabling the flakes +
    # nix-command experimental features is what makes `nix search` usable.
    (readonly pkgs.path)
    (set-env "NIX_CONFIG"
      "experimental-features = nix-command flakes")
    (set-env "NIXPKGS" pkgs.path)
  ] ++ [ (readonly "/run/agenix/deepseek-api-key") ] ++ lspAdds;

  # Common libs/CLI tools injected into every jail.
  mkToolJail = { name, pkg, dirs, system }:
    jail "jailed-${name}${if system then "-system" else ""}"
      pkg
      (with jail.combinators;
        baseJailOptions system ++
        dirs ++
        [ (add-pkg-deps commonPkgs) ]);

  # Per-tool read/write dirs. Paths are absolute under userHome because
  # us-and-sudo must see identical mounts; a runtime ~ would diverge (sudo
  # resets $HOME to /root).
  mkDirs = paths: map (with jail.combinators; p: readwrite p) paths;
  aiderDirs = mkDirs [
    "${userHome}/.config/aider"
    "${userHome}/.aider.conf.yml"
    "${userHome}/.gitconfig"
  ];
  crushDirs = mkDirs [
    "${userHome}/.config/crush"
    "${userHome}/.local/share/crush"
  ];
  opencodeDirs = mkDirs [
    "${userHome}/.config/opencode"
    "${userHome}/.local/share/opencode"
    "${userHome}/.local/state/opencode"
  ];
  claudeDirs = mkDirs [
    "${userHome}/.claude"
    "${userHome}/.claude.json"
  ];

  # System (root-run) variants keep their writable state under systemStateDir
  # instead of the user's home, because bwrap-as-root cannot traverse the
  # user's 700 home dirs to bind-mount them here. The config/data under
  # systemStateDir are seeded root-only by the NixOS host module
  # (hosts/desktop/crush-system.nix).
  systemCrushDirs = mkDirs [
    "${systemStateDir}/.config"
    "${systemStateDir}/.local/share"
  ];

  # Claude Code system variant: HOME is pinned to systemStateDir, so its
  # config dir and project-state file resolve to this root-owned tree,
  # seeded by the host module (hosts/desktop/crush-system.nix).
  systemClaudeDirs = mkDirs [
    "${systemStateDir}/.claude"
    "${systemStateDir}/.claude.json"
  ];

  agent = n: llm-agents.packages.${pkgs.system}.${n};

  # Jailed crush is already sandboxed by bubblewrap, so strip the hardcoded
  # network/download + network-config command bans from bash.go. The jail is
  # the real security boundary; the blocklist is redundant here and blocks
  # legitimate local work (curl health checks, service probes, etc.).
  crushUnbanned = (agent "crush").overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i \
        -e '/"alias",/d' -e '/"aria2c",/d' -e '/"axel",/d' -e '/"chrome",/d' \
        -e '/"curl",/d' -e '/"curlie",/d' -e '/"firefox",/d' \
        -e '/"http-prompt",/d' -e '/"httpie",/d' -e '/"links",/d' \
        -e '/"lynx",/d' -e '/"nc",/d' -e '/"safari",/d' -e '/"scp",/d' \
        -e '/"ssh",/d' -e '/"telnet",/d' -e '/"w3m",/d' -e '/"wget",/d' \
        -e '/"xh",/d' -e '/"firewall-cmd",/d' -e '/"ifconfig",/d' \
        -e '/"ip",/d' -e '/"iptables",/d' -e '/"netstat",/d' \
        -e '/"pfctl",/d' -e '/"route",/d' -e '/"ufw",/d' \
        internal/agent/tools/bash.go
      # Hardcoded in the system prompt template (tool_usage), separate from the
      # bash.go blocklist. Remove the stale "never use curl in bash" instruction
      # too, since the jail is the real boundary and we allow curl.
      sed -i \
        -e '/Never use `curl` through the bash tool/d' \
        internal/agent/templates/coder.md.tpl
    '';
  });

  # Build a (user, system) jail pair for a tool.
  # tool = { name, pkg, dirs, systemDirs ? [ ] }
  # When systemDirs is given it replaces the user's home dirs (so bwrap-as-root
  # never has to traverse $HOME, which is 700); otherwise the system variant
  # reuses the same dirs as the user variant.
  makeTool = { name, pkg, dirs, systemDirs ? [ ] }:
    [
      (mkToolJail { inherit name pkg dirs; system = false; })
      (mkToolJail { inherit name pkg; dirs = if systemDirs == [ ] then dirs else systemDirs; system = true; })
    ];

  jails =
    makeTool { name = "aider"; pkg = pkgs.aider-chat; dirs = aiderDirs;
               systemDirs = [ (with jail.combinators; (readonly deepseekSecret)) ]; }
    ++ makeTool {
         name = "crush";
         pkg = withDeepSeekKey crushUnbanned "crush";
         dirs = crushDirs;
         systemDirs = systemCrushDirs;
       }
    ++ makeTool { name = "opencode"; pkg = withDeepSeekKey (agent "opencode") "opencode"; dirs = opencodeDirs; }
    # NOTE: claude-code bundles its own bubblewrap bash sandbox (the
    # llm-agents package adds bwrap+socat to PATH). Nested bwrap can fail
    # inside our jail; if Claude's sandbox errors, disable it via settings.
    ++ makeTool {
         name = "claude";
         pkg = agent "claude-code";
         dirs = claudeDirs;
         systemDirs = systemClaudeDirs;
       };

in
{
  inherit jails headroomDeepseekWrapper;
}
