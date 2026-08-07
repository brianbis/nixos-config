# /etc/nixos/home/firefox/default.nix
{ pkgs, ... }:

{
  home.file.".config/crush/.keep".text = "";
  home.file.".local/share/crush/.keep".text = "";

  home.file.".config/opencode/.keep".text = "";
  home.file.".local/share/opencode/.keep".text = "";
  home.file.".local/state/opencode/.keep".text = "";
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

      # /r/subreddit -> jumps straight to the subreddit
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