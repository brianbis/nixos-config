{ config, pkgs, ... }:

{
  # Sidra 1.1.x replaced the raw-CSS custom theme (custom.css) with a JSON
  # colour-scheme that it reads from its userData dir (~/.config/Sidra/). The
  # 12-slot scheme below recreates the previous OLED low-contrast look: pure
  # black backgrounds and a mid-gray (~#8a8a8a) text/accent ramp. `light` is
  # omitted so the black scheme is used under both colour schemes (OLED).
  xdg.configFile."Sidra/custom-theme.json" = {
    text = ''
      {
        "dark": {
          "base": "#000000",
          "mantle": "#000000",
          "crust": "#000000",
          "surface0": "#000000",
          "surface1": "#000000",
          "surface2": "#8a8a8a",
          "overlay": "#8a8a8a",
          "text": "#a2a2a2",
          "subtext1": "#c1c1c1",
          "subtext0": "#6a6a6a",
          "accent": "#8a8a8a",
          "accentHover": "#8a8a8a"
        }
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
    categories = [ "AudioVideo" "Audio" "Music" "Player" ];
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
