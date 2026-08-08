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
    inputs.noctalia.packages.${pkgs.system}.default
    kdePackages.konsole
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