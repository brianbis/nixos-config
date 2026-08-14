{ config, ... }:

{
  home.file."dotfiles".source = config.lib.file.mkOutOfStoreSymlink "/etc/nixos/dotfiles";
  xdg.configFile."Code/User/settings.json".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/vscode-settings.json";
}
