# home-manager module for the `llm` agent user — the home of the "system"
# jail variants, which run as this user via `sudo -u llm` (see
# home/llm/jails.nix). The tool configs are rendered by the shared agent-home
# module (./jail-home.nix) from the same catalog as b's home, so user and
# system configs stay identical in content.
#
# No home.packages: the `jc`/`jcs`/`dsh`/`dshs` wrappers live in b's profile
# and exec the jail store paths directly as llm; the jail itself provides its
# own PATH via bwrap. No user services: the headroom proxies run in b's
# session and are reachable from any user over loopback.
{ shared, ... }:

{
  imports = [ ./jail-home.nix ];

  home.stateVersion = "26.05";
}