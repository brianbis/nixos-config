# zomboid/default.nix
# NixOS module entry point for the Project Zomboid dedicated server.
# The server module lives in server.nix; the collection->ini renderer lives
# in plugins.nix (imported by server.nix).
{
  imports = [
    ./server.nix
  ];
}
