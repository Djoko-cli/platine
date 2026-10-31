#!/bin/bash
# Construit Platine, l'installe sur le premier iPhone physique joignable et la lance.
# Usage : scripts/construire.sh [--sans-installer]
# Garde-fous : pas d'app sans icône ; l'identité de signature n'est jamais affichée (titulaire et équipe masqués).
set -euo pipefail
racine="$(cd "$(dirname "$0")/.." && pwd)"
cd "$racine"

[ -s Platine/AppIcon.icon/Assets/platine.png ] && [ -s Platine/AppIcon.icon/icon.json ] \
  || { echo "icône absente : swift outils/dessiner-icone.swift Platine/AppIcon.icon/Assets/platine.png" >&2; exit 1; }
grep -qE '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' Config/Local.xcconfig 2>/dev/null \
  || { echo "Config/Local.xcconfig : DEVELOPMENT_TEAM manquant (voir Config/Signing.xcconfig)" >&2; exit 1; }
equipe=$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]{10}).*/\1/p' Config/Local.xcconfig)
masquer() { sed -E "s/$equipe/<equipe>/g; s/(Apple Development|iPhone Developer|Developer ID Application): [^\"(]*/\1: <titulaire> /g"; }

appareil=""
if [ "${1:-}" != "--sans-installer" ]; then
  json=$(mktemp); trap 'rm -f "$json"' EXIT
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
  appareil=$(python3 -I - "$json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    p = d.get("hardwareProperties", {})
    if p.get("reality") == "physical" and p.get("deviceType") == "iPhone" \
            and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(p["udid"]); break
PY
)
  [ -n "$appareil" ] || { echo "aucun iPhone physique joignable" >&2; exit 1; }
fi

echo "== xcodegen"
xcodegen --quiet
echo "== compilation"
# Compilation générique : l'iPhone n'a pas à être déverrouillé pour compiler, seulement pour installer.
set +e
xcodebuild -project Platine.xcodeproj -scheme Platine -configuration Debug -destination "generic/platform=iOS" \
  -derivedDataPath build -allowProvisioningUpdates build 2>&1 \
  | grep -E 'error:|warning:|\*\* BUILD|Provisioning|provisioning' | grep -v 'appintentsmetadataprocessor' | masquer
code=${PIPESTATUS[0]}
set -e
[ "$code" -eq 0 ] || { echo "compilation échouée (code $code)" >&2; exit "$code"; }
[ -n "$appareil" ] || exit 0

app="build/Build/Products/Debug-iphoneos/Platine.app"
echo "== installation sur l'iPhone"
xcrun devicectl device install app --device "$appareil" "$app" 2>&1 | grep -E 'App installed|error|Error' | masquer
echo "== lancement"
xcrun devicectl device process launch --device "$appareil" io.github.djoko-cli.platine 2>&1 | grep -E 'Launched|error|Error' | masquer
echo "FIN"
