# Archipelago meta-flake.
#
# Bundles the main Archipelago source + the PopTracker / apworld repos as
# nested inputs, so `nix flake update archipelago` re-pins them all in one
# shot. The top-level flake's `archipelago` input points here (not directly
# at github:ArchipelagoMW/Archipelago); the real repos live one level down.
#
# Every nested input tracks its upstream default branch (no hardcoded `ref`);
# the flake.lock records the locked rev for each. `nix flake update
# archipelago` re-pins the meta-flake AND all six nested inputs to their
# default-branch HEADs in a single command.
#
# Release-asset note: the apworld/mod artifacts split two ways. The ones that
# are plain zips of the (public) source tree — BalatroAP.zip (the client mod),
# the spire2 apworld, the Universal Tracker apworld — are BUILT from the pinned
# source (see zip-from-source.nix): `nix flake update archipelago` re-pins the
# source and the zips follow. The ones that are compiled or whose source is not
# published — balatro.apworld (Python source not public), the STS2 AP client
# (Archipelago.zip, a compiled .NET mod), and the PopTracker ELF (compiled C++)
# — are pinned as fixed-output fetchurl of the release asset (URL + sha256).
# balatroap-poptracker has no releases: the source tree IS the pack, so its
# module consumes the locked source directly.
{
  inputs = {
    # The main Archipelago source (launcher + in-repo apworlds + WebHost).
    # Built with the uv2nix environment (see ../uv/ + package.nix).
    src = {
      url = "github:ArchipelagoMW/Archipelago";
      flake = false;
    };

    # PopTracker (C++/meson tracker). Release assets are prebuilt PyInstaller
    # ELFs (poptracker_0-35-4_ubuntu-22-04-x86_64.tar.xz). Tracks the default
    # branch (master); the module resolves the newest release at build time.
    poptracker = {
      url = "github:black-sliver/PopTracker";
      flake = false;
    };

    # BalatroAP (client mod + balatro.apworld server world). Release assets:
    # balatro.apworld + BalatroAP.zip (the smods mod folder). Tracks the
    # default branch (main); the module resolves the newest release at build
    # time.
    balatroap = {
      url = "github:BurndiL/BalatroAP";
      flake = false;
    };

    # Slay-the-Spire-2-Archipelago (spire2.apworld + the AP client zip).
    # world/ holds the Python apworld source; the release carries the
    # prebuilt Archipelago.zip + spire2.apworld. Tracks the default branch
    # (main); the module resolves the newest release at build time.
    sts2 = {
      url = "github:dlueben1/Slay-the-Spire-2-Archipelago";
      flake = false;
    };

    # Universal Tracker (tracker.apworld from the FarisTheAncient fork's
    # Tracker_* releases; the ArchipelagoMW releases page does not carry
    # the Tracker releases). The fork's default branch is `tracker`; the
    # module resolves the newest release at build time.
    universal-tracker = {
      url = "github:FarisTheAncient/Archipelago";
      flake = false;
    };

    # BalatroAP PopTracker pack (the source tree IS the pack; installed into
    # the PopTracker packs dir). No releases — the module consumes the locked
    # source directly (tracks the default branch, master).
    balatroap-poptracker = {
      url = "github:graygooglitch/balatroap_poptracker";
      flake = false;
    };
  };

  outputs = { self, ... }: {
    # Expose the nested inputs so the top-level flake and the home-manager
    # modules can use them. The top-level flake reads
    # `inputs.archipelago.outputs.<system>.archipelagoInputs` (or, for
    # flakeless inputs, `inputs.archipelago.inputs.<name>`).
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
