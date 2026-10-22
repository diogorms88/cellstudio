#!/bin/sh
# Imprime o build-info.json do app: o último commit que mudou o código (Sources/) e a data dele.
# Envios só de dados (flash's, bodies) não mudam a versão. Fora de um repositório git: "dev".
cd "$(dirname "$0")/.." || exit 1
commit=$(git log -1 --format=%H -- Sources 2>/dev/null)
[ -n "$commit" ] || commit=dev
date=$(git log -1 --format=%cI -- Sources 2>/dev/null)
printf '{"commit":"%s","date":"%s"}\n' "$commit" "$date"
