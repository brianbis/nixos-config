{ pkgs, ... }:

{
  "treestyletab@piro.sakura.ne.jp" = {
    force = true;

    settings = {
      "__ConfigsMigration__userValuesSameToDefaultAreCleared" = true;

      autoAttachOnOpenedWithOwner = 0;

      chunkedUserStyleRules0 = builtins.readFile (
        pkgs.runCommand "tree-style-tab-css-base64" {} ''
          base64 -w0 ${./tree_style_tab.css} > $out
        ''
      );

      configsVersion = 34;

      notifiedFeaturesVersion = 9;

      userStyleRules = null;
    };
  };
}