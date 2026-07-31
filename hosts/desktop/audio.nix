{ ... }:

{
  services.pulseaudio.enable = false;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;

    alsa.enable = true;
    alsa.support32Bit = true;

    pulse.enable = true;

    wireplumber = {
      enable = true;
      extraConfig = {
        "10-bluetooth-policy" = {
          "monitor.bluez.properties" = {
            "bluez5.enable-sbc-xq" = true;
            "bluez5.enable-msbc" = true;
            "bluez5.enable-hw-volume" = true;
            "bluez5.headset-roles" = [ "a2dp_sink" ];
            "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
            # Force WirePlumber to automatically connect A2DP sink on detect
            "bluez5.auto-connect" = [ "a2dp_sink" ];
          };

          "monitor.bluez.rules" = [
            # Force A2DP Sink mode and disable autoswitching to HSP/HFP (Microphone)
            {
              matches = [
                {
                  "device.name" = "~bluez_card.*";
                }
              ];
              actions = {
                update-props = {
                  "bluez5.profile" = "a2dp-sink";
                  "bluez5.autoswitch-to-headset-profile" = false;
                };
              };
            }
            # Give Bluetooth audio output priority over onboard audio sinks
            {
              matches = [
                {
                  "node.name" = "~bluez_output.*";
                }
              ];
              actions = {
                update-props = {
                  "priority.driver" = 2000;
                  "priority.session" = 2000;
                };
              };
            }
          ];
        };

        "52-motu-output-policy" = {
          "monitor.alsa.rules" = [
            # MOTU M4 Speaker Output (Fallback when headphones are disconnected)
            {
              matches = [
                {
                  "node.name" = "alsa_output.usb-MOTU_M4_M4AE15CAEJ-00.HiFi__Line1__sink";
                }
              ];
              actions = {
                update-props = {
                  "priority.driver" = 1100;
                  "priority.session" = 1100;
                };
              };
            }
            # Avoid selecting secondary MOTU channels
            {
              matches = [
                {
                  "node.name" = "alsa_output.usb-MOTU_M4_M4AE15CAEJ-00.HiFi__Line2__sink";
                }
              ];
              actions = {
                update-props = {
                  "priority.driver" = 100;
                  "priority.session" = 100;
                };
              };
            }
          ];
        };
      };
    };
  };
}