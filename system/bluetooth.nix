{ pkgs, ... }:

{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.blueman.enable = false;

  systemd.services.bluetooth-trust-headphones = {
    description = "Trust Bluetooth headphones";

    after = [ "bluetooth.service" ];
    wants = [ "bluetooth.service" ];

    serviceConfig = {
      Type = "oneshot";

      ExecStart = ''
        ${pkgs.bluez}/bin/bluetoothctl trust A4:C6:F0:CB:F3:52
        ${pkgs.bluez}/bin/bluetoothctl trust 74:77:86:25:E5:18
      '';
    };
  };
}