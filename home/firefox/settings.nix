{
  # Allow userChrome.css customization
  "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

  # Allow fullscreen without widget restrictions
  "full-screen-api.ignore-widgets" = true;
  "full-screen-api.warning.timeout" = 0;
  "browser.uiCustomization.state" = builtins.readFile ./toolbar-state.json;

  "extensions.autoDisableScopes" = 0;
  "extensions.enabledScopes" = 15;

  "extensions.activeThemeID" = "{b1638061-5a6b-49fd-8495-f03a0c989a57}";
  "extensions.activeTheme" = "{b1638061-5a6b-49fd-8495-f03a0c989a57}";

  # --- Bitwarden form-field fix ---
  # Firefox's native password manager & form-autofill overlay fights with
  # Bitwarden's own in-field icon/menu, causing the broken/duplicated
  # dropdown behavior. Disabling Firefox's built-ins leaves Bitwarden as
  # the sole form-fill handler.
  "signon.rememberSignons" = false;
  "signon.generation.enabled" = false;
  "browser.uidensity" = 1;
  "signon.autofillForms" = false;
  "browser.formfill.enable" = false;
  "extensions.formautofill.addresses.enabled" = false;
  "extensions.formautofill.creditCards.enabled" = false;
  "extensions.formautofill.heuristics.enabled" = false;
  "extensions.pocket.enabled" = false;
  "identity.fxaccounts.enabled" = false;
  "datareporting.healthreport.uploadEnabled" = false;
  "datareporting.policy.dataSubmissionEnabled" = false;
  "toolkit.telemetry.enabled" = false;
  "toolkit.telemetry.unified" = false;
  "toolkit.telemetry.archive.enabled" = false;
  "network.predictor.enabled" = false;
  "network.predictor.enable-prefetch" = false;
  accessibility.browsewithcaret_shortcut.enabled = false;
  # --- Always resume previous session on restart, no "Restore Session" prompt ---
  "browser.startup.page" = 3;
  "browser.sessionstore.max_resumed_crashes" = -1;
  dom.webserial.enabled = true;
}