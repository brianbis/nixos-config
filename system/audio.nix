{ ... }:

{
  services.pulseaudio.enable = false;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;

    alsa.enable = true;
    alsa.support32Bit = true;

    pulse.enable = true;

    wireplumber.extraConfig = {
      "51-bluetooth-audio-policy" = {
        "monitor.bluez.rules" = [
          # Force all Bluetooth audio devices to A2DP only.
          # This disables HSP/HFP microphone mode.
          {
            matches = [
              {
                "device.name" = "~bluez_card.*";
              }
            ];

            actions.update-props = {
              "bluez5.auto-connect" = [ "a2dp_sink" ];
              "bluez5.profile" = "a2dp-sink";
            };
          }

          # Prefer Bluetooth headphones when connected.
          {
            matches = [
              {
                "node.name" = "~bluez_output.*";
              }
            ];

            actions.update-props = {
              "priority.session" = 2000;
            };
          }
        ];
      };

      "52-motu-output-policy" = {
        "monitor.alsa.rules" = [
          # Your actual speaker output.
          {
            matches = [
              {
                "node.name" =
                  "alsa_output.usb-MOTU_M4_M4AE15CAEJ-00.HiFi__Line1__sink";
              }
            ];

            actions.update-props = {
              # Bluetooth beats this, but this is the fallback.
              "priority.session" = 1100;
            };
          }

          # Avoid selecting the wrong MOTU output.
          {
            matches = [
              {
                "node.name" =
                  "alsa_output.usb-MOTU_M4_M4AE15CAEJ-00.HiFi__Line2__sink";
              }
            ];

            actions.update-props = {
              "priority.session" = 100;
            };
          }
        ];
      };
    };
  };
}