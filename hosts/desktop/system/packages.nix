{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # system/network administration
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
    # security tooling
    tailscale
    sops
    age
    gdb
    mangohud
    vulkan-tools
    kdePackages.yakuake
  ];
}