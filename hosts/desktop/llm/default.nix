{ lib, ... }:

{
  imports = [
    ./gate
    ./ninfer
    ./sglang
    ./vllm
    ./omarchy
    ./strata
  ];

  services.strata.enable = true;
}
