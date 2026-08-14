{ config, pkgs, ... }:

{
  # Sidra OLED theme
  xdg.configFile."Sidra/custom.css" = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/Sidra/custom.css";
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
