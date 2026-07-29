{ ... }:

{
  services.pulseaudio.enable = false;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.pipewire.wireplumber.extraConfig = {
    "51-airpods-no-mic" = {
      "monitor.bluez.rules" = [
        {
          matches = [
            {
              "device.name" = "~bluez_card.*";
            }
          ];

          actions = {
            "update-props" = {
              "bluez5.auto-connect" = [ "a2dp_sink" ];
              "bluez5.profile" = "a2dp-sink";
            };
          };
        }
      ];
    };
  };
}