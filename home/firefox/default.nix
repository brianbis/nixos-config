{ pkgs, nur, ... }:

{
  programs.firefox = {
    enable = true;

    profiles.main = {
      extensions = {
        packages =
          import ./addons.nix { inherit pkgs nur; };

        settings =
          import ./tree_style_tab.nix { inherit pkgs; };
      };

      settings =
        import ./settings.nix;

      userChrome =
        builtins.readFile ./userChrome.css;
    };
  };
}