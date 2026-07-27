{ pkgs, ... }:
{
  packages = with pkgs.nur.repos.rycee.firefox-addons; [
    sponsorblock
    ublock-origin
    bitwarden
    darkreader
    amp2html
    tampermonkey
    reddit-enhancement-suite
    old-reddit-redirect
    betterttv
    tree-style-tab
  ];
}