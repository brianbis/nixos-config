{ pkgs, ... }:

let
  firefox-addons = pkgs.nur.repos.rycee.firefox-addons;

  oled-borderless-pitch-black =
    firefox-addons.buildFirefoxXpiAddon {
      pname = "oled-borderless-pitch-black";
      version = "1.2";
      addonId = "oled-borderless-pitch-black@mozilla.org";
      url = "https://addons.mozilla.org/firefox/downloads/file/3492728/oled_borderless_pitch_black-1.2.xpi";
      sha256 = "sha256-rkr8hBFkbjjl3L+UDDa+vLwO3LQquGC+B7ThEXdemIw=";

      meta = {
        homepage = "https://addons.mozilla.org/en-US/firefox/addon/oled-borderless-pitch-black/";
        description = "OLED Borderless Pitch Black Firefox theme";
      };
    };
in
with firefox-addons; [
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

  oled-borderless-pitch-black
]