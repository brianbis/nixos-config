{ lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio.nix
    ./anker-event-capture.nix
    ./bluetooth.nix
    ./librepods
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
    ./tether
  ];

  services.tether.enable = true;
  services.anker-event-capture.enable = true;
  # Temporary: capture everything (full firehose) for now. Flip back to
  # "events" (or delete this line) once the interesting window has passed.
  services.anker-event-capture.mode = "full";
}
