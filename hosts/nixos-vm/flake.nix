{
  description = "NixOS host 'nixos-vm' — the Proxmox VE 9 guest (vmid 100 on node yzerd). Self-contained sub-flake: the repo re-exports it through the path: input 'nixos-vm', and this machine's own /etc/nixos is a byte-identical copy of this directory.";

  inputs = {
    # Exact revision, not the nixpkgs-unstable branch, and the SAME revision the
    # repo's flake.lock resolves for nixpkgs (narHash sha256-EjZqHKObBfIOeHZnMRVV87HB3pPq/WBkmRJWyFxmZu8=).
    # Both machines therefore build against one identical package set, and
    # `nix flake update nixpkgs` inside this sub-flake can never drift the VM.
    nixpkgs.url = "github:NixOS/nixpkgs/f20cd90e28fe0403873f473b29e42662cd86e8c4";
  };

  # Same shape as the repo's root flake: the file is an attrset and `outputs` is
  # the function (a flake file that IS a function is rejected: "must be an
  # attribute set"). `nixpkgs` is bound here by the argument list, not by magic.
  outputs =
    { self
    , nixpkgs
    , ...
    }@inputs:
    {
      # `system` is bound literally rather than inherited from a caller's `system`
      # input, so this evaluates identically standalone — nixos-rebuild --flake
      # /mnt/etc/nixos#nixos-vm on the guest — and as the repo's input.
      nixosConfigurations.nixos-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./default.nix ];
      };
    };
}
