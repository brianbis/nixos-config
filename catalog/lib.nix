# Derived views over ./default.nix (the fleet table). Pure functions of the
# data: no NixOS options, no shell. Two kinds of consumer:
#
#   home/llm/catalog.nix  takes `models` / `providerLabel` / the headroom
#                         exports, which keep the historical shapes so the
#                         per-tool renderers there are unchanged.
#   hosts/desktop/llm/gate  takes `rows` — the routing table the stub serves.
#
# Anything that reads a port or a model id should read it through here, never
# by hardcoding it.
lib: data:

let
  inherit (data) ports providers models gate;

  # Optional row fields carry their explicit absence once, so every view below
  # reads a plain attribute instead of re-defaulting at each use site.
  fleet =
    lib.mapAttrs
      (_: m: { hosted = false; relay = null; onDemand = false; preference = 0; vramMib = 0; } // m)
      models;

  urlOfPort = p: "http://127.0.0.1:${toString p}";

  # ── The public faces ──────────────────────────────────────────────────────
  gatePort = ports.gate;
  gateUrl = urlOfPort gatePort;

  # Where the gate forwards a request for this row: a headroom compression
  # front when the row names one, otherwise the engine's own port.
  relayPort = m: if m.relay != null then ports.${m.relay} else m.port;

  # ── Legacy export shapes ──────────────────────────────────────────────────
  # A row's `url` is what a tool sends requests to: the single gate face for
  # local models, the cloud headroom front for hosted ones. `relay` stays
  # internal (it is where the GATE forwards, not where the agent points).
  legacyModel = m:
    {
      providerName = m.provider;
      inherit (m) id name;
      # Every local row points at the one public face (the gate); the engine's
      # own port stays private plumbing that only the gate forwards to. A
      # hosted row points at its cloud headroom front.
      url =
        if m.hosted or false
        then urlOfPort m.port
        else gateUrl;
      inherit (m) context maxTok reason;
    }
    // lib.optionalAttrs (m ? attachments) { attachments = m.attachments; }
    // lib.optionalAttrs (m ? thinkingBudget) { thinkingBudget = m.thinkingBudget; }
    // lib.optionalAttrs (m ? reasoningEfforts) {
      reasoningEfforts = m.reasoningEfforts;
    }
    // lib.optionalAttrs (m ? cost) {
      costIn = m.cost.input;
      costOut = m.cost.output;
      costInCached = m.cost.inputCached;
      costOutCached = m.cost.outputCached;
    };

  legacyModels = lib.mapAttrs (_: legacyModel) fleet;

  providerLabel =
    lib.mapAttrs
      (_: p: {
        name = p.label;
        type = "openai-compat";
        api_key = "sk-local";
      })
      providers;

  # The headroom fronts, kept under their historical names because
  # home/llm/services.nix, agents-manifest.nix and the tool configs all read
  # them. `*UpstreamUrl` is what the front proxies to.
  headroomPort = ports.headroom;
  headroomProxyUrl = urlOfPort headroomPort;
  headroomUpstreamUrl = urlOfPort ports.llamacpp;
  headroomCloudPort = ports.headroomCloud;
  headroomCloudProxyUrl = urlOfPort headroomCloudPort;
  headroomCloudUpstreamUrl = "https://api.deepseek.com/v1";
  headroomClaudePort = ports.headroomClaude;
  headroomClaudeProxyUrl = urlOfPort headroomClaudePort;
  headroomClaudeUpstreamUrl = urlOfPort ports.llamacpp;
  headroomNinferPort = ports.headroomNinfer;
  headroomNinferProxyUrl = urlOfPort headroomNinferPort;
  # The gate fronts the engine, so this proxy upstreams the engine's own port.
  headroomNinferUpstreamUrl = urlOfPort ports.ninfer;
  headroomNvidiaPort = ports.headroomNvidia;
  headroomNvidiaProxyUrl = urlOfPort headroomNvidiaPort;
  headroomNvidiaUpstreamUrl = "https://integrate.api.nvidia.com/v1";

  # ── Views the gate and the renderers share ────────────────────────────────
  allModels = lib.attrValues fleet;
  localModels = lib.filter (m: ! m.hosted) allModels;
  hostedModels = lib.filter (m: m.hosted) allModels;

  # Provider groups in ledger order — the renderers iterate this instead of
  # listing provider names by hand.
  providerNames = lib.attrNames providers;

  # Several engines serve one served id (the Qwen3.8-27B artifact on four
  # engines). The gate resolves a request's `model` through this list,
  # highest `preference` first.
  byId = lib.groupBy (m: m.id) allModels;
  idRoutes = id: lib.sort (a: b: a.preference > b.preference) (byId.${id} or [ ]);

  # The stub's routing table: one row per model, every port already resolved to
  # an integer so the runtime file carries no names to chase.
  rows = map
    (m: {
      inherit (m) id name family;
      provider = m.provider;
      unit = m.unit;
      port = m.port;
      relay = relayPort m;
      hosted = m.hosted;
      onDemand = m.onDemand;
      preference = m.preference;
      context = m.context;
      maxTok = m.maxTok;
      vramMib = m.vramMib;
      canReason = m.reason;
      canAttach = m.attachments or false;
      efforts = builtins.attrNames (m.reasoningEfforts or { });
    })
    (lib.sort (a: b: a.id < b.id) allModels);

  defaultRow =
    let
      d = { hosted = false; relay = null; vramMib = 0; } // gate.default;
    in
    {
      inherit (d) id unit port;
      relay = relayPort d;
      inherit (d) hosted vramMib;
    };
in
{
  inherit
    ports
    providers
    models
    gate
    gatePort
    gateUrl
    legacyModels
    providerLabel
    providerNames
    headroomPort
    headroomProxyUrl
    headroomUpstreamUrl
    headroomCloudPort
    headroomCloudProxyUrl
    headroomCloudUpstreamUrl
    headroomClaudePort
    headroomClaudeProxyUrl
    headroomClaudeUpstreamUrl
    headroomNinferPort
    headroomNinferProxyUrl
    headroomNinferUpstreamUrl
    headroomNvidiaPort
    headroomNvidiaProxyUrl
    headroomNvidiaUpstreamUrl
    allModels
    localModels
    hostedModels
    byId
    idRoutes
    rows
    defaultRow
    ;
}
