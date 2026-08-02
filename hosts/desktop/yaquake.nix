{ config, pkgs, lib, ... }:

{
  environment.systemPackages = [
    pkgs.yakuake
  ];
}