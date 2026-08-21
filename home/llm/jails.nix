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

  # Single source of truth for the packages injected into every jail.
  # Each spec carries a stable doc name (what AGENTS.md renders) and a
  # resolver to the actual derivation, so the doc generator can list names
  # without evaluating any package (no overlay required at doc-build time).
  commonPkgSpecs = [
    { name = "bashInteractive"; pkg = pkgs.bashInteractive; }
    { name = "curl"; pkg = pkgs.curl; }
    { name = "wget"; pkg = pkgs.wget; }
    { name = "jq"; pkg = pkgs.jq; }
    { name = "git"; pkg = pkgs.git; }
    { name = "which"; pkg = pkgs.which; }
    { name = "ripgrep"; pkg = pkgs.ripgrep; }
    { name = "gnugrep"; pkg = pkgs.gnugrep; }
    { name = "gnused"; pkg = pkgs.gnused; }
    { name = "gawkInteractive"; pkg = pkgs.gawkInteractive; }
    { name = "ps"; pkg = pkgs.ps; }
    { name = "findutils"; pkg = pkgs.findutils; }
    { name = "gzip"; pkg = pkgs.gzip; }
    { name = "unzip"; pkg = pkgs.unzip; }
    # Read-only host journal access for system jails: unit states, linger
    # activation, core-pin guard warnings. The binary is present in all
    # jails but only works in system jails (user jails lack /run/systemd).
    { name = "systemd"; pkg = pkgs.systemd; }
    { name = "gnutar"; pkg = pkgs.gnutar; }
    { name = "diffutils"; pkg = pkgs.diffutils; }
    { name = "strace"; pkg = pkgs.strace; }
    { name = "openssl"; pkg = pkgs.openssl; }
    { name = "cfr"; pkg = pkgs.cfr; }
    { name = "tcpdump"; pkg = pkgs.tcpdump; }
    { name = "mitmproxy"; pkg = pkgs.mitmproxy; }
    { name = "jdk21"; pkg = pkgs.jdk21; }

    # rtk: Rust Token Killer, compresses noisy command output before it hits
    # the context window, usable by any jailed agent (in nixpkgs).
    { name = "rtk"; pkg = pkgs.rtk; }
    # headroom: context optimization layer that compresses everything an agent
    # reads. Not in nixpkgs / llm-agents; built from ./home/llm/headroom.nix.
    { name = "headroom"; pkg = pkgs.headroom; }

    # Nix CLI so jailed agents can search nixpkgs (`nix search nixpkgs <term>`)
    # and eval packages against the source mounted read-only below.
    { name = "nix"; pkg = pkgs.nix; }

    # Shadow system-activating nix CLIs (nixos-rebuild, home-manager, nix-env,
    # nix-channel, nixos-install) with stubs that refuse to run.
    { name = "nixGuard"; pkg = nixGuard; }

    # Database CLI clients shared by every jailed tool.
    { name = "sqlite"; pkg = pkgs.sqlite; }
    { name = "postgresql"; pkg = pkgs.postgresql; }
    { name = "mariadb.client"; pkg = pkgs.mariadb.client; }

    {
      name = "python3";
      pkg = pkgs.python3.withPackages (ps: [
        ps.cryptography
        ps.dnslib
        ps.requests
      ]);
    }
  ];

  commonPkgs = map (spec: spec.pkg) commonPkgSpecs;
  commonPkgNames = map (spec: spec.name) commonPkgSpecs;

  # Base jail options: user (cwd, no /etc/nixos) vs system (/etc/nixos rw).
  # The shared LSP set (host-installed copies, from the `lsps` catalog) is
  # mounted here, once per jail, so we don't bundle a fresh per-tool closure.
  #
  # baseJailOptions is split into a pure mount-list builder (baseMounts) and
  # the option-combinator wrapper so agents-manifest.nix can render the
  # readonly mounts into AGENTS.md without needing jail-nix at all.
  #
  # The nixpkgs source mount is the flake's own checkout (/etc/nixos), not
  # pkgs.path: the agent edits this repo, so it needs the working tree
  # mounted read-only to search / eval against it. pkgs.path would point at
  # the pinned nixpkgs input instead, which is not what the agent edits.
  #
  # Read-only host mounts are kept in two lists:
  # - baseMounts: non-sensitive paths rendered verbatim into AGENTS.md.
  # - secretMounts: sensitive paths (agenix secrets) that must NOT be named
  #   in the generated doc; they are attached by the justfile after the
  #   declarative build step.
  baseMounts = system: (lib.optional (!system) "/etc/nixos") ++ [ "/var/log" ]
    ++ (if system then [ "/var/log/journal" "/run/systemd" ] else [ ])
    ++ (if system then [ "/sys" "/run/user" ] else [ ]);

  # agenix secret file(s) mounted read-only into every jail. Kept out of
  # baseMounts on purpose: naming the secret path in AGENTS.md would leak
  # the secret name into the doc. Rendered separately by the justfile.
  secretMounts = [ deepseekSecret ];

  # Full read-only mount list used by the actual jails.
  readonlyMounts = system: baseMounts system ++ secretMounts;

  # Writable paths beyond the read-only overlay. System jails get the repo
  # and their state dir read-write; user jails get $PWD via mount-cwd (a
  # runtime path, not statically knowable) plus per-tool dirs (see mkDirs).
  writablePathsSystem = [ "/etc/nixos" systemStateDir ];

  baseJailOptions = system: with jail.combinators; [
    network
    time-zone
    no-new-session
    (set-env "HOME" (if system then systemStateDir else userHome))
  ] ++ (if system
    then map readwrite writablePathsSystem
    else [ mount-cwd ]) ++ map readonly (readonlyMounts system) ++ [
    (set-env "NIX_CONFIG"
      "experimental-features = nix-command flakes")
    (set-env "NIXPKGS" pkgs.path)
  ] ++ lspAdds;

  # Common libs/CLI tools injected into every jail.
  mkToolJail = { name, pkg, dirs, system, systemExtraPkgs ? [ ], systemExtraMounts ? [ ] }:
    jail "jailed-${name}${if system then "-system" else ""}"
      pkg
      (with jail.combinators;
        baseJailOptions system ++
        dirs ++
        [ (add-pkg-deps (commonPkgs ++ (if system then systemExtraPkgs else [ ]))) ]
        ++ (if system then systemExtraMounts else [ ]));

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

  agent = n: llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.${n};

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
        -e '/"systemctl",/d' \
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
  # tool = { name, pkg, dirs, systemDirs ? [ ], systemExtraPkgs ? [ ], systemExtraMounts ? [ ] }
  # systemExtra* apply only to the root-run system variant.
  # When systemDirs is given it replaces the user's home dirs (so bwrap-as-root
  # never has to traverse $HOME, which is 700); otherwise the system variant
  # reuses the same dirs as the user variant.
  makeTool = { name, pkg, dirs, systemDirs ? [ ], systemExtraPkgs ? [ ], systemExtraMounts ? [ ] }:
    let
      userJail = mkToolJail { inherit name pkg dirs; system = false; };
      systemJail = mkToolJail { inherit name pkg systemExtraPkgs systemExtraMounts; dirs = if systemDirs == [ ] then dirs else systemDirs; system = true; };
    in {
      "${name}-jail" = userJail;
      "${name}-jail-system" = systemJail;
    };

  jailsByTool =
    (makeTool { name = "aider"; pkg = pkgs.aider-chat; dirs = aiderDirs;
                systemDirs = [ (with jail.combinators; (readonly deepseekSecret)) ]; })
    // (makeTool {
         name = "crush";
         pkg = withDeepSeekKey crushUnbanned "crush";
         dirs = crushDirs;
         systemDirs = systemCrushDirs;
         # Debug tooling for the system jail: pgrep/pidof, the PipeWire and
         # WirePlumber CLIs (pw-top, pw-dump, wpctl) for inspecting audio
         # stream state, plus read-only /sys (cpufreq governor) and /run/user
         # (session PipeWire socket, reachable as root).
         systemExtraPkgs = with pkgs; [ procps pipewire wireplumber ];
         systemExtraMounts = with jail.combinators; [
           (readonly "/sys")
           (readonly "/run/user")
         ];
       })
    // (makeTool { name = "opencode"; pkg = withDeepSeekKey (agent "opencode") "opencode"; dirs = opencodeDirs; })
    // (makeTool {
         name = "claude";
         pkg = agent "claude-code";
         dirs = claudeDirs;
         systemDirs = systemClaudeDirs;
       });

  # Flat list of all jail packages (home.packages expects a list).
  jails = builtins.attrValues jailsByTool;

  # Short aliases for the crush jail pair: `jc` (user) and `jcs` (system,
  # run via sudo so it can read/write /etc/nixos). Wrappers exec the actual
  # jail binaries from `jailsByTool`, so they always track the real packages.
  jc = pkgs.writeShellScriptBin "jc" ''
    exec ${jailsByTool."crush-jail"}/bin/jailed-crush "$@"
  '';
  jcs = pkgs.writeShellScriptBin "jcs" ''
    exec sudo ${jailsByTool."crush-jail-system"}/bin/jailed-crush-system "$@"
  '';

  in
{
  inherit
    jails
    headroomDeepseekWrapper
    commonPkgs
    commonPkgNames
    jc
    jcs
    forbiddenNixCmds
    baseMounts
    secretMounts
    writablePathsSystem
    ;
}
