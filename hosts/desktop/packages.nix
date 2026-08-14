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
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
    kdePackages.konsole
    # X11 compatibility layer (spawned automatically when found in
    # PATH). Needed for X11 apps like Discord and Yakuake.
    xwayland-satellite
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