{ pkgs, ... }:

{
  programs.firefox = {
    enable = true;

    profiles.main = {
      extensions = {
        packages =
          import ./addons.nix { inherit pkgs; };

        settings =
          import ./tree_style_tab.nix { inherit pkgs; };
      };

      settings =
        import ./settings.nix;

      userChrome =
        builtins.readFile ./userChrome.css;

      bookmarks = {
        force = true;
        settings = [
          {
            name = "Subreddit shortcut";
            keyword = "r";
            url = "https://old.reddit.com/r/%s";
          }
        ];
      };
    };
  };
}
