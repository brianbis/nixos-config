{ ... }:

{
  xdg.desktopEntries.spectacle = {
    name = "Spectacle";
    exec = "spectacle";
    icon = "spectacle";
    type = "Application";
    categories = ["Graphics" "Utility"];
    comment = "KDE Screenshot tool";
    settings = {
      Keywords = "sn;screenshot;screen capture;spectacle";
    };
  };
}
