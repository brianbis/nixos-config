{ lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio.nix
    ./bluetooth.nix
    ./boot.nix
    ./monitor
    ./networking.nix
    ./nvidia.nix
    ./packages.nix
    ./plasma.nix
    ./security.nix
    ./steam.nix
    ./vllm.nix
    ./llamacpp.nix
    ./ninfer
    ./host.nix
    ./hushmic
    ./caddy.nix
  ];
}
