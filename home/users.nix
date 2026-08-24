# Shared user identities for the human (b) and the LLM agent (llm), used by
# both the NixOS host config and the standalone agents-md doc build so the
# home directories have a single source of truth.
#
# The `llm` user owns the "system" jail variants' home (/home/llm): the
# system jails run as this user via `sudo -u llm` instead of as root, so the
# agent's worst case is "can write /etc/nixos + its own home", and its home
# is managed declaratively by home-manager (home/llm/agent-home.nix). The
# `llm` group (hosts/desktop/security.nix) is an extra group of the user
# (the primary group is `users`), and grants read access to the agenix
# secret and the systemd journal.
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