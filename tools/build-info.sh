#!/bin/sh
# Imprime o build-info.json do app: commit do git e data (fora de um repositório git, "dev").
cd "$(dirname "$0")/.." || exit 1
commit=$(git rev-parse HEAD 2>/dev/null || echo dev)
date=$(git log -1 --format=%cI 2>/dev/null)
printf '{"commit":"%s","date":"%s"}\n' "$commit" "$date"
