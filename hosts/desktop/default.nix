{ lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio.nix
    ./anker-event-capture.nix
    ./bluetooth.nix
    #./librepods
    ./boot.nix
    ./monitor
    ./networking.nix
    ./nvidia.nix
    ./packages.nix
    ./plasma.nix
    ./security.nix
    ./steam.nix
    ./llm
    ./host.nix
    ./hushmic
    ./caddy.nix
    ./dsh-web.nix
    ./dsh-open.nix
    ./searxng.nix
    #./zomboid
    # Tether (Linux + iPhone Continuity bridge): upstream programs.tether
    # module — bluetooth class-of-device service, avahi/mDNS publishing,
    # firewall port. The Firefox extension + native-messaging manifest are
    # wired home-manager-side (home/firefox/firefox.nix): this module's
    # extensions option targets nixpkgs' programs.firefox, which is not the
    # browser in use here.
    inputs.tether.nixosModules.default
  ];

  programs.tether = {
    enable = true;
    package = inputs.tether.packages.${pkgs.system}.default;
    wifi.enable = true;
    wifi.openFirewall = true;
    bluetooth.enable = true;
    # adapters defaults to [ "hci0" ].
  };
  services.anker-event-capture.enable = true;
  # Temporary: capture everything (full firehose) for now. Flip back to
  # "events" (or delete this line) once the interesting window has passed.
  services.anker-event-capture.mode = "full";
}
