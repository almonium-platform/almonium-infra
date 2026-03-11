#!/usr/bin/env bash
set -euo pipefail

cd /home/almonium/infra
git fetch origin main
git reset --hard origin/main

if ! command -v ansible >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y ansible
fi

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
fi

if ! docker compose version >/dev/null 2>&1; then
  sudo apt-get install -y docker-compose-plugin
fi

ansible-galaxy collection install community.docker
