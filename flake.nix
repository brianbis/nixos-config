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
    discord-nixpkgs,
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

    jail = jail-nix.lib.init pkgs;

    commonPkgs = with pkgs; [
      bashInteractive
      curl
      wget
      jq
      git
      which
      ripgrep
      gnugrep
      gawkInteractive
      ps
      findutils
      gzip
      unzip
      gnutar
      diffutils
      strace
      openssl
      cfr
      tcpdump
      mitmproxy
      jdk21
      (python3.withPackages (ps: [
              ps.cryptography
              # add other python packages here if needed later
            ]))
    ];

    commonJailOptions = with jail.combinators; [
      network
      time-zone
      no-new-session
      mount-cwd
    ];

    makeJailedAider = { extraPkgs ? [ ] }:
        jail "jailed-aider"
          pkgs.aider-chat
          (with jail.combinators;
            commonJailOptions ++ [
              (readwrite (noescape "~/.config/aider"))
              (readwrite (noescape "~/.aider.conf.yml"))

              # Allow git repo access
              (readwrite (noescape "~/.gitconfig"))

              (add-pkg-deps commonPkgs)
              (add-pkg-deps extraPkgs)
            ]);

    makeJailedCrush = { extraPkgs ? [ ] }:
      jail "jailed-crush"
        llm-agents.packages.${system}.crush
        (with jail.combinators;
          commonJailOptions ++ [
            (readwrite (noescape "~/.config/crush"))
            (readwrite (noescape "~/.local/share/crush"))

            (add-pkg-deps commonPkgs)
            (add-pkg-deps extraPkgs)
          ]);

    makeJailedOpencode = { extraPkgs ? [ ] }:
      jail "jailed-opencode"
        llm-agents.packages.${system}.opencode
        (with jail.combinators;
          commonJailOptions ++ [
            (readwrite (noescape "~/.config/opencode"))
            (readwrite (noescape "~/.local/share/opencode"))
            (readwrite (noescape "~/.local/state/opencode"))

            (add-pkg-deps commonPkgs)
            (add-pkg-deps extraPkgs)
          ]);
  in
  {
    lib = {
      inherit makeJailedCrush makeJailedOpencode makeJailedAider;
    };

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
              discord-nixpkgs
              plasma-manager
              nur
              jail-nix
              llm-agents
              makeJailedCrush
              makeJailedOpencode
              makeJailedAider
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
          makeJailedCrush
          makeJailedOpencode
          makeJailedAider
          ;
      };
    };
  };
}