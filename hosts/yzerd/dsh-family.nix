{ config, lib, pkgs, ... }:

# The family door, one member per row.
#
# One row = one unix user (own home, own ~/.dsh = the data separation), one
# private dsh web instance bound to loopback on its own port, and one Tailscale
# Serve service = its own tailnet hostname. Sign-in is Tailscale's own login
# (the member's device is enrolled under their tailnet account); there is no
# nginx/caddy/htpasswd layer on this box — the tailnet IS the gate
# ("lets just use tailscale", 2026-10-31), so the bcrypt front gate from the
# nginx/caddy experiment is deliberately gone.
#
# One-time provisioning per member (README.md "The family door over the
# tailnet"): add a row below, commit, and the CI rebuild creates the user,
# the instance and the Serve service; on the tailscale side the member
# creates their tailnet account (the one-time account creation) and enrolls
# their devices. Ongoing registration is NOT a thing we support: rows are
# the ledger, added by whoever edits this repo.
#
# ACCEPTED RISK, stated where it can be found: a signed-in family member's
# dsh is an agent with bash on this CI box, unjailed (the user's decision,
# 2026-10-31, mirrored here and in README.md). Rows carry no wheel/sudo
# group on purpose: the member gets an agent at their own uid, not root's
# CI state.

let
  # Fact, not taste: the tailnet this node joins serves hostnames under
  # this domain (desktop precedent: svc:dsh → dsh.tail835824.ts.net). A
  # member's Serve hostname is `<member>.<tailnet-domain>`, which is also
  # the value dsh must trust: Serve presents that Host to the upstream
  # unchanged (same reason the desktop's dsh-web carries --trusted-host).
  tailnetDomain = "tail835824.ts.net";

  members = {
    jeffbis = {
      # dshPort: the member's private loopback instance port — unique per
      # node (the CI ledger's 180xx rows are gate-owned, untouched here).
      # servePort: Tailscale Serve listener port, unique per node (the
      # docs' "same port cannot be used for Serve" limitation) and inside
      # tailscale's allowed set {80, 8080, 443, 8443}.
      dshPort = 3091;
      servePort = 443;
    };
  };

  dshBin = pkgs."dsh-pkg"; # injected by flake.nix from the ./dsh builder copy

  # Per-member `tailscale serve` command, bound at the Nix level so the
  # AGENTS.md interpolation rule holds: a string with its own ${...} is a
  # let-bound fragment, never nested inside another string's interpolation.
  serveApplyLines =
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: m:
      "tailscale serve --service=svc:${name} --yes --https=${toString m.servePort} http://127.0.0.1:${toString m.dshPort}"
    ) members);

  # The default model every member gets: the box's local coder engine —
  # strata-coder-serve (./llm/strata/default.nix repeats the coder ledger
  # port 18088 literally; there is no catalog on this box, and the module
  # says so). Loopback-only like every engine port: model traffic never
  # crosses the tailnet, the browser only ever talks to the member's own
  # Serve hostname. Row facts mirror catalog/default.nix's
  # strata_qwen38_coder row (id, context 200K, maxTok 32768) plus the
  # compat pair every non-deepseek openai-completions route carries; no
  # reasoningEfforts row, so no effort is sent (the desktop patch's
  # render agrees).
  familyPatch = ''
    # Family default: the box's local coder engine (strata-coder-serve,
    # :18088 loopback). Home-level layer: applies above every profile.
    # Replacing the llm-pi-ai config wholesale drops the hosted provider
    # rows on purpose — a family member never reaches api.deepseek.com.
    - id: llm-pi-ai
      config:
        providers:
          strata_coder:
            displayName: Strata Coder (local)
            apiKeyEnv: DEEPSEEK_API_KEY
            api: openai-completions
            baseURL: http://127.0.0.1:18088/v1
            models:
              - id: qwen3.8-flash-next-coder
                name: Qwen3.8-Flash-Next Coder IQ1_M (Strata)
                contextWindow: 200000
                maxTokens: 32768
                compat:
                  supportsDeveloperRole: false
                  maxTokensField: max_tokens
    - id: agent-default-model
      config:
        provider: strata_coder
        model: qwen3.8-flash-next-coder
  '';
