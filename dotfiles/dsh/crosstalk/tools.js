/**
 * The decorated `list_agents` / `send_message` tools — extend, don't
 * duplicate. The stock definitions (registered by the subagent-control preset
 * rows) stay registered; this plugin registers per-agent shadows that add the
 * `peers` / `all` scopes and peer addressing, and delegate every stock scope
 * back to the captured stock definitions. Registrations are reversible Cordis
 * effects: unloading (or the agent's disposal) removes the shadow and restores
 * stock behavior exactly.
 *
 * @module @dsh-crosstalk/bundle/tools
 */
const peerSchema = {
  type: "object",
  additionalProperties: false,
  required: ["kind", "name", "ref", "status", "cwd", "lastActivity"],
  properties: {
    kind: { type: "string", enum: ["peer"] },
    name: { type: "string" },
    ref: { type: "string" },
    status: { type: "string", enum: ["running", "idle", "ready"] },
    cwd: { type: "string" },
    lastActivity: { type: "number" },
  },
};
const childSchema = {
  type: "object",
  additionalProperties: false,
  required: ["kind", "id", "label", "status"],
  properties: {
    kind: { type: "string", enum: ["child"] },
    id: { type: "string" },
    label: { type: "string" },
    status: { type: "string", enum: ["running", "idle", "ready"] },
    parent: { type: "string" },
    depth: { type: "number" },
  },
};
const diagnosticSchema = {
  type: "object",
  additionalProperties: false,
  required: ["kind", "id", "reason"],
  properties: {
    kind: { type: "string", enum: ["diagnostic"] },
    id: { type: "string" },
    reason: { type: "string", enum: ["corrupt", "unsupported", "unavailable"] },
    parent: { type: "string" },
    depth: { type: "number" },
  },
};
/** Project one registry peer onto the model-facing `list_agents` row. */
export function projectPeer(peer) {
  return {
    kind: "peer",
    name: peer.name,
    ref: peer.ref,
    status: peer.status,
    cwd: peer.cwd,
    lastActivity: peer.heartbeatAt,
  };
}
/** Render one peer row as a text line. */
export function renderPeerRow(row) {
  return `${row.name} [${row.status}] — ${row.cwd}`;
}
function isRecord(value) {
  return typeof value === "object" && value !== null;
}
function isListAgentsScope(value) {
  return (
    value === "children" ||
    value === "descendants" ||
    value === "peers" ||
    value === "all"
  );
}
function parseListArgs(args) {
  if (!isRecord(args)) return {};
  const scope = args.scope;
  if (scope === undefined) return {};
  if (!isListAgentsScope(scope))
    throw new Error(
      "list_agents: scope must be children, descendants, peers, or all",
    );
  return { scope };
}
function parseSendArgs(args) {
  if (
    !isRecord(args) ||
    typeof args.to !== "string" ||
    typeof args.message !== "string"
  ) {
    throw new Error("send_message: to and message must be strings");
  }
  if (args.summary !== undefined && typeof args.summary !== "string") {
    throw new Error("send_message: summary must be a string when provided");
  }
  return {
    to: args.to,
    message: args.message,
    ...(args.summary === undefined ? {} : { summary: args.summary }),
  };
}
/**
 * Build the decorated `list_agents` definition for one agent. `stock` is the
 * definition that agent currently sees (usually the subagent-control one);
 * when absent, the stock scopes fail with a clear error instead of silently
 * returning nothing.
 */
export function buildListAgents(service, stock) {
  return {
    name: "list_agents",
    description:
      "List the agents and sessions you can address. Scope `children` lists your direct background " +
      "subagents; `descendants` walks the whole tree below you (depth-1 entries are send_message candidates, " +
      "deeper ones interrupt_agent-only); `peers` lists the other live DSH sessions on this machine " +
      "(dsh-crosstalk) with their name, status, cwd and last activity; `all` combines descendants with peers. " +
      "Peers are addressed in send_message by name or ref. The snapshot is not a delivery promise — send_message " +
      "performs the authoritative check and may still fail.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        scope: {
          type: "string",
          enum: ["children", "descendants", "peers", "all"],
          description:
            "children (default) lists direct children; descendants walks the tree below you; peers lists other live sessions on this machine; all combines descendants with peers.",
        },
      },
    },
    output: {
      schema: {
        type: "array",
        items: {
          oneOf: [childSchema, diagnosticSchema, peerSchema],
        },
      },
      render: (rawArgs, value) => {
        const { scope = "children" } = parseListArgs(rawArgs);
        if (scope === "peers") {
          const rows = value;
          return [
            {
              type: "text",
              text:
                rows.length === 0
                  ? "(no peer sessions)"
                  : rows.map(renderPeerRow).join("\n"),
            },
          ];
        }
        if (scope === "all") {
          const rows = value;
          const lines = rows.map((row) => {
            if (row.kind === "peer")
              return `${row.name} [${row.status}] — ${row.cwd}`;
            const at =
              row.parent !== undefined
                ? ` parent=${String(row.parent)} depth=${String(row.depth)}`
                : "";
            return row.kind === "diagnostic"
              ? `${row.id} [diagnostic: ${row.reason}]${at}`
              : `${row.id} [${row.status}]${at} — ${row.label}`;
          });
          return [
            {
              type: "text",
              text: lines.length === 0 ? "(nothing to list)" : lines.join("\n"),
            },
          ];
        }
        // children / descendants: reuse the stock renderer when present.
        if (stock !== undefined) return stock.output.render({ scope }, value);
        return [
          {
            type: "text",
            text: "(subagent listing unavailable: dsh-tool-subagent-control is not installed)",
          },
        ];
      },
    },
    async execute(rawArgs, exec) {
      const { scope = "children" } = parseListArgs(rawArgs);
      if (scope === "peers") {
        return service.peers().map(projectPeer);
      }
      if (scope === "all") {
        const descendants =
          stock === undefined
            ? []
            : await stock.execute({ scope: "descendants" }, exec);
        return [...descendants, ...service.peers().map(projectPeer)];
      }
      if (stock === undefined) {
        throw new Error(
          "list_agents: children/descendants require the stock subagent tooling (dsh-tool-subagent-control), which is not installed",
        );
      }
      return await stock.execute({ scope }, exec);
    },
  };
}
/**
 * Build the decorated `send_message` definition for one agent. Peer names and
 * refs are resolved through the crosstalk service; anything else falls back to
 * the captured stock definition (subagent follow-ups).
 */
