{ ... }:

{
  programs.plasma = {
    enable = true;

    resetFilesExclude = [ "kwinrulesrc" ];

    shortcuts = {
      "services/org.kde.krunner.desktop" = {
        "_launch" = [ "Meta" "Alt+Space" ];
      };
      yakuake = {
        "toggle-window-state" = "Meta+R";
      };
      "services/org.kde.spectacle.desktop" = {
        "RecordRegion" = "none";
      };

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

      ksmserverrc = {
        General = {
          loginMode = "restorePreviousLogout";
        };
      };
    };

    window-rules = [
      # --- Hardcoded, exact-fraction tiling for the main three ---
      {
        description = "Discord - middle quarter";
        match.window-class = { value = "discord"; type = "substring"; };
        apply = {
          position = { value = "1280,0";      apply = "remember"; };
          size     = { value = "1280,1440"; apply = "remember"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "Obsidian - middle quarter";
        match.window-class = { value = "obsidian"; type = "substring"; };
        apply = {
          position = { value = "1280,0";      apply = "remember"; };
          size     = { value = "1280,1440"; apply = "remember"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "Konsole - left quarter half upper";
        match.window-class = { value = "konsole"; type = "substring"; };
        apply = {
          position = { value = "0,0";    apply = "force"; };
          size     = { value = "1280,720"; apply = "force"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "Firefox - right half";
        match.window-class = { value = "firefox"; type = "substring"; };
        apply = {
          position = { value = "2560,0";    apply = "remember"; };
          size     = { value = "2560,1440"; apply = "remember"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "VS Code - left quarter half lower";
        match.window-class = { value = "code"; type = "substring"; };
        apply = {
          position = { value = "0,720";     apply = "force"; };
          size     = { value = "1280,720"; apply = "force"; };
          desktop  = { value = "1";       apply = "remember"; };
          screen   = { value = "0";       apply = "remember"; };
        };
      }
    ];
  };
}