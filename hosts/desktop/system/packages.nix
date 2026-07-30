{ pkgs, inputs, ... }:

{
  environment.systemPackages = with pkgs; [
    inputs.agenix.packages.${pkgs.system}.default
    curl
    wget
    rsync
    mtr
    nmap
    tcpdump
    iperf3
    bind
    whois
    ffmpeg-full
    tailscale
    age
    gdb
    mangohud
    vulkan-tools
    kdePackages.yakuake
  ];
}