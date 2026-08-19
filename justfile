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
    sudo rm -f result result-*
    @if ! sudo git diff --quiet || [ -n "$(sudo git status --porcelain)" ]; then \
        echo "Staging changes..."; \
        sudo git add .; \
    fi

# NixOS build & rebuild
switch:
    just auto-stage
    sudo nixos-rebuild switch --flake .
    @sudo nix build --no-link .#agents-md --print-out-paths | xargs -I{} sudo cp {} agents.md

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

# vLLM docker containers
#
# Only ever run ONE at a time: they fight over VRAM.

vllm-containers := "docker-vllm-gemma4-nvfp4-turbo docker-vllm-gemma4-awq"

# Start commands

vllm-gemma4-nvfp4-turbo:
    sudo systemctl start docker-vllm-gemma4-nvfp4-turbo.service

vllm-gemma4-awq:
    sudo systemctl start docker-vllm-gemma4-awq.service

# Infer running container and stop it

vllm-stop:
    #!/usr/bin/env bash
    for c in {{vllm-containers}}; do
        if sudo systemctl is-active --quiet "$c.service"; then
            echo "Stopping $c"
            sudo systemctl stop "$c.service"
            exit 0
        fi
    done
    echo "No vLLM container running"

# Infer running container and show status
vllm-status:
    #!/usr/bin/env bash
    for c in {{vllm-containers}}; do
        echo "checking $c"
        if sudo systemctl is-active --quiet "$c.service"; then
            echo "vLLM running: $c"
            sudo systemctl status "$c.service" --no-pager
            exit 0
        fi
    done
    echo "No vLLM container running"

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

agents-md:
    nix build --no-link .#agents-md --print-out-paths

# llama.cpp shortcuts

llamacpp-start:
    sudo systemctl start llamacpp-muse.service

llamacpp-stop:
    sudo systemctl stop llamacpp-muse.service

llamacpp-restart:
    sudo systemctl restart llamacpp-muse.service

llamacpp-status:
    sudo systemctl status llamacpp-muse.service --no-pager

llamacpp-logs:
    sudo journalctl -u llamacpp-muse.service -f

llamacpp-health:
    curl -s http://127.0.0.1:8000/health || echo "llama.cpp not responding"

llamacpp-load-muse:
    curl -s -X POST http://127.0.0.1:8000/load -H 'Content-Type: application/json' -d '{"model":"/var/lib/llama/models/muse-glimmer-30B-kquant-dynamic.gguf"}' || echo "load failed"

llamacpp-load-qwen:
    curl -s -X POST http://127.0.0.1:8000/load -H 'Content-Type: application/json' -d '{"model":"/var/lib/llama/models/Qwen3.8-27B-Q8_0.gguf"}' || echo "load failed"

llamacpp-models:
    ls -lh /var/lib/llama/models

llamacpp-psi:
    sudo systemctl is-active --quiet llamacpp-muse.service && echo "running" || echo "stopped"

# Short aliases
alias lc-start := llamacpp-start
alias lc-stop := llamacpp-stop
alias lc-status := llamacpp-status