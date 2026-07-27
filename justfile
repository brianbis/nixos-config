set shell := ["bash", "-cu"]

# Apply current NixOS configuration
switch:
    sudo nixos-rebuild switch --flake .

# Build without activating (safe test)
build:
    sudo nixos-rebuild build --flake .

# Show what would change before switching
diff:
    nix store diff-closures /nix/var/nix/profiles/system ./result

# Update flake inputs
update:
    nix flake update

save message="NixOS configuration update":
    git add .
    if git diff --cached --quiet; then \
        git commit --amend -m "{{message}}"; \
    else \
        git commit -m "{{message}}"; \
    fi

push message="NixOS configuration update":
    just save "{{message}}"
    git push --force-with-lease

# Check config evaluation without switching
check:
    nixos-rebuild dry-build --flake .

# Garbage collect old generations
gc:
    sudo nix-collect-garbage -d

# Show available system generations
generations:
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# Roll back to previous generation
rollback:
    sudo nixos-rebuild switch --rollback --flake .


# Shortcuts
alias s := switch
alias sw := switch
alias apply := switch
alias rebuild := switch
alias rs := switch

alias b := build
alias c := check

alias u := update