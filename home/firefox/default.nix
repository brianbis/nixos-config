{ pkgs, nur, ... }:

{
  programs.firefox = {
    enable = true;

    policies = {
      ExtensionSettings = {
        "{47400ad1-545d-449a-85f6-f9edfc7e590a}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/file/3492728/oled_borderless_pitch_black-1.2.xpi";
          installation_mode = "force_installed";
        };
      };
    };

    profiles.main = {
      extensions.packages =
        import ./addons.nix { inherit pkgs nur; };

      settings =
        import ./settings.nix;

      userChrome =
        builtins.readFile ./userChrome.css;
    };
  };
}