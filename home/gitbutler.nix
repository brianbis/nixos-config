{ ... }:

# GitButler (Tauri v2, nixpkgs `gitbutler`) ships its own `GitButler.desktop`
# with only `Keywords = git;`. Naming this entry `GitButler` makes home-manager
# write ~/.local/share/applications/GitButler.desktop, which takes precedence
# over the package's $out/share/applications/GitButler.desktop, so KRunner sees
# one entry with the fuller alias set below.
#
# The nixpkgs package builds the full GUI (Tauri frontend + Rust backend); its
# mainProgram is `gitbutler-tauri`, not `gitbutler`.
#
# GTK_THEME=Adwaita:dark (same load-bearing trick as Tether in default.nix):
# GitButler is a Tauri v2 / GTK4 app that draws its own titlebar (CSD) with a
# light theme and does not pick up ~/.config/gtk-4.0/gtk.css, so on a dark
# Plasma session the titlebar renders white. Forcing the dark Adwaita variant
# makes GTK use a dark titlebar directly.
{
  xdg.desktopEntries.GitButler = {
    name = "GitButler";
    exec = "env GTK_THEME=Adwaita:dark gitbutler-tauri";
    icon = "gitbutler-tauri";
    type = "Application";
    categories = [ "Development" ];
    comment = "Git client for simultaneous branches on top of your existing workflow";
    settings = {
      Keywords = "git;gitbutler;branch;virtual branches;pr;stacked";
      StartupWMClass = "GitButler";
    };
  };
}
