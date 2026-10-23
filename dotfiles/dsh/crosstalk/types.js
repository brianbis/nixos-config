/**
 * dsh-crosstalk — shared domain types.
 *
 * A session is a live DSH process participating in cross-session messaging. It
 * publishes one heartbeat JSON file under `<homeDir>/registry/<ref>.json` and
 * receives messages through its inbox directory
 * `<homeDir>/inbox/<ref>/`. Messages are one JSON file per message, written
 * atomically (temp file + rename) so a crash mid-write is never observed as a
 * partial message.
 *
 * @module @dsh-crosstalk/bundle/types
 */
export {};
//# sourceMappingURL=types.js.map
