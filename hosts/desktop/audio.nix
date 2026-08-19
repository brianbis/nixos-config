{ pkgs, ... }:

# Mic chain: MOTU M4 Mic1 -> hushmic (DPDFNet LADSPA via its own PipeWire
# filter-chain) -> virtual "hushmic" source. The old DeepFilter filter-chain
# (99-deepfilter) is gone; hushmic fully supersedes it and owns the mic path.
#
# hushmic runs as a systemd USER service in headless mode (--enable-once: no
# tray, no window, just the audio pipeline until SIGTERM). It is pinned to
# cpu6/7 (the 5.8 GHz P-cores), which hushmic/scheduler.nix holds at
# performance governor + EPP permanently.
{
  services.pulseaudio.enable = false;

  security.rtkit.enable = true;

  # Limit shader compiler thread storms from Steam/Proton/Vulkan
  # to keep audio cores free.
  environment.sessionVariables = {
    MESA_MAX_SHADER_COMPILER_THREADS = "4";
    RADV_SHADER_CACHE = "1";
    # DXVK/VKD3D
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

  # Headless hushmic: DPDFNet noise suppression as a virtual mic.
  # --enable-once skips tray/window/sockets entirely and blocks until SIGTERM;
  # on exit it restores the previous default input and reaps its filter-chain.
  systemd.user.services.hushmic = {
    description = "HushMic real-time microphone noise suppression (headless)";
    wantedBy = [ "basic.target" ];
    after = [ "pipewire.service" ];
    wants = [ "pipewire.service" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.hushmic}/bin/hushmic --enable-once";
        Restart = "on-failure";
        RestartSec = 3;

        CPUAffinity = [ 6 7 ];
        Nice = -10;
        CPUWeight = 1000;
        OOMScoreAdjust = -1000;
      };
  };
}