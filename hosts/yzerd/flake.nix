{
  description = ''
    NixOS host 'yzerd' — the physical box (Option A: PVE retired, NixOS native).

    Self-contained sub-flake in the same shape as hosts/nixos-vm: the repo re-exports
    it through the path: input 'yz-native', and this directory alone evaluates
    standalone, which is what the live ISO needs — after nvme0n1p3 is wiped the ONLY
    copy of this tree is on the Ventoy stick (/mnt/vtoy/repo-yzerd), mounted by the
    installation system. Keep it dependency-light on that account: the root flake's
    inputs (sourcehut:, NUR, nix-craftapps) cannot be fetched from a fresh live
    environment, so this sub-flake pins nixpkgs by exact revision only.
  '';

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/f20cd90e28fe0403873f473b29e42662cd86e8c4";

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.yzerd = nixpkgs.lib.nixosSystem {
      # Bound literally (not config.system) so the flake evaluates standalone via
      # `nixos-rebuild --flake /mnt2/repo-yzerd#yzerd` on the live system.
      system = "x86_64-linux";
      modules = [ ./default.nix ];
    };
  };
}
