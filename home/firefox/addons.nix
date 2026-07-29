{ pkgs, nur, ... }:

let
  firefox-addons = nur.legacyPackages.${pkgs.system}.repos.rycee.firefox-addons;

  black-oled = firefox-addons.buildFirefoxXpiAddon {
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
(with firefox-addons; [
  sponsorblock
  ublock-origin
  bitwarden
  darkreader
  amp2html
  reddit-enhancement-suite
  old-reddit-redirect
  tree-style-tab
]) ++ [
  black-oled
]