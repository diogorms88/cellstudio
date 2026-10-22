#!/bin/zsh
# Instala (ou remove com --remove) o serviço do Mac que atualiza o CellStudio no iPhone a partir do GitHub.
set -e
LABEL=local.diogoramos.cellstudio.updater
BASE="$HOME/Library/Application Support/CellStudio/updater"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == --remove ]]; then
  rm -f "$PLIST"
  echo "Serviço removido (a pasta $BASE ficou; pode apagar)."
  exit 0
fi

mkdir -p "$BASE" "$HOME/Library/LaunchAgents"
cp -f "${0:A:h}/cellstudio-updater.sh" "$BASE/cellstudio-updater.sh"
chmod +x "$BASE/cellstudio-updater.sh"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/zsh</string><string>$BASE/cellstudio-updater.sh</string></array>
	<key>StartInterval</key><integer>1800</integer>
	<key>RunAtLoad</key><true/>
	<key>LowPriorityIO</key><true/>
	<key>Nice</key><integer>10</integer>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Serviço instalado: verifica o GitHub a cada 30 minutos. Log: $BASE/updater.log"
