# Builds the (user, system) jail pair for each jailed agent (crush, opencode, aider, claude, dsh). System jails run as the llm agent user (via `sudo -u llm`) so they can edit /etc/nixos without being root.
{ lib, pkgs, jail-nix, llm-agents, deepseekSecret, nvidiaSecret, shared, userHome, dshSrc }:

let
  inherit (shared)
    headroomCloudUpstreamUrl
    headroomCloudPort
    headroomNvidiaUpstreamUrl
    headroomNvidiaPort
    headroomNinferUpstreamUrl
    models
    lspAdds
    agentHome
    agentUsername
    ;

  jail = jail-nix.lib.init pkgs;

  # Headroom context-compression proxy for DeepSeek (cloud); reads the API key from the agenix secret at runtime.
  headroomDeepseekWrapper = pkgs.writeShellScriptBin "headroom-deepseek" ''
    KEY="''$(cat ${deepseekSecret} | tr -d '\n')"
    HEADER="{\"Authorization\":\"Bearer $KEY\"}"
    exec ${pkgs.headroom}/bin/headroom proxy \
      --openai-api-url ${headroomCloudUpstreamUrl} \
      --openai-extra-headers "$HEADER" \
      --host 127.0.0.1 --port ${toString headroomCloudPort}
  '';

  # Same pattern for the NVIDIA NIM (Build) cloud endpoint (Kimi K3): reads the NVIDIA API key from the agenix secret at runtime and injects it into upstream requests via --openai-extra-headers, so the agent's dsh only ever carries a dummy credential.
  headroomNvidiaWrapper = pkgs.writeShellScriptBin "headroom-nvidia" ''
    KEY="''$(cat ${nvidiaSecret} | tr -d '\n')"
    HEADER="{\"Authorization\":\"Bearer $KEY\"}"
    exec ${pkgs.headroom}/bin/headroom proxy \
      --openai-api-url ${headroomNvidiaUpstreamUrl} \
      --openai-extra-headers "$HEADER" \
      --host 127.0.0.1 --port ${toString headroomNvidiaPort}
  '';

  withDeepSeekKey = pkg: name:
    pkgs.writeShellScriptBin name ''
      export DEEPSEEK_API_KEY="$(cat /run/agenix/deepseek-api-key)"
      export OPENAI_API_KEY="$DEEPSEEK_API_KEY"
      exec ${pkg}/bin/${name} "$@"
    '';

  # Like withDeepSeekKey but exports a non-secret placeholder: the real key is injected host-side by the headroom-proxy-deepseek service (8788, outside the jail), so dsh only needs *a* credential. The placeholder keeps the real key out of dsh's environ and bwrap argv (both readable by the same-uid agent).
  withDummyKey = pkg: name:
    pkgs.writeShellScriptBin name ''
      export DEEPSEEK_API_KEY="managed-by-headroom-proxy-8788"
      export OPENAI_API_KEY="$DEEPSEEK_API_KEY"
      exec ${pkg}/bin/${name} "$@"
    '';

  # Empty file bound over /run/agenix/deepseek-api-key in the dsh system jail so the same-uid agent can't read the real key; pinned via add-pkg-deps so GC can't orphan the store path bwrap binds.
  emptySecretFile = pkgs.writeText "empty-secret" "";

  # Stubs that refuse the system-mutating/activating CLIs (robust vs quoting/sudo/env prefixes); `nix` stays available so the agent can build but never activate.
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

  # Blender with a headless software-GL env: points libglvnd at mesa's EGL ICD and forces the swrast (llvmpipe) DRI driver so `blender -b` renders without a display/GPU.
  blenderHeadless = pkgs.writeShellApplication {
    name = "blender";
    runtimeInputs = [ pkgs.mesa pkgs.blender ];
    # ${"$"} below emits a literal `$` (Nix has no dollar-doubled escape in indented strings), giving the ${LD_LIBRARY_PATH-} default so `set -u` is safe.
    text = ''
      export LD_LIBRARY_PATH="${pkgs.mesa}/lib:${pkgs.mesa}/lib/dri:${"$"}{LD_LIBRARY_PATH-}"
      export __EGL_VENDOR_LIBRARY_FILENAMES="${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json"
      export MESA_LOADER_DRIVER_OVERRIDE=swrast
      export EGL_PLATFORM=surfaceless
      export BLENDER_GL_BACKEND=egl
      exec ${pkgs.blender}/bin/blender "$@"
    '';
  };

  # graphify: route its default LLM backend at the local NInfer endpoint. The dsh
  # jail's dummy OPENAI_API_KEY (no gemini/kimi/claude key) makes the openai backend
  # win; OPENAI_BASE_URL carries /v1 since the client appends /chat/completions. Wrapped
  # (not a global env var) so OPENAI_* doesn't leak into the other jailed tools; graphify-mcp is a passthrough.
  graphifyNinfer = pkgs.symlinkJoin {
    name = "graphify";
    paths = [
      (pkgs.writeShellScriptBin "graphify" ''
        export OPENAI_BASE_URL="${headroomNinferUpstreamUrl}/v1"
        export OPENAI_MODEL="${models.qwen38_nvfp4_ninfer.id}"
        export OPENAI_API_KEY="sk-local"
        exec ${pkgs.graphify}/bin/graphify "$@"
      '')
      (pkgs.runCommand "graphify-mcp" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.graphify}/bin/graphify-mcp $out/bin/graphify-mcp
      '')
    ];
  };

  # music-transcription: SOTA audio->Sonic-Pi pipeline env (python3.12 + torch CPU +
  # demucs + librosa + torchcrepe). `mt` runs its python so it doesn't shadow the
  # data-analysis `python3` already on PATH. Usage: mt /home/llm/music-transcription/pipe.py <track.mp3> -o out.json
  musicTranscriptionEnv = pkgs.callPackage ../../hosts/desktop/music-transcription/package.nix { };
  mt = pkgs.writeShellApplication {
    name = "mt";
    text = "exec ${musicTranscriptionEnv}/bin/python \"$@\"";
  };

  # uv pinned to 0.12.13: quail's pyproject.toml declares `required-version = "==0.12.13"`,
  # and the nixpkgs pin ships 0.12.17. Defined inline (not overrideAttrs) because the
  # nixpkgs uv package hardcodes version/src/cargoHash in the buildRustPackage body, so
  # overrideAttrs can't displace them. src = NAR hash of the unpacked 0.12.13 tree;
  # cargoHash = hash of the 0.12.13 vendored Cargo deps. The nix uv is a dynamic ELF, so
  # it runs in-jail only because baseJailOptions binds the glibc loader at
  # /lib64/ld-linux-x86-64.so.2.
  uv01213 = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "uv";
    version = "0.12.13";
    src = pkgs.fetchFromGitHub {
      owner = "astral-sh";
      repo = "uv";
      tag = "0.12.13";
      hash = "sha256-seVvrRsOpkkR28aA4EGb7w/2j7q5fD+4PgF/VVJ1yqQ=";
    };
    cargoHash = "sha256-8atFEBKefI69jnkrXmvFAEy9weQBBz3LhdVHKPNyll8=";
    buildInputs = [ pkgs."rust-jemalloc-sys" ];
    nativeBuildInputs = [ pkgs.installShellFiles ];
    cargoBuildFlags = [ "--package" "uv" ];
    doCheck = false;
    meta = {
      description = "Extremely fast Python package installer and resolver, written in Rust";
      homepage = "https://github.com/astral-sh/uv";
      license = with pkgs.lib.licenses; [ asl20 mit ];
      mainProgram = "uv";
    };
  });

  # Packages injected into every jail. Each spec carries a stable doc name + a resolver so the doc generator can list names without evaluating any package.
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
    # xz: decompress .xz archives (Nix binary-cache NARs, tarballs, etc.).
    { name = "xz"; pkg = pkgs.xz; }
    # systemd: read-only host journal access for system jails (unit states, linger, core-pin guard warnings); only works in system jails.
    { name = "systemd"; pkg = pkgs.systemd; }
    { name = "gnutar"; pkg = pkgs.gnutar; }
    { name = "diffutils"; pkg = pkgs.diffutils; }
    # gnupatch: apply/verify source and preset patches in-jail (e.g. re-syncing the dsh standard-preset delta).
    { name = "gnupatch"; pkg = pkgs.gnupatch; }
    { name = "strace"; pkg = pkgs.strace; }
    # unshare (util-linux): create isolated namespaces (e.g. `unshare -n`) so untrusted binaries can be dynamic-analyzed in-jail without network egress.
    { name = "unshare"; pkg = pkgs.util-linux; }
    { name = "openssl"; pkg = pkgs.openssl; }
    { name = "cfr"; pkg = pkgs.cfr; }
    { name = "tcpdump"; pkg = pkgs.tcpdump; }
    { name = "mitmproxy"; pkg = pkgs.mitmproxy; }
    { name = "jdk21"; pkg = pkgs.jdk21; }

    # rtk: Rust Token Killer, compresses noisy command output before it hits the context window.
    { name = "rtk"; pkg = pkgs.rtk; }
    # headroom: context optimization layer that compresses everything an agent reads (built from ./home/llm/tools/headroom.nix).
    { name = "headroom"; pkg = pkgs.headroom; }

    # graphify: codebase -> knowledge graph + stdio MCP server (built from ./home/llm/tools/graphify.nix); graphifyNinfer wraps the CLI so its LLM backend is the local NInfer endpoint.
    { name = "graphify"; pkg = graphifyNinfer; }
    # graphlore: richer MCP server (28 tools) wrapping graphify's knowledge graph (built from ./home/llm/tools/graphlore.nix).
    { name = "graphlore"; pkg = pkgs.graphlore; }
    # bend: dependently typed affine language (the `bend` CLI checks/runs/compiles .bend; built from ./home/llm/tools/bend.nix).
    { name = "bend"; pkg = pkgs.bend; }
    # difftastic: structural diff that understands syntax (the `difft` binary, built from ./home/llm/tools/difftastic.nix).
    { name = "difftastic"; pkg = pkgs.difftastic; }
    # ripwire: "the ripgrep of AI context" CLI + MCP server (built from ./home/llm/tools/ripwire.nix so `nix flake update ripwire` tracks upstream).
    { name = "ripwire"; pkg = pkgs.ripwire; }
    # openCodeReview: Alibaba's AI code review CLI, invoked as `ocr` (built from ./home/llm/tools/open-code-review.nix).
    { name = "openCodeReview"; pkg = pkgs.openCodeReview; }

    # nix: so jailed agents can search nixpkgs and eval packages against the read-only-mounted source.
    { name = "nix"; pkg = pkgs.nix; }
    # uv: Python package installer/resolver (pinned 0.12.13 for quail's required-version).
    { name = "uv"; pkg = uv01213; }

    { name = "nixGuard"; pkg = nixGuard; }

    { name = "sqlite"; pkg = pkgs.sqlite; }
    { name = "postgresql"; pkg = pkgs.postgresql; }
    { name = "mariadb.client"; pkg = pkgs.mariadb.client; }
    { name = "duckdb"; pkg = pkgs.duckdb; }

    {
      name = "python3";
      # Data-analysis stack: jupyter metapackage, polars, seaborn, duckdb bindings — one env so the notebook kernel sees the same modules as `python3` on PATH.
      pkg = pkgs.python3.withPackages (ps: [
        ps.cryptography
        ps.dnslib
        ps.numpy
        ps.pillow
        ps.requests
        ps.seaborn
        ps.polars
        ps.duckdb
        ps.jupyter
      ]);
    }

    # mt: SOTA audio->Sonic-Pi pipeline env (python3.12 + torch CPU + demucs + librosa + torchcrepe); runs the env's python (see musicTranscriptionEnv).
    { name = "music-transcription"; pkg = mt; }

    # blender: headless 3D rendering for the code-tree generator (the blenderHeadless wrapper supplies the software GL).
    { name = "blender"; pkg = blenderHeadless; }

    # Security audit tooling: multi-language static analysis (semgrep C++/JS/TS/Python, nodejs JS/TS linters, cppcheck C++, bandit Python).
    { name = "semgrep"; pkg = pkgs.semgrep; }
    { name = "nodejs"; pkg = pkgs.nodejs; }
    { name = "cppcheck"; pkg = pkgs.cppcheck; }
    { name = "bandit"; pkg = pkgs.bandit; }

    # --- Compilers / language toolchains (Rust, GCC, Go, Zig, C#/.NET, Julia, OCaml, GHC, Kotlin, Scala). ---
    { name = "rustc"; pkg = pkgs.rustc; }
    { name = "cargo"; pkg = pkgs.cargo; }
    { name = "clippy"; pkg = pkgs.rustPackages.clippy; }
    { name = "rustfmt"; pkg = pkgs.rustPackages.rustfmt; }
    { name = "rust-analyzer"; pkg = pkgs.rust-analyzer; }
    { name = "gcc"; pkg = pkgs.gcc; }
    { name = "go"; pkg = pkgs.go; }
    { name = "zig"; pkg = pkgs.zig; }
    { name = "dotnet-sdk"; pkg = pkgs.dotnet-sdk; }
    { name = "julia"; pkg = pkgs.julia; }
    { name = "ocaml"; pkg = pkgs.ocaml; }
    { name = "ghc"; pkg = pkgs.ghc; }
    { name = "kotlin"; pkg = pkgs.kotlin; }
    { name = "scala"; pkg = pkgs.scala; }

    # --- Web: JS/TS runtimes + package managers, headless browsers, web servers, interpreters, Wasm. ---

    # --- JS/TS runtimes & package managers. ---
    { name = "bun"; pkg = pkgs.bun; }
    { name = "deno"; pkg = pkgs.deno; }
    { name = "pnpm"; pkg = pkgs.pnpm; }
    { name = "yarn"; pkg = pkgs.yarn; }

    # --- Headless browsers + automation (testing / scraping / E2E). ---
    { name = "firefox"; pkg = pkgs.firefox; }
    { name = "playwright"; pkg = pkgs.python3Packages.playwright; }
    { name = "selenium"; pkg = pkgs.python3Packages.selenium; }

    # --- Web servers. ---
    { name = "nginx"; pkg = pkgs.nginx; }
    { name = "caddy"; pkg = pkgs.caddy; }
    { name = "apacheHttpd"; pkg = pkgs.apacheHttpd; }

    # --- Web-language interpreters. ---
    { name = "ruby"; pkg = pkgs.ruby; }
    { name = "php"; pkg = pkgs.php; }

    # --- Web infra + Wasm. ---
    { name = "redis"; pkg = pkgs.redis; }
    { name = "wasmtime"; pkg = pkgs.wasmtime; }

    # --- Red/blue team software-security toolkit (nixpkgs attrs; the jail's real boundary is bwrap, these are convenience coverage). ---

    # --- Network / recon (red team): port & service discovery, socket state. ---
    { name = "nmap"; pkg = pkgs.nmap; }
    { name = "masscan"; pkg = pkgs.masscan; }
    { name = "netcat"; pkg = pkgs.netcat; }
    { name = "socat"; pkg = pkgs.socat; }
    { name = "iproute2"; pkg = pkgs.iproute2; }
    { name = "lsof"; pkg = pkgs.lsof; }
    { name = "psmisc"; pkg = pkgs.psmisc; }
    { name = "procps"; pkg = pkgs.procps; }
    { name = "nethogs"; pkg = pkgs.nethogs; }
    { name = "iftop"; pkg = pkgs.iftop; }

    # --- Web / HTTP (red team): fuzzing, vuln scanning, TLS & fingerprinting. ---
    { name = "ffuf"; pkg = pkgs.ffuf; }
    { name = "feroxbuster"; pkg = pkgs.feroxbuster; }
    { name = "gobuster"; pkg = pkgs.gobuster; }
    { name = "nikto"; pkg = pkgs.nikto; }
    { name = "httpx"; pkg = pkgs.httpx; }
    { name = "nuclei"; pkg = pkgs.nuclei; }
    { name = "subfinder"; pkg = pkgs.subfinder; }
    { name = "dnsx"; pkg = pkgs.dnsx; }
    { name = "naabu"; pkg = pkgs.naabu; }
    { name = "whatweb"; pkg = pkgs.whatweb; }
    { name = "wafw00f"; pkg = pkgs.wafw00f; }
    { name = "sqlmap"; pkg = pkgs.sqlmap; }
    { name = "testssl"; pkg = pkgs.testssl; }
    { name = "sslscan"; pkg = pkgs.sslscan; }
    { name = "tcpkali"; pkg = pkgs.tcpkali; }

    # --- Credentials / AD (red team): spraying, cracking, Windows protocols. ---
    { name = "hydra"; pkg = pkgs.hydra; }
    { name = "john"; pkg = pkgs.john; }
    { name = "hashcat"; pkg = pkgs.hashcat; }
    { name = "netexec"; pkg = pkgs.netexec; }
    { name = "responder"; pkg = pkgs.responder; }
    { name = "impacket"; pkg = pkgs.python3Packages.impacket; }
    { name = "pypykatz"; pkg = pkgs.python3Packages.pypykatz; }

    # --- Binary / reverse engineering (red team): debug, disasm, exploit dev. ---
    { name = "gdb"; pkg = pkgs.gdb; }
    { name = "radare2"; pkg = pkgs.radare2; }
    # angr dropped: its nixpkgs recipe fails on python 3.14 (needs setuptools-rust, undeclared); radare2 + gdb + pwntools cover RE.
    { name = "pwntools"; pkg = pkgs.python3Packages.pwntools; }
    { name = "binutils"; pkg = pkgs.binutils; }
    # ldd (glibc's bin output): resolve a binary's dynamic-link closure in-jail.
    { name = "ldd"; pkg = pkgs.glibc.bin; }
    { name = "file"; pkg = pkgs.file; }
    { name = "hexedit"; pkg = pkgs.hexedit; }
    { name = "upx"; pkg = pkgs.upx; }
    { name = "ltrace"; pkg = pkgs.ltrace; }
    { name = "valgrind"; pkg = pkgs.valgrind; }

    # --- Forensics (red/blue): metadata, carving, memory, patterns, packets. ---
    { name = "exiftool"; pkg = pkgs.exiftool; }
    { name = "binwalk"; pkg = pkgs.binwalk; }
    { name = "foremost"; pkg = pkgs.foremost; }
    { name = "scalpel"; pkg = pkgs.scalpel; }
    { name = "testdisk"; pkg = pkgs.testdisk; }
    { name = "volatility3"; pkg = pkgs.volatility3; }
    { name = "yara"; pkg = pkgs.yara; }
    { name = "wireshark"; pkg = pkgs.wireshark; }

    # --- Secrets / dependency audit (blue team): leak + vuln + SBOM scanning. ---
    { name = "gitleaks"; pkg = pkgs.gitleaks; }
    { name = "trufflehog"; pkg = pkgs.trufflehog; }
    { name = "detect-secrets"; pkg = pkgs."detect-secrets"; }
    { name = "shellcheck"; pkg = pkgs.shellcheck; }
    { name = "codeql"; pkg = pkgs.codeql; }
    { name = "clang"; pkg = pkgs.clang; }
    { name = "trivy"; pkg = pkgs.trivy; }
    { name = "grype"; pkg = pkgs.grype; }
    { name = "syft"; pkg = pkgs.syft; }
    { name = "osv-scanner"; pkg = pkgs."osv-scanner"; }
    { name = "cargo-audit"; pkg = pkgs."cargo-audit"; }
    { name = "govulncheck"; pkg = pkgs.govulncheck; }
    { name = "pip-audit"; pkg = pkgs."pip-audit"; }
    { name = "safety"; pkg = pkgs.python3Packages.safety; }

    # --- Integrity / system audit (blue team): FIM, audit, observability. ---
    # (chkrootkit removed + rkhunter absent in the pinned nixpkgs; rootkit detection is covered by aide FIM + osquery + lynis.)
    { name = "aide"; pkg = pkgs.aide; }
    { name = "audit"; pkg = pkgs.audit; }
    { name = "osquery"; pkg = pkgs.osquery; }
    { name = "lynis"; pkg = pkgs.lynis; }

    # --- OSINT / recon (red team): social/email, subdomains, web history, DNS. ---
    # (theharvester dropped: it bundles playwright, whose pinned source hash is stale in this nixpkgs rev.)
    { name = "maigret"; pkg = pkgs.maigret; }
    { name = "snscrape"; pkg = pkgs.snscrape; }
    { name = "amass"; pkg = pkgs.amass; }
    { name = "assetfinder"; pkg = pkgs.assetfinder; }
    { name = "subjack"; pkg = pkgs.subjack; }
    { name = "waybackurls"; pkg = pkgs.waybackurls; }
    { name = "gau"; pkg = pkgs.gau; }
    { name = "katana"; pkg = pkgs.katana; }
    { name = "unfurl"; pkg = pkgs.unfurl; }
    { name = "whois"; pkg = pkgs.whois; }
    { name = "dnsutils"; pkg = pkgs.dnsutils; }
    { name = "dnsenum"; pkg = pkgs.dnsenum; }
    { name = "fierce"; pkg = pkgs.fierce; }
    { name = "fping"; pkg = pkgs.fping; }
    { name = "mtr"; pkg = pkgs.mtr; }
    { name = "rustscan"; pkg = pkgs.rustscan; }
    { name = "ettercap"; pkg = pkgs.ettercap; }
    { name = "bettercap"; pkg = pkgs.bettercap; }
    { name = "aircrack-ng"; pkg = pkgs.aircrack-ng; }
    { name = "wpscan"; pkg = pkgs.wpscan; }
    { name = "arjun"; pkg = pkgs.arjun; }
    { name = "wfuzz"; pkg = pkgs.wfuzz; }
    { name = "dalfox"; pkg = pkgs.dalfox; }
    { name = "commix"; pkg = pkgs.commix; }

    # --- CTF: pwn / crypto / stego / packets. ---
    # Math & crypto: z3 (SMT), sympy (symbolic), gmpy2 (bignum), pycryptodome, sage (SageMath).
    { name = "z3"; pkg = pkgs.z3; }
    { name = "sympy"; pkg = pkgs.python3Packages.sympy; }
    { name = "gmpy2"; pkg = pkgs.python3Packages.gmpy2; }
    { name = "pycryptodome"; pkg = pkgs.python3Packages.pycryptodome; }
    { name = "sage"; pkg = pkgs.sage; }
    # Pwn / ROP: ropper (gadget finder) + checksec (binary hardening flags).
    { name = "ropper"; pkg = pkgs.python3Packages.ropper; }
    { name = "checksec"; pkg = pkgs.checksec; }
    # Stego: image/metadata hiding & extraction.
    { name = "steghide"; pkg = pkgs.steghide; }
    { name = "zsteg"; pkg = pkgs.zsteg; }
    { name = "stegsolve"; pkg = pkgs.stegsolve; }
    { name = "stegseek"; pkg = pkgs.stegseek; }
    { name = "outguess"; pkg = pkgs.outguess; }
    # Packets: scapy (crafting) + tcpflow (per-connection extraction).
    { name = "scapy"; pkg = pkgs.python3Packages.scapy; }
    { name = "tcpflow"; pkg = pkgs.tcpflow; }

    # --- Storytelling / data-viz: Quarto (Markdown + Python/R slides + data execution + Plotly/Vega/ggplot -> static HTML),
    #     Vega-Lite + vega-cli (declarative grammar-of-graphics, runtime data fetch), Marp (minimal Markdown decks),
    #     pandoc (universal conversion), Plotly + Altair (charts inside Quarto), Hugo (static-site storyboards).
    { name = "quarto"; pkg = pkgs.quarto; }
    { name = "vega-lite"; pkg = pkgs.vega-lite; }
    { name = "vega-cli"; pkg = pkgs.vega-cli; }
    { name = "marp"; pkg = pkgs.marp-cli; }
    { name = "pandoc"; pkg = pkgs.pandoc; }
    { name = "plotly"; pkg = pkgs.python3Packages.plotly; }
    { name = "altair"; pkg = pkgs.python3Packages.altair; }
    { name = "hugo"; pkg = pkgs.hugo; }

    # --- Data analytics / self-contained "Tableau-feel" (FOSS): in-process analytics + declarative/interactive rendering so a deck stays a self-contained, refreshable file. ---
    { name = "duckdb"; pkg = pkgs.duckdb; }
    { name = "pandas"; pkg = pkgs.python3Packages.pandas; }
    { name = "polars"; pkg = pkgs.python3Packages.polars; }
    { name = "sqlglot"; pkg = pkgs.python3Packages.sqlglot; }
    { name = "arrow"; pkg = pkgs.python3Packages.arrow; }
    { name = "echarts"; pkg = pkgs.echarts; }
  ];

  commonPkgs = map (spec: spec.pkg) commonPkgSpecs;
  commonPkgNames = map (spec: spec.name) commonPkgSpecs;

  # Pure mount-list builder (separate from baseJailOptions) so agents-manifest.nix can render the readonly mounts into AGENTS.md without calling into jail-nix.
  # /etc/machine-id (system jails): the jail's /etc is a fresh tmpfs, so the host's machine-id is invisible unless bound in (journalctl resolves the journal dir via it).
  baseMounts = system: (lib.optional (!system) "/etc/nixos") ++ [ "/var/log" ]
    ++ (if system then [ "/var/log/journal" "/run/systemd" "/etc/machine-id" ] else [ ])
    ++ (if system then [ "/sys" "/run/user" ] else [ ])
    ++ [ "/nix/store" ];

  # agenix secret(s) mounted read-only into every jail; kept out of baseMounts so naming the secret path in AGENTS.md doesn't leak the secret name.
  secretMounts = [ deepseekSecret ];

  readonlyMounts = system: baseMounts system ++ secretMounts;

  # Extra writable paths for system jails (user jails' $PWD is a runtime path, handled via mount-cwd).
  writablePathsSystem = [ "/etc/nixos" agentHome ];

  # The shared LSP set is mounted once per jail (not per tool) so we don't bundle a fresh per-tool closure.
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
    # The jail's / is a fresh tmpfs with no /lib64, so every dynamically-linked
    # binary (uv, uv-managed CPython, PyPI wheels like ruff) whose ELF interpreter
    # is /lib64/ld-linux-x86-64.so.2 fails with ENOENT. Bind the nix glibc loader
    # in so the kernel can find it; --dir must precede the file bind.
    (unsafe-add-raw-args
      "--dir /lib64 --ro-bind ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2")
    # The jail's / is a fresh tmpfs, so PyPI wheels' C extensions (numpy, torch,
    # pyarrow in the agent's venvs) can't find libstdc++/libz via default paths.
    # --clearenv wipes the caller's env, so this must be set inside the jail (not
    # the service env). The /lib64 bind above handles the ELF interpreter; this
    # handles the shared-library search path.
    (set-env "LD_LIBRARY_PATH" "${pkgs.libgcc}/lib:${pkgs.zlib}/lib")
  ] ++ lspAdds;

  mkToolJail = { name, pkg, dirs, system, systemExtraPkgs ? [ ], systemExtraMounts ? [ ] }:
    jail "jailed-${name}${if system then "-system" else ""}"
      pkg
      (with jail.combinators;
      baseJailOptions system ++
      dirs ++
      [ (add-pkg-deps (commonPkgs ++ (if system then systemExtraPkgs else [ ]))) ]
      ++ (if system then systemExtraMounts else [ ]));

  # Per-tool read/write dirs, relative to the owning home (user: userHome, system: agentHome); absolute paths so user and system mounts stay statically identical.
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
  # dsh keeps all user data under a single root (~/.dsh, overridable via $DSH_HOME); the jail pins HOME, so the default root is what gets mounted.
  dshDirPaths = [
    ".dsh"
  ];

  agent = n: llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.${n};

  # Jailed crush is already sandboxed by bubblewrap, so strip the hardcoded network/download + network-config command bans from bash.go: the jail is the real security boundary.
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
      # Also drop the stale "never use curl in bash" instruction from the system prompt template (the jail is the real boundary).
      sed -i \
        -e '/Never use `curl` through the bash tool/d' \
        internal/agent/templates/coder.md.tpl
    '';
  });

  # The dsh system jail is headless with no real xdg-open, so dsh's host-side opener fails with `spawn xdg-open ENOENT`; this wrapper forwards the path to the dsh-open handler (runs as b) over /run/dsh-open/open.sock.
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
      # Make the file (and every llm-owned ancestor dir) group-readable+writable so b (in the llm group) can read it and save edits back; root-owned dirs are skipped.
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
      # Forward the path to the dsh-open handler (runs as b) over the agent-only Unix socket (one line in, one line out).
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

  # dsh is built from source (the flakeless `dsh` input): home/llm/dsh/ replicates the upstream release pipeline to produce the @deepseek-ai/dsh npm tarball (tarball.nix) and installs it without running npm (package.nix: node_modules unpacked from per-package fetchurl FODs, since `npm ci` OOMs on this tree). The version follows the pinned tree's root package.json; `just dsh-repin` re-pins it.
  # The shipped `standard` preset is patched in place at build time (the user preset root can't shadow the shipped one, first-root-wins); writeText makes the patch a derivation input (a bare repo path is invisible to the sandboxed builder).
  dshPkg = (import ./dsh/default.nix) {
    inherit pkgs;
    src = dshSrc;
    versionCheckHomeHook = agent "versionCheckHomeHook";
  };

  dshPatched = dshPkg.package.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.gnupatch ];
    postInstall = (old.postInstall or "") + ''
      patch -p1 -d $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-app/presets \
        < ${pkgs.writeText "dsh-standard-preset.patch" (builtins.readFile ../../dotfiles/dsh/standard-preset.patch)}
    '';
  });

  # Build a (user, system) jail pair for a tool. systemExtra* apply only to the system variant; systemDirs replaces the default agent-home dirs when a system variant needs a different mount set.
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
      # Debug tooling for the system jail: PipeWire/WirePlumber CLIs for audio stream state, plus read-only /sys (cpufreq) and /run/user (session sockets).
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
      # Dummy key: the real DeepSeek key is injected host-side by the headroom-proxy-deepseek service (8788, outside the jail); see withDummyKey.
      pkg = withDummyKey dshPatched "dsh";
      dirPaths = dshDirPaths;
      # The jail's /run is a fresh tmpfs, so the dsh-open socket must be bind-mounted in; mount the DIRECTORY (not the socket) so a switch that recreates it leaves no stale inode (ENXIO).
      # openssh client: the dsh agent reaches LAN hosts (e.g. the Home Assistant server) to explore device cloud Api / MQTT; the jail already allows network, this only adds the binaries.
      systemExtraPkgs = [ dshOpenXdgOpen emptySecretFile pkgs.openssh pkgs.discord ];
      systemExtraMounts = with jail.combinators; [
        (readwrite "/run/dsh-open")
        # Shadow the agenix secrets that baseJailOptions ro-binds into every jail: bind the empty store file over each so the same-uid agent can't read the real cloud key. systemExtraMounts is appended after baseJailOptions, so this later --ro-bind wins.
        (unsafe-add-raw-args
          "--ro-bind ${emptySecretFile} /run/agenix/deepseek-api-key")
        (unsafe-add-raw-args
          "--ro-bind ${emptySecretFile} /run/agenix/nvidia-api-key")
      ];
    });

  # Flat list of all jail packages (home.packages expects a list).
  jails = builtins.attrValues jailsByTool;

  # Short aliases for the crush jail pair: `jc` (user) and `jcs` (system, as llm); the wrappers exec the real jail binaries from jailsByTool.
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
    # Per-tool (user, system) jail pair attrset; exported so the NixOS system module can run a specific jail directly (dsh-web.service runs "dsh-jail-system").
    jailsByTool
    # The raw dsh npm package (before jail wrapping); exported so the npm closure re-pin can be verified in isolation.
    dshPatched
    headroomDeepseekWrapper
    headroomNvidiaWrapper
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
