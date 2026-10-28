{ pkgs, inputs, ... }:

{
  imports = [ inputs.nix-craftapps.nixosModules.default ];

  # The ArtCraft Crafting Apps (storytold): all thirteen (figcraft arrived
  # upstream 2026-10-24), from upstream's prebuilt release tarballs. Each app
  # lands as two commands — the GUI (`photocraft`) plus a headless companion
  # (`photocraft-cli`) — and apps.json now also carries cli-only and
  # darwin sources, which enableAll picks up; nothing here lists apps by hand.
  # (`photocraft`) and a headless companion (`photocraft-cli`) — plus its
  # Plasma launcher entry and icons.
  #
  # linkFonts (on by default) is what the apps' text tools need: they read
  # /usr/share/fonts directly, with no fontconfig, and NixOS has no such
  # directory until fonts.fontDir.enable links it to the system fonts.
  # GPU: nothing here — the module must not touch hardware.* (nvidia.nix owns
  # the driver); the apps render through wgpu (Vulkan, then GLES via EGL).
  programs.craftapps = {
    enable = true;
    enableAll = true;
  };
}
