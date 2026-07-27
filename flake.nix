{
  description = "b's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix.url = "github:Mic92/sops-nix";

    nur.url = "github:nix-community/NUR";
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, nur, ... }:
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
          home-manager.users.b = import ./home.nix;
        }
      ];

      specialArgs = {
        inherit nur;
      };
    };
  };
}