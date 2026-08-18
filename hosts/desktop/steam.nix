{ ... }:

# CPU governor + EPP is owned by hushmic-cpu-boost (audio-cpu-watcher), see
# hushmic-scheduler.nix. That watcher already matches the Steam predicate, so
# there is no second governor writer here; the previous steam-gaming-mode
# service raced hushmic-cpu-boost and made the governor flap. GameMode still
# applies per-process tuning for games.
{
  programs.steam.enable = true;

  programs.gamemode = {
    enable = true;
    settings = {
      general.renice = 10;
    };
  };
}