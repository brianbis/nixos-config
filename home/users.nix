# Shared user identity for b, used by both the NixOS host config and the
# standalone agents-md doc build so the home directory has a single source
# of truth.
{
  b = {
    username = "b";
    homeDirectory = "/home/b";
  };
}