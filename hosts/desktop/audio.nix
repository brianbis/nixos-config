{ pkgs, ... }:

# Mic chain: MOTU M4 Mic1 -> hushmic (DPDFNet LADSPA filter-chain) ->
# virtual "hushmic" source. The hushmic service is pinned to cpu0-7
# (all the P-cores).
{
  services.pulseaudio.enable = false;

  security.rtkit.enable = true;

  # Limit shader compiler thread storms from Steam/Proton/Vulkan
  # to keep audio cores free.
  environment.sessionVariables = {
    MESA_MAX_SHADER_COMPILER_THREADS = "4";
    RADV_SHADER_CACHE = "1";
    DXVK_ASYNC = "1";
  };

  environment.systemPackages = with pkgs; [
    hushmic
  ];

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
            "bluez5.auto-connect" = [ "a2dp_sink" ];
          };

          "monitor.bluez.rules" = [
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

  # HushMic: DPDFNet noise suppression as a virtual mic, running in tray mode.
  # --tray starts the background filter-chain plus the KSNI system-tray daemon
  # (silent, no A/B window). The desktop entry provides a manual launch path
  # that opens the A/B window on first click; subsequent clicks forward to the
  # already-running instance via a show socket. Only one instance is allowed
  # per session (advisory flock); systemd ensures it starts at login.
  systemd.user.services.hushmic = {
    description = "HushMic real-time microphone noise suppression";
    wantedBy = [ "basic.target" ];
    after = [ "pipewire.service" ];
    wants = [ "pipewire.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.hushmic}/bin/hushmic --tray";
      Restart = "on-failure";
      RestartSec = 3;

      CPUAffinity = [ 0 1 2 3 4 5 6 7 ];
      Nice = -10;
      CPUWeight = 1000;
      OOMScoreAdjust = -1000;
    };
  };
}
