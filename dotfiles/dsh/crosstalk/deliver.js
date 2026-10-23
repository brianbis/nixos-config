/**
 * The inbox watcher: polls this session's inbox directory and delivers each
 * message file into the live session as a labeled, wake-on-idle turn.
 *
 * Delivery semantics (deliberately Claude Code-style, best-effort):
 * - A message arrives as a clearly-labeled system-side turn
 *   (`[message from session <name> (<cwd>)]`) with a `crosstalk` source, so
 *   the append-only log records provenance and the UI renders a relay card.
 * - If the target agent is idle, `followup` wakes it for a turn; if it is
 *   mid-turn, the message is claimed at the next turn boundary.
 * - `list_agents` status is not a delivery promise: files are consumed only
 *   after a successful handoff, and a file that cannot be delivered yet is
 *   retried on later polls up to {@link InboxWatcher.maxAttempts}.
 *
 * @module @dsh-crosstalk/bundle/deliver
 */
import { readdirSync, renameSync } from "node:fs";
import { join } from "node:path";
import { readJsonFile } from "./atomic.js";
import {
  consumeMessageFile,
  parseMessageFile,
  toUserMessage,
} from "./message.js";
/**
 * Whether a glob pattern (with `*`, `**`, `?`) matches a path. `*` matches
 * within one path segment, `**` matches across segments, `?` matches one
 * character. A pattern without wildcards is matched literally.
 */
export function globMatch(pattern, value) {
  let re = "";
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === "*") {
      if (pattern[i + 1] === "*") {
        re += ".*";
        i++;
      } else {
        re += "[^/]*";
      }
    } else if (ch === "?") {
      re += ".";
    } else {
      re += ch.replace(/[.+^${}()|[\]\\]/g, "\\$&");
    }
  }
  try {
    return new RegExp(`^${re}$`).test(value);
  } catch {
    return false;
  }
}
/**
 * Whether an allowlist entry admits a sender. An entry containing a wildcard
 * or a path separator is a cwd glob; otherwise it matches the session name
 * exactly (or the cwd exactly, as a convenience).
 */
export function allowlistAllows(entries, sender) {
  for (const entry of entries) {
    const trimmed = entry.trim();
    if (trimmed === "") continue;
    if (
      trimmed.includes("*") ||
      trimmed.includes("?") ||
      trimmed.includes("/")
    ) {
      if (globMatch(trimmed, sender.cwd)) return true;
    } else if (trimmed === sender.name || trimmed === sender.cwd) {
      return true;
    }
  }
  return false;
}
/**
 * Run the trust policy over one inbound message: same-user acceptance (v0.1
 * fixed) and allowlist filtering. Returns `deliver` or a `drop` reason.
 */
export function decideDelivery(file, policy) {
  const senderUid = file.from.uid;
  const ownUid = policy.uid;
  if (senderUid !== undefined && ownUid !== undefined && senderUid !== ownUid) {
    return {
      kind: "drop",
      reason: `sender uid ${senderUid} != session uid ${ownUid} (same-user only)`,
    };
  }
  if (
    policy.mode === "allowlist" &&
    !allowlistAllows(policy.allowlist, file.from)
  ) {
    return {
      kind: "drop",
      reason: `session ${file.from.name} is not on the allowlist`,
    };
  }
  return { kind: "deliver" };
}
/**
 * Polls the inbox and hands each accepted message to a live agent via
 * `followup` (wake-on-idle, next-turn-boundary when busy).
 */
export class InboxWatcher {
  /**
   * How many polls a file may wait for a live agent before it is dropped with
   * a log line (best-effort delivery; the process may genuinely have no
   * session, e.g. a bare headless host).
   */
  maxAttempts;
  inboxDir;
  resolveAgents;
  policy;
  attempts = new Map();
  draining = false;
  log;
  constructor(inboxDir, resolveAgents, policy, options = {}) {
    this.inboxDir = inboxDir;
    this.resolveAgents = resolveAgents;
    this.policy = policy;
    this.maxAttempts = options.maxAttempts ?? 30;
    this.log = options.log ?? (() => {});
  }
  /** Scan the inbox once, delivering every accepted file. Reentrancy-safe. */
  drain() {
    if (this.draining) return;
    this.draining = true;
    try {
      let files;
      try {
        files = readdirSync(this.inboxDir);
      } catch {
        return; // no inbox yet
      }
      for (const file of files.sort()) {
        if (!file.endsWith(".json")) continue;
        if (
          file.endsWith(".tmp.json") ||
          file.endsWith(".dead") ||
          file.endsWith(".corrupt")
        )
          continue;
        this.deliverFile(join(this.inboxDir, file), file);
      }
    } finally {
      this.draining = false;
    }
  }
  deliverFile(path, basename) {
    const parsed = parseMessageFile(readJsonFile(path));
    if (parsed === undefined) {
      // Quarantine corrupt files so they stop blocking the inbox.
      try {
        renameSync(path, `${path}.corrupt`);
      } catch {
        // leave it; the next poll will try again
      }
      this.log(`dsh-crosstalk: dropped corrupt message file ${basename}`);
      return;
    }
    const decision = decideDelivery(parsed, this.policy);
    if (decision.kind === "drop") {
      consumeMessageFile(path);
      this.log(
        `dsh-crosstalk: dropped message ${parsed.id} from ${parsed.from.name}: ${decision.reason}`,
      );
      return;
    }
    const agents = this.resolveAgents();
    if (agents.length === 0) {
      const attempts = (this.attempts.get(parsed.id) ?? 0) + 1;
      this.attempts.set(parsed.id, attempts);
      if (attempts >= this.maxAttempts) {
        this.attempts.delete(parsed.id);
        consumeMessageFile(path);
        this.log(
          `dsh-crosstalk: dropped message ${parsed.id} from ${parsed.from.name}: no live agent after ${attempts} polls`,
        );
      }
      return; // keep the file; a session may appear
    }
    for (const agent of agents) {
      try {
        agent.followup(toUserMessage(parsed, this.policy.notifyUser));
      } catch (error) {
        this.log(
          `dsh-crosstalk: delivery to ${agent.id} failed: ${error instanceof Error ? error.message : String(error)}`,
        );
        return; // keep the file; retry next poll
      }
    }
    this.attempts.delete(parsed.id);
    consumeMessageFile(path);
  }
}
//# sourceMappingURL=deliver.js.map