in
{
  users.users = lib.mapAttrs (name: m: {
    # passwd's gecos field: no colons, no newlines (type-checked).
    description = "family member ${name}, dsh instance on port ${toString m.dshPort}";

    group = name;
    isNormalUser = true;
    home = "/home/${name}";
    homeMode = "0700";
    # Deliberately empty: no wheel, no sudo group, no password, no ssh key.
    # The door is the tailnet, not an ssh session, and the accepted-risk
    # boundary is "agent at this uid", not "owner of the box".
    extraGroups = [ ];
  }) members;

  users.groups = lib.mapAttrs (_: _: { }) members;

  systemd.services = (lib.mapAttrs' (name: m: lib.nameValuePair "dsh-web-${name}" {
    description = "dsh web GUI for family member ${name} (private instance)";
    wantedBy = [ "multi-user.target" ];
    # The service runs as this uid; pin HOME (the pin's option name is
    # `environment`, not the older `env`) so the instance's state —
    # ~/.dsh — is the member's own, never someone else's. The key is the
    # dummy pi-ai insists on even for local endpoints; strata's server
    # runs keyless (header ignored — an unset svc api_key needs nothing).
    environment = {
      HOME = "/home/${name}";
      DEEPSEEK_API_KEY = "managed-by-yzerd-tailnet-door-keyless";
    };
    # Seed the member's default model layer on first start, from the
    # store-backed etc file below; only if absent, so the member's own
    # tweaks survive every restart. dsh hot-reloads the copied file.
    preStart = ''
      if [ ! -f "$HOME/.dsh/cordis.patch.yml" ]; then
        mkdir -p "$HOME/.dsh"
        install -m 0600 /etc/dsh-family/cordis.patch.yml "$HOME/.dsh/cordis.patch.yml"
      fi
    '';
    serviceConfig = {
      Type = "simple";
      User = name;
      Group = name;
      # --trusted-host: Serve hands its own tailnet hostname up as Host
      # unchanged, so the GUI's browser-trust fence accepts exactly that
      # host for this member. Privileged methods stay loopback-only.
      ExecStart = "${dshBin}/bin/dsh --profile web --port ${toString m.dshPort} --trusted-host ${name}.${tailnetDomain}";
      Restart = "on-failure";
      RestartSec = "3";
    };
  })) members // {

  # One unit applies every member's Serve service, mirroring the desktop's
  # tailscale-serve unit (same tag-wait, same reset-then-apply dance, same
  # start-limit burst): `serve reset` clears the node's Serve config once,
  # then each row is applied on its own port.
  tailscale-serve-family = {
    description = "Tailscale Serve: apply every member's dsh service (svc:<member>, HTTPS)";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "tailscaled-autoconnect.service" "tailscale-advertise-tags.service" ]
      ++ map (name: "dsh-web-${name}.service") (lib.attrNames members);
    wants = [ "tailscaled.service" "tailscale-advertise-tags.service" ]
      ++ map (name: "dsh-web-${name}.service") (lib.attrNames members);
    startLimitIntervalSec = 900;
    startLimitBurst = 15;
    path = [ config.services.tailscale.package pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "2min";
    };
    script = ''
      # Wait for the control plane to apply the node tag (up to 60s) —
      # Serve hosts need the tagged node before the hostnames resolve.
      tagged() {
        tailscale status --json | jq -e '.Self.Tags // [] | index("tag:devices") != null' > /dev/null 2>&1
      }
      for _ in $(seq 1 30); do
        tagged && break
        sleep 2
      done
      if ! tagged; then
        echo "tag:devices not applied to this node within 60s; check the tailnet policy tagOwners / the console Tags pane" >&2
        exit 1
      fi
      # Clear stale/conflicting Serve config (no-op when clean), then apply
      # each member's service on its own listener port.
      tailscale serve reset
    '' + serveApplyLines + "\n";
  }; };

  # The default patch layer, store-backed at /etc so every member's
  # service can copy it into their own ~/.dsh (seeded first start only —
  # see preStart above). One file serves all members: separation is in
  # the copies, not in this seed (desktop precedent: environment.etc,
  # hosts/desktop/monitor/monitor.nix — this pin dropped the bare
  # `etc` alias).
  environment.etc."dsh-family/cordis.patch.yml".text = familyPatch;

  # Tailnet traffic enters on tailscale0; the firewall trusts loopback
  # anyway, so open exactly the Serve listeners plus their cleartext
  # redirect partner (desktop pair: https=443 answers the 80 redirect —
  # for a later 8443 row re-verify the partner port from serve's journal
  # rather than assuming it). The dsh ports themselves stay loopback-only.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts =
    lib.unique ([ 80 ] ++ map (m: m.servePort) (lib.attrValues members));
}
