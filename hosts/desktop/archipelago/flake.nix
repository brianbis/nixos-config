# Archipelago meta-flake: bundles the Archipelago source + PopTracker / apworld
# repos as nested inputs so `nix flake update archipelago` re-pins them all.
# Every input tracks its upstream default branch (no hardcoded ref); the lock
# records each rev. Release artifacts split two ways: plain zips of public
# source are BUILT from the pinned source (zip-from-source.nix); compiled or
# non-public artifacts (balatro.apworld, the STS2 .NET client, the PopTracker
# ELF) are pinned as fixed-output fetchurl of the release asset.
{
  inputs = {
    # Main Archipelago source; built with the uv2nix environment (../uv/ + package.nix).
    src = {
      url = "github:ArchipelagoMW/Archipelago";
      flake = false;
    };

    # PopTracker (C++/meson tracker); release assets are prebuilt PyInstaller ELFs.
    poptracker = {
      url = "github:black-sliver/PopTracker";
      flake = false;
    };

    # BalatroAP (client mod + balatro.apworld); release carries balatro.apworld + BalatroAP.zip.
    balatroap = {
      url = "github:BurndiL/BalatroAP";
      flake = false;
    };

    # Slay-the-Spire-2-Archipelago; world/ holds the Python apworld source, the
    # release carries the prebuilt Archipelago.zip + spire2.apworld.
    sts2 = {
      url = "github:dlueben1/Slay-the-Spire-2-Archipelago";
      flake = false;
    };

    # Universal Tracker: tracker.apworld comes from the FarisTheAncient fork's
    # Tracker_* releases (the upstream releases page lacks them); default branch is `tracker`.
    universal-tracker = {
      url = "github:FarisTheAncient/Archipelago";
      flake = false;
    };

    # BalatroAP PopTracker pack; no releases, the source tree IS the pack.
    balatroap-poptracker = {
      url = "github:graygooglitch/balatroap_poptracker";
      flake = false;
    };
  };

  outputs = { self, ... }: {
    # Exposed so the top-level flake / home modules can use the nested inputs.
    archipelagoInputs = {
      src = self.inputs.src;
      poptracker = self.inputs.poptracker;
      balatroap = self.inputs.balatroap;
      sts2 = self.inputs.sts2;
      universal-tracker = self.inputs.universal-tracker;
      balatroap-poptracker = self.inputs.balatroap-poptracker;
    };
  };
}
