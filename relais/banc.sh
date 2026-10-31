#!/bin/bash
# Banc du relais sur le Mac, avant le NAS : OwnTone du NAS par le réseau local, vraies push (APNs de développement).
#   relais/banc.sh          lance le relais (jetons dans ~/.config/platine/apns/relais-jetons.json)
#   relais/banc.sh jetons   lui donne les jetons lus sur l'iPhone par « scripts/essai-push.py recuperer »
# Réglages tirés de Config/Local.xcconfig et du nom de la clé APNs ; rien de secret n'est affiché.
set -euo pipefail
racine=$(cd "$(dirname "$0")/.." && pwd)
dossier=~/.config/platine/apns
ecoute=127.0.0.1:18090

if [ "${1:-}" = jetons ]; then
  /usr/bin/python3 -I - "$dossier/jetons-push.json" "$ecoute" <<'EOF'
import json, sys, urllib.request
contenu = json.load(open(sys.argv[1]))
envois = [("demarrage", "", contenu.get("demarrage"))] + [("session", s, j) for s, j in contenu.get("sessions", {}).items()]
for genre, session, jeton in envois:
    if not jeton:
        continue
    corps = json.dumps({"type": genre, "session": session, "jeton": jeton}).encode()
    demande = urllib.request.Request(f"http://{sys.argv[2]}/platine/jetons", data=corps, method="POST")
    with urllib.request.urlopen(demande, timeout=20) as r:
        print(f"jeton {genre} …{jeton[-4:]} : HTTP {r.status}")
EOF
  exit
fi

lire() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$racine/Config/Local.xcconfig" | sed 's/\$()//g' | tail -1; }
cles=("$dossier"/AuthKey_*.p8)
[ ${#cles[@]} -eq 1 ] && [ -f "${cles[0]}" ] || { echo "il faut exactement une clé AuthKey_*.p8 dans $dossier" >&2; exit 1; }
id_cle=${cles[0]##*/AuthKey_}
# L'hôte du NAS, tiré de l'alias ssh « nas » : aucun nom réel dans le dépôt.
nas=${NAS:-$(ssh -G nas | awk '/^hostname /{print $2}')}

cd "$racine/relais"
PORTIER=$(lire PLATINE_PORTIER) APNS_EQUIPE=$(lire DEVELOPMENT_TEAM) APNS_CLE_ID=${id_cle%.p8} APNS_CLE=${cles[0]} \
  OWNTONE=http://$nas:3689 OWNTONE_WS=ws://$nas:3688 JETONS=$dossier/relais-jetons.json ECOUTE=$ecoute \
  exec go run .
