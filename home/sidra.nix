{ config, pkgs, ... }:

{
  # Sidra OLED theme
  xdg.configFile."Sidra/custom.css" = {
    text = ''
/* Sidra OLED low-contrast theme – pure black #000000 background */
:root {
  --pageBG: #000000 !important;
  --pageBG-rgb: 0,0,0 !important;
  --opaqueShelfBG: #000000 !important;
  --fallbackMaterialBG: #000000 !important;
  --shelfBG: rgba(0,0,0,0.15) !important;
  --genericJoeColor: #000000 !important;

  --systemPrimary: #8a8a8a !important;
  --systemPrimary-vibrant: #8a8a8a !important;
  --systemSecondary: #6a6a6a !important;
  --systemSecondary-vibrant: #6a6a6a !important;
  --systemTertiary: #6a6a6a !important;
  --systemQuaternary: #5a5a5a !important;
  --systemQuinary: #5a5a5a !important;

  --labelDivider: rgba(138,138,138,0.08) !important;
  --vibrantDivider: rgba(138,138,138,0.12) !important;

  --playerBackground: rgba(0,0,0,0.88) !important;
  --playerBackgroundFallback: #000000 !important;
  --playerLCDBGFill: #000000 !important;
  --playerMissingArtworkBg: #000000 !important;
  --playerMissingArtworkIcon: #8a8a8a !important;
  --playerScrubberFill: #8a8a8a !important;
  --playerScrubberTrack: rgba(138,138,138,0.2) !important;
  --playerPlatterButtonBGFill: #8a8a8a !important;
  --playerPlatterButtonIconFill: #000000 !important;
  --playerDropShadow2: rgba(0,0,0,0.1) !important;

  --segmentedControlBG: rgba(0,0,0,0.2) !important;
  --segmentedControlSelectedBG: #8a8a8a !important;

  --tracklistHoverColor: rgba(138,138,138,0.08) !important;
  --tracklistAltRowColor: rgba(0,0,0,0.03) !important;

  --systemStandardThickMaterialSover: rgba(0,0,0,0.72) !important;
  --systemHeaderMaterialSover: rgba(0,0,0,0.8) !important;
  --systemToolbarTitlebarMaterialSover: rgba(0,0,0,0.8) !important;

  --keyColor: #8a8a8a !important;
  --keyColor-rgb: 138,138,138 !important;
  --keyColor-rollover: #8a8a8a !important;
  --keyColor-pressed: #8a8a8a !important;
  --keyColor-deepPressed: #8a8a8a !important;
  --keyColor-disabled: rgba(138,138,138,0.35) !important;
  --musicKeyColor: #8a8a8a !important;
  --musicBrandBG: #8a8a8a !important;
  --selectionColor: #8a8a8a !important;
  --chromePlayerBGFill: rgba(0,0,0,0.88) !important;
  --lcd-bg-color: #000000 !important;
}

* {
  scrollbar-color: #8a8a8a #000000 !important;
}

.chrome-player::before {
  background-color: rgba(0,0,0,0.88) !important;
  background-image: none !important;
}

.side-panel {
  background-color: rgba(0,0,0,0.97) !important;
}

:is(footer, .scrollable-page footer) {
  background: #000000 !important;
  background-color: #000000 !important;
  border-color: rgba(138,138,138,0.12) !important;
  color: #8a8a8a !important;
}

html, body {
  background: #000000 !important;
  color: #8a8a8a !important;
}
  '';
    force = true;
  };

  xdg.configFile."Sidra/config.json" = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.local/share/sidra/config.json";
    force = true;
  };

  xdg.desktopEntries.sidra = {
    name = "Sidra";
    exec = "sidra";
    icon = "sidra";
    type = "Application";
    categories = ["AudioVideo" "Audio" "Music" "Player"];
    comment = "Apple Music desktop client";
    settings = {
      Keywords = "apple;itunes;apple music;music";
    };
  };

  home.activation.sidraConfig = ''
    mkdir -p "$HOME/.local/share/sidra"
    if [ ! -f "$HOME/.local/share/sidra/config.json" ]; then
      echo '{"theme":"custom"}' > "$HOME/.local/share/sidra/config.json"
    fi
  '';
}