{
  # Allow userChrome.css customization
  "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

  # Allow fullscreen without widget restrictions
  "full-screen-api.ignore-widgets" = true;

  "browser.uiCustomization.state" = builtins.readFile ./toolbar-state.json;

  "extensions.autoDisableScopes" = 0;
  "extensions.enabledScopes" = 15;
}
