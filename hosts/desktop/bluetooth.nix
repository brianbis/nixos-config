{ pkgs, ... }:

{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;

    settings = {
      General = {
        # Force BlueZ to use Classic Bluetooth (BR/EDR) only for audio devices.
        # This prevents BlueZ from getting confused by AirPods BLE "Find My" addresses.
        ControllerMode = "bredr";
        
        Experimental = true;
        FastConnectable = true;
        JustWorksRepairing = "always";
      };

      Policy = {
        # Auto-enable adapter and attempt reconnection for trusted devices
        AutoEnable = true;
      };
    };
  };

  services.blueman.enable = false;

  systemd.services.bluetooth-agent = {
    description = "Bluetooth auto authorize agent";
    wantedBy = [ "bluetooth.target" ];
    after = [ "bluetooth.service" ];

    serviceConfig = {
      ExecStart = "${pkgs.bluez}/bin/bluetoothctl agent NoInputNoOutput";
      Restart = "always";
    };
  };

  systemd.services.bluetooth-trust-headphones = {
    description = "Trust AirPods & Bluetooth Headphones";
    after = [ "bluetooth.service" ];
    wants = [ "bluetooth.service" ];
    wantedBy = [ "bluetooth.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = ''
        ${pkgs.bash}/bin/bash -c '\
          ${pkgs.bluez}/bin/bluetoothctl trust A4:C6:F0:CB:F3:52 || true; \
          ${pkgs.bluez}/bin/bluetoothctl trust 74:77:86:25:E5:18 || true \
        '
      '';
    };
  };
}