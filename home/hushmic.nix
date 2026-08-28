{ ... }:

{
  xdg.desktopEntries.hushmic = {
    name = "HushMic";
    exec = "hushmic";
    icon = "hushmic";
    type = "Application";
    categories = [ "AudioVideo" "Audio" ];
    comment = "Real-time microphone noise suppression";
    settings = {
      Keywords = "noise-suppression;microphone;dpdfnet;audio-filter";
    };
  };
}
