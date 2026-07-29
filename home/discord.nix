{ pkgs, discord-nixpkgs, ... }:
let
  discordPkgs = import discord-nixpkgs {
    system = pkgs.system;
    config.allowUnfree = true;
  };
  discordUnwrapped = discordPkgs.discord.override {
    withOpenASAR = true;
  };
  discord = pkgs.writeShellScriptBin "discord" ''
    cd /
    exec ${discordUnwrapped}/bin/Discord "$@"
  '';
in
{
  home.packages = [
    discord
  ];
  xdg.desktopEntries.discord = {
    name = "Discord";
    exec = "discord";
    icon = "discord";
    terminal = false;
    categories = [ "Network" "InstantMessaging" ];
  };
}