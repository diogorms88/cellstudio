#!/bin/zsh
# Atualização automática do CellStudio no iPhone, feita pelo Mac (roda pelo launchd a cada 30 min).
#
# 1. Mantém uma cópia do GitHub em ~/Library/Application Support/CellStudio/updater/repo (igual ao GitHub, sem edições locais).
# 2. Se o GitHub tem commit novo, ou se a última instalação tem mais de 5 dias (a assinatura gratuita vale 7),
#    e o iPhone está conectado (cabo ou mesma rede Wi-Fi), compila com o Xcode e instala no iPhone.
#
#   cellstudio-updater.sh           verificação normal
#   cellstudio-updater.sh --force   compila e instala mesmo sem commit novo
set -u
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

REPO_URL=https://github.com/diogorms88/cellstudio.git
BUNDLE_ID=local.diogoramos.cellstudio
BASE="$HOME/Library/Application Support/CellStudio/updater"
SRC="$BASE/repo"
STATE="$BASE/state"
DERIVED="$BASE/build"
mkdir -p "$STATE"
exec >>"$BASE/updater.log" 2>&1

log() { print -- "$(date '+%Y-%m-%d %H:%M:%S') $*" }
notify() { osascript -e "display notification \"$1\" with title \"CellStudio\"" >/dev/null 2>&1 }

# só uma execução por vez (trava esquecida há mais de 2 h é descartada)
LOCK="$BASE/.lock"
if [[ -d $LOCK ]] && (( $(date +%s) - $(stat -f %m "$LOCK") > 7200 )); then rmdir "$LOCK"; fi
mkdir "$LOCK" 2>/dev/null || { log "outra atualização em andamento"; exit 0 }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

if [[ ! -d "$SRC/.git" ]]; then
  git clone -q "$REPO_URL" "$SRC" || { log "não consegui clonar $REPO_URL"; exit 1 }
fi
cd "$SRC" || exit 1
git fetch -q origin main || { log "sem conexão com o GitHub"; exit 0 }
git reset -q --hard origin/main
# versão do app = último commit que mudou o código (envios só de dados não recompilam)
HEAD_SHA=$(git log -1 --format=%H -- Sources)

# o próprio atualizador também se atualiza a partir do GitHub
# (cópia + mv: o zsh lê o script aos poucos, então o arquivo em execução não pode ser sobrescrito no lugar)
cp -f tools/cellstudio-updater.sh "$BASE/.updater.new" 2>/dev/null && mv -f "$BASE/.updater.new" "$BASE/cellstudio-updater.sh"

last_sha=$(cat "$STATE/iphone-commit" 2>/dev/null || echo none)
last_time=$(cat "$STATE/iphone-time" 2>/dev/null || echo 0)
age=$(( $(date +%s) - last_time ))
reason=""
[[ "${1:-}" == --force ]] && reason="pedido manual"
[[ -z $reason && $last_sha != $HEAD_SHA ]] && reason="commit novo ${HEAD_SHA[1,7]}"
[[ -z $reason && $age -gt 432000 ]] && reason="renovar assinatura (instalado há $(( age / 86400 )) dias)"
[[ -z $reason ]] && exit 0

# iPhone pareado e ao alcance (cabo ou rede; "unavailable" = longe), com Modo de Desenvolvedor
devjson="$BASE/devices.json"
xcrun devicectl list devices --json-output "$devjson" >/dev/null 2>&1
DEVICE=$(/usr/bin/python3 - "$devjson" <<'PY'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devs = []
for d in devs:
    c, p, h = d.get("connectionProperties", {}), d.get("deviceProperties", {}), d.get("hardwareProperties", {})
    if h.get("platform") == "iOS" and c.get("pairingState") == "paired" and c.get("tunnelState") in ("connected", "disconnected") \
       and p.get("developerModeStatus") == "enabled":
        print(d["identifier"], h.get("udid", ""))
        break
PY
)
if [[ -z $DEVICE ]]; then
  log "$reason: nenhum iPhone conectado, tento de novo depois"
  exit 0
fi
DEVICE_ID=${DEVICE%% *}
UDID=${DEVICE##* }

log "$reason: compilando para o iPhone $UDID"
cd "$SRC/ios" || exit 1
xcodegen -q >/dev/null || { log "xcodegen falhou"; exit 1 }
if ! xcodebuild -project CellStudio.xcodeproj -scheme CellStudio -configuration Release \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build >"$BASE/last-build.log" 2>&1; then
  log "compilação falhou (ver last-build.log)"
  notify "A atualização falhou ao compilar. Veja o log no Mac."
  exit 1
fi
APP="$DERIVED/Build/Products/Release-iphoneos/CellStudio.app"
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >"$BASE/last-install.log" 2>&1; then
  log "instalação falhou (iPhone bloqueado?) – ver last-install.log"
  exit 1
fi
print -- $HEAD_SHA > "$STATE/iphone-commit"
date +%s > "$STATE/iphone-time"
log "instalado ${HEAD_SHA[1,7]} no iPhone"
notify "Nova versão instalada no iPhone (${HEAD_SHA[1,7]})"
