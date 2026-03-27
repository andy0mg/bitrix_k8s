#!/usr/bin/env bash
# Копирует примеры inventory и group_vars для первого запуска Ansible.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../ansible" && pwd)"
cd "$ROOT"
if [[ ! -f inventory/hosts.yml ]]; then
  cp inventory/hosts.yml.example inventory/hosts.yml
fi
if [[ ! -f group_vars/all.yml ]]; then
  cp group_vars/all.yml.example group_vars/all.yml
fi
echo "Готово: отредактируйте $ROOT/inventory/hosts.yml и $ROOT/group_vars/all.yml"
