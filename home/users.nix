# Shared user identities for the human (b) and the LLM agent (llm), used by
# both the NixOS host config and the standalone agents-md doc build so the
# home directories have a single source of truth.
#
# The `llm` user runs the "system" jail variants via `sudo -u llm` (not root),
# so its worst case is "can write /etc/nixos + its own home"; its home is
# managed by home-manager. The `llm` group grants read access to the agenix secret and journal.
{
  b = {
    username = "b";
    homeDirectory = "/home/b";
  };

  llm = {
    username = "llm";
    homeDirectory = "/home/llm";
  };
}