{ pkgs, ... }:

let
  black-oled = pkgs.nur.repos.rycee.firefox-addons.buildFirefoxXpiAddon {
    pname = "black-oled";
    version = "1.2";
    addonId = "{b1638061-5a6b-49fd-8495-f03a0c989a57}";
    url = "https://addons.mozilla.org/firefox/downloads/file/3492728/oled_borderless_pitch_black-1.2.xpi";
    sha256 = "sha256-rkr8hBFkbjjl3L+UDDa+vLwO3LQquGC+B7ThEXdemIw=";

    meta = {
      homepage = "https://addons.mozilla.org/en-US/firefox/addon/black-oled/";
      description = "Black (OLED) Firefox theme";
    };
  };
in
(with pkgs.nur.repos.rycee.firefox-addons; [
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
]) ++ [
  black-oled
]