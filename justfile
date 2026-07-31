set shell := ["bash", "-cu"]

secrets-dir := "secrets"
identity-key := "/var/lib/agenix/key.txt"

secret-edit name:
    @mkdir -p {{secrets-dir}}
    sudo EDITOR="nano" agenix -e {{secrets-dir}}/{{name}}.age -i {{identity-key}}

secret-show name:
    sudo age -d -i {{identity-key}} {{secrets-dir}}/{{name}}.age

secret-check name:
    @sudo age -d -i {{identity-key}} {{secrets-dir}}/{{name}}.age >/dev/null
    @echo "{{name}}: OK"

secrets-check:
    @for f in {{secrets-dir}}/*.age; do \
        echo "Checking $f"; \
        sudo age -d -i {{identity-key}} "$f" >/dev/null || exit 1; \
    done
    @echo "All secrets OK"

secrets-list:
    @ls -1 {{secrets-dir}}/*.age 2>/dev/null || echo "No secrets found in {{secrets-dir}}"

stage:
    sudo git add .

auto-stage:
    @if ! sudo git diff --quiet || [ -n "$(sudo git status --porcelain)" ]; then \
        echo "Staging changes..."; \
        sudo git add .; \
    fi

# NixOS build & rebuild
switch:
    just auto-stage
    sudo nixos-rebuild switch --flake .

build:
    just auto-stage
    sudo nixos-rebuild build --flake .

check:
    nixos-rebuild dry-build --flake .

diff:
    nix store diff-closures /nix/var/nix/profiles/system ./result

update:
    nix flake update

save message="NixOS configuration update":
    sudo git add -A .
    if sudo git diff --cached --quiet; then \
        sudo git -c user.name="b" -c user.email="brianbis@gmail.com" commit --amend -m "{{message}}"; \
    else \
        sudo git -c user.name="b" -c user.email="brianbis@gmail.com" commit -m "{{message}}"; \
    fi

push message="NixOS configuration update":
    just save "{{message}}"
    sudo GIT_SSH_COMMAND="ssh -i /home/b/.ssh/id_ed25519" git fetch origin
    sudo GIT_SSH_COMMAND="ssh -i /home/b/.ssh/id_ed25519" git push --force-with-lease

gc:
    sudo nix-collect-garbage -d

generations:
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

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

alias se := secret-edit
alias ss := secret-show
alias sc := secret-check