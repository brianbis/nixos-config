{ ... }:

{
  programs.plasma = {
    enable = true;

    configFile = {
      kwinrc = {
        Windows = {
          FocusStealingPreventionLevel = 0;
        };
      };
    };
  };
}
