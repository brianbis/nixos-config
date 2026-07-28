{
  description = "b's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    discord-nixpkgs.url =
      "github:NixOS/nixpkgs/64a1fc0ed43e9f770f1401dd5d4dd57c12ca001a";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix.url = "github:Mic92/sops-nix";

    nur.url = "github:nix-community/NUR";
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, nur, discord-nixpkgs, ... }:
  {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        ./hardware-configuration.nix
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        { nixpkgs.overlays = [ nur.overlays.default ]; }
        {
          home-manager.useGlobalPkgs = true;
          home-manager.extraSpecialArgs = {
            inherit discord-nixpkgs;
          };
          home-manager.users.b = import ./home.nix;
        }
      ];

      specialArgs = {
        inherit nur;
      };
    };
  };
}