export function buildSendMessage(service, stock) {
  return {
    name: "send_message",
    description:
      "Send a message to a background subagent by its subagent id (continuing the same conversation), or to " +
      "another live DSH session on this machine by peer name or ref (from list_agents peers, dsh-crosstalk). For " +
      "peers the message is delivered as a clearly-labeled turn in the target session — if it is idle it wakes " +
      "for a turn, if mid-turn it arrives at the next turn boundary, and delivery is best-effort. The sender's " +
      "name rides along, so replying is just send_message back. A failure means the message was NOT delivered.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["to", "message"],
      properties: {
        to: {
          type: "string",
          description:
            "Subagent id (from subagent/list_agents), or a peer session name/ref (from list_agents peers).",
        },
        message: {
          type: "string",
          description: "The message to deliver.",
        },
        summary: {
          type: "string",
          description:
            "Optional 5-10 word recap shown in the target session UI.",
        },
      },
    },
    output: {
      schema: {
        type: "object",
        additionalProperties: false,
        required: ["messageId"],
        properties: {
          messageId: { type: "string" },
        },
      },
      render: (rawArgs) => {
        const to =
          isRecord(rawArgs) && typeof rawArgs.to === "string"
            ? rawArgs.to
            : "(unknown target)";
        return [
          {
            type: "text",
            text: `message queued for ${to}`,
          },
        ];
      },
    },
    async execute(rawArgs, exec) {
      const args = parseSendArgs(rawArgs);
      const resolution = service.resolve(args.to);
      if (resolution.kind === "live") {
        const { messageId } = await service.send(args.to, {
          text: args.message,
          summary: args.summary,
        });
        return { messageId };
      }
      if (resolution.kind === "stale") {
        throw new Error(
          `send_message: session ${args.to} is not currently live (last seen ${new Date(resolution.peer.heartbeatAt).toISOString()}); ` +
            "run list_agents peers for live sessions",
        );
      }
      if (stock === undefined) {
        throw new Error(
          `send_message: no peer session named "${args.to}" and the stock subagent tooling is not installed`,
        );
      }
      return await stock.execute(
        { subagent_id: args.to, message: args.message },
        exec,
      );
    },
  };
}
/**
 * Decorate every live agent (and every future one) with the extended tools.
 * @returns the disposer that unregisters the shadows and the listener,
 *   restoring stock behavior.
 */
export function applyToolDecoration(ctx, service) {
  const disposers = new Set();
  const decorate = (agent) => {
    // The agent object is the dsh-scope key used by DSH's own prompt assembly.
    const listStock = agent.ctx.tools.get("list_agents", agent);
    const sendStock = agent.ctx.tools.get("send_message", agent);
    let listDisposer;
    let sendDisposer;
    try {
      listDisposer = agent.ctx.tools.register(
        buildListAgents(service, listStock),
      );
      sendDisposer = agent.ctx.tools.register(
        buildSendMessage(service, sendStock),
      );
    } catch (error) {
      // A shadow that fails to register must not take the agent down; the
      // stock tools remain in place.
      ctx
        .logger("crosstalk")
        .warn(
          `tool decoration for agent ${agent.id} failed: ${error instanceof Error ? error.message : String(error)}`,
        );
      return;
    }
    disposers.add(listDisposer);
    disposers.add(sendDisposer);
  };
  for (const agent of ctx.agents.list()) decorate(agent);
  const off = ctx.on("agent/created", ({ agent }) => decorate(agent));
  return () => {
    off();
    for (const dispose of [...disposers]) {
      try {
        dispose();
      } catch {
        // already disposed
      }
    }
    disposers.clear();
  };
}
//# sourceMappingURL=tools.js.map
