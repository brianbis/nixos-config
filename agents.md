# Maintainer Guide: NixOS Repo and Jailed Agent Execution Environment

## Purpose
This file documents how this NixOS flake provisions the host, secrets, local LLM services, and the jailed agent runtime. Follow it to add models, change tools, or debug agent behavior.

## Repository layout
```
/etc/nixos/
  flake.nix                # Flake inputs, overlays, home-manager wiring
  flake.lock
  justfile                 # Common operations
  secrets.nix              # agenix public keys
  secrets/                 # age-encrypted secrets
  home/
    default.nix
    packages.nix
    plasma.nix
    firefox/
    sts.nix
    llm/
      catalog.nix          # Single source of truth for models, providers, LSPs, configs
      configs.nix
      default.nix
      jails.nix
      services.nix
  hosts/desktop/
    default.nix            # Host baseline
    hardware-configuration.nix
    audio.nix bluetooth.nix boot.nix networking.nix nvidia.nix plasma.nix security.nix steam.nix
    packages.nix
    monitor/
    crush-system.nix       # Seeds root-owned state for system jails
    llamacpp.nix           # llama.cpp server
    vllm.nix               # vLLM docker services
  packages/
    ast-grep-cli.nix
    headroom.nix
```

## Core principles
- Keep all agent configuration in `home/llm/catalog.nix`. Do not duplicate model or LSP definitions elsewhere.
- User jails use `$HOME` state. System jails use `/var/lib/crush-system`.
- Headroom proxies all local and cloud LLM traffic. Never point agents directly at upstream services.
- All changes go through `just switch` which auto-stages and rebuilds the flake.

## Flake inputs
`flake.nix` defines:
- `nixpkgs unstable`, `home-manager`, `plasma-manager`, `agenix`, `nur`
- `jail-nix`, `llm-agents.nix`, `hushmic-nix`, `sidra`
- Overlays:
  - add `ast-grep-cli` and `headroom` to python3
  - override `llama-cpp` to a specific tag with CUDA enabled

Do not add model-specific logic to flake.nix. Edit the catalog.

## Secrets
Secrets are managed with agenix:
- `secrets.nix` lists public keys for `secrets/*.age`
- Identity key: `/var/lib/agenix/key.txt`
- Use `just secret-edit NAME`, `just secret-show NAME`, `just secrets-check`

## LLM catalog
Edit `home/llm/catalog.nix` only.

### Proxies
- Local OpenAI-compatible: `127.0.0.1:8787` -> upstream `127.0.0.1:8000`
- Cloud OpenAI-compatible: `127.0.0.1:8788` -> `https://api.deepseek.com/v1`
- Claude Code Anthropic: `127.0.0.1:8789` -> local llama server

### Models
Add/remove entries in `models`. Each entry needs `providerName`, `id`, `name`, `url`, `context`, `maxTok`, `reason`, `attachments` as required.

Catalog derives `crushProviders`, `opencodeProviders`, and `claudeConfig`. Parity is automatic.

### LSPs
`lsps` defines language servers. The catalog generates per-tool LSP maps with `file_types` and `root_markers`.

### Config generation
`crushConfigFor base` renders data_directory, PreToolUse rtk-rewrite hook, mcp.headroom, lsp map, providers map. System config uses `/var/lib/crush-system`, user config uses `$HOME`.

## Jail architecture
`home/llm/jails.nix` builds a user jail and a system jail for each agent tool: crush, opencode, aider, claude. Jails are bubblewrap sandboxes via `jail-nix`.

### Base options
- `network`, `time-zone`, `no-new-session`
- `HOME` pinned to `userHome` or `systemStateDir`
- System jails: readwrite `/etc/nixos` and `systemStateDir`
- User jails: `mount-cwd`
- Readonly nixpkgs source mount with `NIX_CONFIG=experimental-features=nix-command flakes`
- Readonly `/run/agenix/deepseek-api-key`
- LSP packages mounted via `lspAdds`

### Common packages
bashInteractive, curl, wget, jq, git, ripgrep, gnugrep, gnused, gawkInteractive, ps, findutils, gzip, unzip, gnutar, diffutils, strace, openssl, cfr, tcpdump, mitmproxy, jdk21, rtk, headroom, nix, nixGuard, sqlite, postgresql, mariadb.client, python3 with cryptography/dnslib/requests.

### nixGuard
Stubs for `nixos-rebuild`, `nixos-install`, `home-manager`, `nix-env`, `nix-channel` print denial and exit 1. Agents can edit config but cannot activate.

### Per-tool directories
- aider: `~/.config/aider`, `~/.aider.conf.yml`, `~/.gitconfig`
- crush: `~/.config/crush`, `~/.local/share/crush`
- opencode: `~/.config/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode`
- claude: `~/.claude`, `~/.claude.json`
System variants use `systemStateDir/.config` and `systemStateDir/.local/share`.

### DeepSeek key handling
`headroomDeepseekWrapper` reads API key from agenix secret at runtime. `withDeepSeekKey` exports `DEEPSEEK_API_KEY` and `OPENAI_API_KEY` before exec.

