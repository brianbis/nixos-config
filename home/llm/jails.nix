# Builds the (user, system) jail pair for each jailed agent (crush, opencode,
# aider, claude, dsh). System jails run as the llm agent user (via `sudo -u llm`)
# so they can edit /etc/nixos without being root.
{ lib, pkgs, jail-nix, llm-agents, deepseekSecret, shared, userHome, dshSrc }:

let
  inherit (shared)
    headroomCloudUpstreamUrl
    headroomCloudPort
    lspAdds
    agentHome
    agentUsername
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

  # Like withDeepSeekKey but exports a NON-secret placeholder instead of the real
  # key. The real DeepSeek key is injected host-side by the headroom-proxy-deepseek
  # service (port 8788, which runs OUTSIDE the jail) via --openai-extra-headers, so
  # dsh only needs *a* credential: pi-ai's openai-completions insists on one even
  # for local endpoints (see catalog.nix dshSettings). Exporting the placeholder
  # (not the real key) keeps the key out of dsh's environ (/proc/2/environ) and out
  # of any bwrap --setenv argv (/proc/1/cmdline), both of which the same-uid agent
  # can read. The placeholder is a non-secret constant, so baking it into the store
  # is harmless.
  withDummyKey = pkg: name:
    pkgs.writeShellScriptBin name ''
      export DEEPSEEK_API_KEY="managed-by-headroom-proxy-8788"
      export OPENAI_API_KEY="$DEEPSEEK_API_KEY"
      exec ${pkg}/bin/${name} "$@"
    '';

  # Empty file used to shadow the agenix secret in the dsh system jail (see the
  # dsh entry in jailsByTool): bound over /run/agenix/deepseek-api-key so the
  # same-uid agent cannot read the real key from the path baseJailOptions ro-binds.
  # Pinned into the jail closure via add-pkg-deps (systemExtraPkgs) so a
  # nix-collect-garbage cannot orphan the store path bwrap binds.
  emptySecretFile = pkgs.writeText "empty-secret" "";

  # Shadow only the system-mutating/activating CLIs with stubs that refuse to run,
  # rather than parsing command strings: deterministic and robust against quoting /
  # `sudo` / `env` prefixes. The `nix` CLI remains available for evaluation, flake
  # checks, and builds; the agent can edit /etc/nixos but never activate.
  forbiddenNixCmds = {
    "nixos-rebuild" = "building or switching a NixOS system is not allowed inside a jailed agent";
    "nixos-install" = "installing a NixOS system is not allowed inside a jailed agent";
    "home-manager" = "home-manager is not allowed inside a jailed agent";
    "nix-env" = "nix-env profile mutation is not allowed inside a jailed agent";
    "nix-channel" = "nix-channel operations are not allowed inside a jailed agent";
  };
  nixGuard = pkgs.symlinkJoin {
    name = "nix-guard";
    paths = lib.mapAttrsToList
      (name: msg:
        pkgs.writeShellScriptBin name ''
          echo "denied: ${msg}. Edit config files only; do not activate." >&2
          exit 1
        ''
      )
      forbiddenNixCmds;
  };

  # Single source of truth for packages injected into every jail. Each spec
  # carries a stable doc name and a resolver so the doc generator can list
  # names without evaluating any package (no overlay at doc-build time).
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
    # GNU patch: apply/verify source and preset patches in-jail (e.g. re-syncing
    # the dsh standard-preset delta against a fresh dsh).
    { name = "gnupatch"; pkg = pkgs.gnupatch; }
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
    # reads. Not in nixpkgs / llm-agents; built from
    # ./home/llm/tools/headroom.nix.
    { name = "headroom"; pkg = pkgs.headroom; }

    # Nix CLI so jailed agents can search nixpkgs (`nix search nixpkgs <term>`)
    # and eval packages against the source mounted read-only below.
    { name = "nix"; pkg = pkgs.nix; }

    { name = "nixGuard"; pkg = nixGuard; }

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

  # baseMounts is a pure mount-list builder (separate from the baseJailOptions
  # wrapper) so agents-manifest.nix can render the readonly mounts into
  # AGENTS.md without calling into jail-nix.
  # /etc/machine-id (system jails): the jail's /etc is a fresh tmpfs, so the
  # host's machine-id is invisible unless bound in. journalctl resolves the
  # journal dir as /var/log/journal/<machine-id>/ via this file; without it
  # it reports "No journal files were found" even though /var/log/journal is
  # mounted.
  baseMounts = system: (lib.optional (!system) "/etc/nixos") ++ [ "/var/log" ]
    ++ (if system then [ "/var/log/journal" "/run/systemd" "/etc/machine-id" ] else [ ])
    ++ (if system then [ "/sys" "/run/user" ] else [ ]);

  # agenix secret file(s) mounted read-only into every jail. Kept out of
  # baseMounts on purpose: naming the secret path in AGENTS.md would leak
  # the secret name into the doc. Rendered separately by the justfile.
  secretMounts = [ deepseekSecret ];

  readonlyMounts = system: baseMounts system ++ secretMounts;

  # Extra writable paths for system jails (beyond the read-only overlay). User
  # jails' $PWD is a runtime path (not statically knowable), so it's handled
  # via mount-cwd rather than listed here.
  writablePathsSystem = [ "/etc/nixos" agentHome ];

  # The shared LSP set is mounted once per jail (not per tool) so we don't
  # bundle a fresh per-tool closure.
  baseJailOptions = system: with jail.combinators; [
    network
    time-zone
    no-new-session
    (set-env "HOME" (if system then agentHome else userHome))
  ] ++ (if system
  then map readwrite writablePathsSystem
  else [ mount-cwd ]) ++ map readonly (readonlyMounts system) ++ [
    (set-env "NIX_CONFIG"
      "experimental-features = nix-command flakes")
    (set-env "NIXPKGS" pkgs.path)
  ] ++ lspAdds;

  mkToolJail = { name, pkg, dirs, system, systemExtraPkgs ? [ ], systemExtraMounts ? [ ] }:
    jail "jailed-${name}${if system then "-system" else ""}"
      pkg
      (with jail.combinators;
      baseJailOptions system ++
      dirs ++
      [ (add-pkg-deps (commonPkgs ++ (if system then systemExtraPkgs else [ ]))) ]
      ++ (if system then systemExtraMounts else [ ]));

  # Per-tool read/write dirs, relative to the owning home (user: userHome,
  # system: agentHome). Paths are absolute so user and system mounts stay
  # statically identical; a runtime ~ would diverge (sudo resets $HOME).
  mkDirSpecs = base: paths: map (with jail.combinators; p: readwrite "${base}/${p}") paths;
  userDirSpecs = paths: mkDirSpecs userHome paths;
  agentDirSpecs = paths: mkDirSpecs agentHome paths;

  aiderDirPaths = [
    ".config/aider"
    ".aider.conf.yml"
    ".gitconfig"
  ];
  crushDirPaths = [
    ".config/crush"
    ".local/share/crush"
  ];
  opencodeDirPaths = [
    ".config/opencode"
    ".local/share/opencode"
    ".local/state/opencode"
  ];
  claudeDirPaths = [
    ".claude"
    ".claude.json"
  ];
  # dsh (DeepSeek Harness) keeps all user data under a single root (~/.dsh,
  # overridable via $DSH_HOME); the jail pins HOME, so the default root is
  # what gets mounted.
  dshDirPaths = [
    ".dsh"
  ];

  agent = n: llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.${n};

  # Jailed crush is already sandboxed by bubblewrap, so strip the hardcoded
  # network/download + network-config command bans from bash.go: the jail is the
  # real security boundary, and the blocklist blocks legitimate local work.
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

  # The dsh system jail is headless with no real xdg-open, so dsh's host-side
  # opener fails with `spawn xdg-open ENOENT`. This wrapper forwards the path to
  # the dsh-open handler (runs as b) over /run/dsh-open/open.sock instead.
  dshOpenXdgOpen = pkgs.writeShellApplication {
    name = "xdg-open";
    runtimeInputs = [ pkgs.socat pkgs.coreutils ];
    text = ''
      set -u
      SOCK=/run/dsh-open/open.sock
      [ $# -ge 1 ] || { echo "xdg-open: no path argument" >&2; exit 1; }
      path="$1"
      # Open regular files only (a URL is not a regular file — kills the vector).
      [ -f "$path" ] || { echo "xdg-open: not a regular file: $path" >&2; exit 1; }
      # Make the file (and every llm-owned ancestor dir) group-readable+writable
      # so b (in the llm group) can read it and save edits back. This wrapper
      # runs as llm (the owner), so it can chmod its own files — no root needed.
      # Root-owned dirs (/etc, /home, /) are skipped.
      me=$(id -u)
      if [ "$(stat -c %u -- "$path" 2>/dev/null)" = "$me" ]; then
        chgrp -- ${agentUsername} "$path" 2>/dev/null || true
        chmod g+rw -- "$path" 2>/dev/null || true
      fi
      d=$(dirname -- "$path")
      while [ -n "$d" ] && [ "$d" != "/" ]; do
        if [ "$(stat -c %u -- "$d" 2>/dev/null)" = "$me" ]; then
          chgrp -- ${agentUsername} "$d" 2>/dev/null || true
          chmod g+rx -- "$d" 2>/dev/null || true
        fi
        d=$(dirname -- "$d")
      done
      # Forward the path to the dsh-open handler (runs as b) over the agent-only
      # Unix socket. One line in (the path), one line out (the status).
      resp=$(printf '%s\n' "$path" | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null) || {
        echo "xdg-open: dsh-open service unavailable ($SOCK)" >&2; exit 1;
      }
      case "$resp" in
        ok*) exit 0 ;;
        "")  echo "xdg-open: no response from dsh-open handler" >&2; exit 1 ;;
        *)   echo "xdg-open: $resp" >&2; exit 1 ;;
      esac
    '';
  };

  # Patch the shipped `standard` preset at build time: the user preset root
  # can't shadow the shipped one (first-root-wins). writeText makes the patch a
  # derivation input (a bare repo path is invisible to the sandboxed builder).
  #
  # Since dsh 0.1.2 the shipped presets live in the @deepseek-ai/dsh-agent-
  # presets package (resolved at runtime via SHIPPED_PRESET_ROOT), not in the
  # CLI tarball's config/ dir. The preset is patched in place inside
  # node_modules so the discovery root picks up the patched composition.
  #
  # dsh is built from source (the flakeless `dsh` input, pinned in flake.nix):
  # dsh-source.nix replicates the upstream release pipeline to produce the
  # @deepseek-ai/dsh npm tarball, and dsh-package.nix runs the usual
  # buildNpmPackage recipe on it. This replaces `agent "dsh"` from the
  # llm-agents flake input, which pins the npm `latest` dist-tag (0.1.1-rc.2).
  # The version follows the pinned tree's root package.json, so
  # `nix flake update dsh` re-pins both commit and version together.
  dshVersion =
    (builtins.fromJSON (builtins.readFile (dshSrc + "/package.json"))).version;

  dshTarball = (import ./dsh-source.nix) {
    inherit pkgs;
    src = dshSrc;
    commit = dshSrc.rev;
    version = dshVersion;
  };

  dshPatched = (pkgs.callPackage ./dsh-package.nix {
    versionCheckHomeHook = agent "versionCheckHomeHook";
    src = dshTarball;
    version = dshVersion;
  }).overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.gnupatch ];
    postInstall = (old.postInstall or "") + ''
      patch -p1 -d $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-agent-presets/presets/standard \
        < ${pkgs.writeText "dsh-standard-preset.patch" (builtins.readFile ../../dotfiles/dsh/standard-preset.patch)}
    '';
  });

  # Build a (user, system) jail pair for a tool. systemExtra* apply only to the
  # system variant; systemDirs replaces the default agent-home dirs when a system
  # variant needs a different mount set (e.g. aider: secret read-only, no dirs).
  makeTool = { name, pkg, dirPaths, systemDirs ? (agentDirSpecs dirPaths), systemExtraPkgs ? [ ], systemExtraMounts ? [ ] }:
    let
      userJail = mkToolJail { inherit name pkg; dirs = userDirSpecs dirPaths; system = false; };
      systemJail = mkToolJail { inherit name pkg systemExtraPkgs systemExtraMounts; dirs = systemDirs; system = true; };
    in
    {
      "${name}-jail" = userJail;
      "${name}-jail-system" = systemJail;
    };

  jailsByTool =
    (makeTool {
      name = "aider";
      pkg = pkgs.aider-chat;
      dirPaths = aiderDirPaths;
      systemDirs = [ (with jail.combinators; (readonly deepseekSecret)) ];
    })
    // (makeTool {
      name = "crush";
      pkg = withDeepSeekKey crushUnbanned "crush";
      dirPaths = crushDirPaths;
      # Debug tooling for the system jail: PipeWire/WirePlumber CLIs for audio
      # stream state, plus read-only /sys (cpufreq) and /run/user (session
      # sockets). b's /run/user session dir is mode 700, so llm can't inspect it.
      systemExtraPkgs = with pkgs; [ procps pipewire wireplumber ];
      systemExtraMounts = with jail.combinators; [
        (readonly "/sys")
        (readonly "/run/user")
      ];
    })
    // (makeTool { name = "opencode"; pkg = withDeepSeekKey (agent "opencode") "opencode"; dirPaths = opencodeDirPaths; })
    // (makeTool { name = "claude"; pkg = agent "claude-code"; dirPaths = claudeDirPaths; })
    // (makeTool {
      name = "dsh";
      # Dummy key: the real DeepSeek key is injected host-side by the
      # headroom-proxy-deepseek service (8788, outside the jail); see withDummyKey.
      pkg = withDummyKey dshPatched "dsh";
      dirPaths = dshDirPaths;
      # The jail's /run is a fresh tmpfs, so the dsh-open socket must be
      # bind-mounted in. Mount the DIRECTORY (not the socket) so a switch
      # that recreates it leaves no stale inode (ENXIO); rw for socket connect.
      # openssh client: the dsh agent reaches LAN hosts (e.g. the user's Home
      # Assistant server) to explore device cloud Api / MQTT from the owner
      # account. The jail already allows network; this only adds the binaries.
      systemExtraPkgs = [ dshOpenXdgOpen emptySecretFile pkgs.openssh ];
      systemExtraMounts = with jail.combinators; [
        (readwrite "/run/dsh-open")
        # Shadow the agenix secret that baseJailOptions ro-binds into every jail:
        # bind the empty store file over it so the same-uid agent cannot read the
        # real key from /run/agenix/deepseek-api-key. systemExtraMounts is appended
        # after baseJailOptions in mkToolJail, so this later --ro-bind wins.
        (unsafe-add-raw-args
          "--ro-bind ${emptySecretFile} /run/agenix/deepseek-api-key")
      ];
    });

  # Flat list of all jail packages (home.packages expects a list).
  jails = builtins.attrValues jailsByTool;

  # Short aliases for the crush jail pair: `jc` (user) and `jcs` (system, run as
  # llm via `sudo -u llm` to read/write /etc/nixos). The wrappers exec the real
  # jail binaries from `jailsByTool`, so they track the real packages.
  jc = pkgs.writeShellScriptBin "jc" ''
    exec ${jailsByTool."crush-jail"}/bin/jailed-crush "$@"
  '';
  jcs = pkgs.writeShellScriptBin "jcs" ''
    exec sudo -u ${agentUsername} ${jailsByTool."crush-jail-system"}/bin/jailed-crush-system "$@"
  '';

  # Same pair for the dsh jail: `dsh` (user) and `dshs` (system, as llm).
  dsh = pkgs.writeShellScriptBin "dsh" ''
    exec ${jailsByTool."dsh-jail"}/bin/jailed-dsh "$@"
  '';
  dshs = pkgs.writeShellScriptBin "dshs" ''
    exec sudo -u ${agentUsername} ${jailsByTool."dsh-jail-system"}/bin/jailed-dsh-system "$@"
  '';

in
{
  inherit
    jails
    # Per-tool (user, system) jail pair attrset. Exported so the NixOS system
    # module can run a specific jail directly (dsh-web.service runs
    # "dsh-jail-system") without re-deriving the jail pair.
    jailsByTool
    headroomDeepseekWrapper
    commonPkgs
    commonPkgNames
    jc
    jcs
    dsh
    dshs
    forbiddenNixCmds
    baseMounts
    secretMounts
    writablePathsSystem
    ;
}
