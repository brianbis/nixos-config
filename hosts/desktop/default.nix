{ lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio.nix
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
  ];
}
