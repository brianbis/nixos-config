{ pkgs, inputs, ... }:
let
  my-python-packages =
    p: with p; [
      # Data / science
      numpy
      pandas
      scikit-learn
      matplotlib
      seaborn
    ];
in
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
    (python3.withPackages my-python-packages)
  ];
}