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
    # machine/security tooling
    tailscale
    sops
    age
  ];
}