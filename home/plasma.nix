{ ... }:

{
  programs.plasma = {
    enable = true;

    shortcuts = {
      # 1. Bind standalone Meta, Meta+R, and Alt+Space directly to open KRunner
      "services/org.kde.krunner.desktop" = {
        "_launch" = [ "Meta" "Meta+R" "Alt+Space" ];
      };

      # 2. Unbind Spectacle's screen recording shortcut so it stops stealing Meta+R
      "services/org.kde.spectacle.desktop" = {
        "RecordRegion" = "none";
      };

      # 3. Prevent Kickoff from capturing Meta
      "plasmashell" = {
        "activate application launcher" = "none";
      };
    };

    configFile = {
      kwinrc = {
        Windows = {
          FocusStealingPreventionLevel = 0;
        };
      };
    };
  };
}