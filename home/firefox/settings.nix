{
  # Allow userChrome.css customization
  "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

  # Allow fullscreen without widget restrictions
  "full-screen-api.ignore-widgets" = true;

  "browser.uiCustomization.state" = builtins.readFile ./toolbar-state.json;

  "extensions.autoDisableScopes" = 0;
  "extensions.enabledScopes" = 15;

  "extensions.activeThemeID" = "{b1638061-5a6b-49fd-8495-f03a0c989a57}";
  "extensions.activeTheme" = "{b1638061-5a6b-49fd-8495-f03a0c989a57}";
}
