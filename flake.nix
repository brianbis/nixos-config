{
  description = "b's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nur.url = "github:nix-community/NUR";

    # Jailed LLM tooling
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    plasma-manager,
    agenix,
    nur,
    jail-nix,
    llm-agents,
    ...
  }@inputs:
  let
    system = "x86_64-linux";

    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [ nur.overlays.default ];
    };
  in
  {
    formatter.${system} =
      nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;

      modules = [
        ./hosts/desktop
        agenix.nixosModules.default
        home-manager.nixosModules.home-manager

        ({ config, ... }: {
          nixpkgs.config.allowUnfree = true;

          nixpkgs.overlays = [
            nur.overlays.default
          ];

          home-manager.useGlobalPkgs = true;

          home-manager.extraSpecialArgs = {
            inherit
              plasma-manager
              nur
              jail-nix
              llm-agents
              ;

            deepseekSecret = config.age.secrets.deepseek-api-key.path;
          };

          home-manager.users.b = import ./home;
        })
      ];

      specialArgs = {
        inherit
          nur
          inputs
          jail-nix
          llm-agents
          ;
      };
    };
  };
}