### Crush unban
`crushUnbanned` removes hardcoded network/download tool bans from `internal/agent/tools/bash.go` and system prompt, because the jail is the security boundary.

### Security properties
- No host root access except explicit mounts
- Network allowed, egress controlled by headroom proxies
- System activation denied via nixGuard
- Home access limited to whitelisted dirs
- System jails cannot reach user 700 home, hence separate state tree
- All agents share catalog, LSP set, and common packages

## Host services
### llama.cpp
`hosts/desktop/llamacpp.nix` downloads GGUF weights to `/var/lib/llama/models` on activation using `hf-token`. Starts `llamacpp-muse.service` on `127.0.0.1:8000`. Manual start via `just llamacpp-start`.

### vLLM
`hosts/desktop/vllm.nix` defines Docker services. Only one container may run at a time due to VRAM.

### crush-system
`hosts/desktop/crush-system.nix` creates `/var/lib/crush-system` tmpfiles and activation script writing `crush.json`, `rtk-rewrite.sh`, `.claude/settings.json`. Required because root jails cannot access user home.

## Host modules
### hosts/desktop/default.nix
Imports all modules, hostname `nixos`, timezone America/Phoenix, stateVersion 26.05, nix experimental features, weekly gc, user `b` groups networkmanager wheel dialout llm.

### hosts/desktop/hardware-configuration.nix
Auto-generated, do not edit. Defines btrfs root, initrd modules.

### hosts/desktop/audio.nix
Disables pulseaudio, enables PipeWire with ALSA, rtkit, deepfilternet + hushmic. PipeWire filter chain for DeepFilter mic from MOTU M4. WirePlumber bluetooth policy for A2DP sink only.

### hosts/desktop/bluetooth.nix
Defines headphone MACs, provides `bt-connect-headphones` script.

### hosts/desktop/boot.nix
Enables systemd-boot, allows EFI variable touch.

### hosts/desktop/networking.nix
Enables NetworkManager, Tailscale with auth key from agenix.

### hosts/desktop/nvidia.nix
X driver nvidia, kernel param PreserveVideoMemoryAllocations, modesetting, nvidiaSettings, open kernel, power management. Sets VAAPI vars, installs nvtop.

### hosts/desktop/plasma.nix
Enables X server, SDDM, Plasma6, default session plasma.

### hosts/desktop/security.nix
Imports agenix, creates `llm` group, adds user `b`, configures sudo.

### hosts/desktop/steam.nix
Enables Steam and gamemode.

### hosts/desktop/packages.nix
System packages: agenix, konsole, xwayland-satellite, python data packages.

### hosts/desktop/monitor/
Monitor config and scripts for display discovery, kscreen backend, sddm-kwin backend.

## Home modules
### home/default.nix
Home Manager for user `b`. Imports packages, plasma, firefox, sts, llm, plasma-manager.

### home/packages.nix
User packages, custom derivations like fluent-oled.

### home/plasma.nix
Plasma customization, Alt+F4 close or shutdown script.

### home/firefox/
Firefox home config: default.nix, settings.nix, addons.nix, tree_style_tab, userChrome.css.

### home/sts.nix
Home activation to install Slay the Spire 2 Archipelago client.

### home/llm/
- catalog.nix – single source of truth
- configs.nix – tool config rendering
- default.nix – imports jails and services
- jails.nix – jail definitions
- services.nix – headroom services

## Packages
### packages/headroom.nix
Python package definition for headroom context compression proxy.

### packages/ast-grep-cli.nix
Python wrapper for ast-grep CLI.

## Agent execution environment
### General
Working directory `/etc/nixos`. Repo is git on `main`. Agents run in jails via `jail-nix`.

### Crush
Config: `/var/lib/crush-system/.config/crush/crush.json` for system, `~/.config/crush/crush.json` for user. Data dir under `.local/share/crush`. PreToolUse rtk-rewrite hook. MCP headroom stdio server. LSPs start on demand.

### Claude Code
Settings at `~/.claude/settings.json` and `/var/lib/crush-system/.claude/settings.json`. Env vars `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` injected from catalog. Routes via `127.0.0.1:8789`.

### OpenCode / Aider
Derive providers/models from catalog. No per-tool manual edits.

### Model and provider changes
1. Edit `home/llm/catalog.nix`
2. Run `just switch`
3. Restart agent services
4. Verify `cat ~/.config/crush/crush.json | jq .providers`

### Debugging
- `cat /var/lib/crush-system/.config/crush/crush.json`
- `curl -s http://127.0.0.1:8787/health`
- `just llamacpp-health`
- `just vllm-status`
- `journalctl -u llamacpp-muse.service -f`
- `just secrets-check`

### Operational rules
- Do not start both vLLM containers simultaneously
- `llamacpp-muse.service` is manual start
- Never point agents directly at `127.0.0.1:8000`, use headroom proxy
- Model weights under `/var/lib/llama/models`, activation handles download
- System state under `/var/lib/crush-system`, regenerated on switch

## Operational notes
- `just switch` stages git and runs `nixos-rebuild switch --flake .`
- `just secrets-check` validates all age secrets
- Monitor scripts in `hosts/desktop/monitor/scripts/` handle display hotplug
