#!/bin/bash
# Pose le relais sur le NAS, avec la route des jetons du portier, puis le lance.
#   relais/deployer.sh            compile, copie, et sauvegarde le Caddyfile du portier en Caddyfile.precedent
#   relais/deployer.sh lancer     construit et démarre le relais, puis redémarre le portier si son Caddyfile a changé
#                                 (sa config n'est relue qu'au démarrage : admin off)
#   relais/deployer.sh verifier   après le lancement : refus du portier et route des jetons, par le nom public
# Sur le NAS, docker répond sans sudo par son chemin complet (/usr/local/bin n'est pas dans le PATH d'une session ssh).
# Compile le binaire linux/amd64, copie binaire, Dockerfile et compose.yaml dans le dossier du relais, la clé APNs et
# le .env seulement s'ils manquent (droits 600). Rien de secret n'est affiché.
set -euo pipefail
racine=$(cd "$(dirname "$0")/.." && pwd)
nas=${NAS_SSH:-nas}
dossier=${DOSSIER_RELAIS:-/volume2/docker/platine-relais}
portier=${DOSSIER_PORTIER:-/volume2/docker/platine-portier}
docker=/usr/local/bin/docker
lire() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$racine/Config/Local.xcconfig" | sed 's/\$()//g' | tail -1; }

if [ "${1:-}" = lancer ]; then
  ssh "$nas" "cd '$dossier' && $docker compose up -d --build"
  if ssh "$nas" "test -f '$dossier/.portier-a-redemarrer'"; then
    ssh "$nas" "$docker restart platine-portier && rm -f '$dossier/.portier-a-redemarrer'"
  else
    echo "portier : Caddyfile inchangé, pas de redémarrage"
  fi
  exit
fi

if [ "${1:-}" = verifier ]; then
  adresse=$(lire PLATINE_PORTIER)
  jeton=$(lire PLATINE_JETON)
  code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
  # Le jeton passe par l'entrée standard, pas par la ligne de commande (visible dans la liste des processus).
  avec_jeton() { printf 'Authorization: Bearer %s\n' "$jeton" | code -H @- "$@"; }
  attendu() { [ "$2" = "$3" ] && echo "ok      $1 : HTTP $2" || { echo "ÉCHEC   $1 : HTTP $2, attendu $3"; echec=1; }; }
  echec=0
  attendu "sans jeton" "$(code "$adresse/api/player")" 401
  attendu "jetons sans jeton" "$(code -X POST -d '{}' "$adresse/platine/jetons")" 401
  attendu "hors liste" "$(avec_jeton "$adresse/api/config")" 404
  attendu "état du lecteur" "$(avec_jeton "$adresse/api/player")" 200
  # Un corps invalide : le relais répond 400, preuve que la route passe jusqu'à lui (502 s'il ne tourne pas).
  attendu "route des jetons" "$(avec_jeton -X POST -d '{}' "$adresse/platine/jetons")" 400
  unset jeton
  exit $echec
fi
cles=(~/.config/platine/apns/AuthKey_*.p8)
[ ${#cles[@]} -eq 1 ] && [ -f "${cles[0]}" ] || { echo "il faut exactement une clé AuthKey_*.p8 dans ~/.config/platine/apns" >&2; exit 1; }

echo "== tests et compilation"
cd "$racine/relais"
go vet ./... && go test -count=1 ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o build/relais .

echo "== copie vers le NAS"
# Les ACL du dossier partagé de DSM passent outre umask (fichiers créés en rwxrwxrwx+) ; chmod les retire. Un secret
# reçoit ses droits avant son contenu : il n'est jamais lisible par d'autres, même un instant.
envoyer() { ssh "$nas" "cat > '$2' && chmod ${3:-644} '$2'" < "$1"; }
envoyer_secret() { ssh "$nas" "rm -f '$1' && : > '$1' && chmod 600 '$1' && cat > '$1'"; }
ssh "$nas" "mkdir -p '$dossier/donnees' && chmod 700 '$dossier/donnees'"
envoyer build/relais "$dossier/relais" 755
envoyer Dockerfile "$dossier/Dockerfile"
envoyer compose.yaml "$dossier/compose.yaml"
printf '*\n!relais\n' | ssh "$nas" "cat > '$dossier/.dockerignore' && chmod 644 '$dossier/.dockerignore'"
if ssh "$nas" "test -f '$dossier/AuthKey.p8'"; then
  echo "clé APNs : déjà en place"
else
  envoyer_secret "$dossier/AuthKey.p8" < "${cles[0]}" && echo "clé APNs : copiée (600)"
fi
if ssh "$nas" "test -f '$dossier/.env'"; then
  echo ".env : déjà en place"
else
  id_cle=${cles[0]##*/AuthKey_}
  {
    echo "PORTIER=$(lire PLATINE_PORTIER)"
    echo "APNS_EQUIPE=$(lire DEVELOPMENT_TEAM)"
    echo "APNS_CLE_ID=${id_cle%.p8}"
    echo "RELAIS_UID=$(ssh "$nas" id -u)"
    echo "RELAIS_GID=$(ssh "$nas" id -g)"
    echo "TZ=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  } | envoyer_secret "$dossier/.env"
  echo ".env : écrit (600)"
fi
# Écrit en place (même inode) : le conteneur monte ce fichier seul, un fichier remplacé lui resterait invisible.
if ssh "$nas" "cat '$portier/Caddyfile'" | cmp -s - "$racine/portier/Caddyfile"; then
  echo "Caddyfile du portier : déjà à jour"
else
  ssh "$nas" "cp -p '$portier/Caddyfile' '$portier/Caddyfile.precedent'"
  ssh "$nas" "cat > '$portier/Caddyfile'" < "$racine/portier/Caddyfile"  # droits d'origine gardés
  ssh "$nas" ": > '$dossier/.portier-a-redemarrer'"  # pour « lancer »
  echo "Caddyfile du portier : à jour (l'ancien en Caddyfile.precedent)"
fi

echo
echo "Ensuite : relais/deployer.sh lancer, puis relais/deployer.sh verifier"
echo "Journal : ssh $nas tail -F $dossier/donnees/relais.log"
echo "Retour arrière du portier : ssh $nas \"cat $portier/Caddyfile.precedent > $portier/Caddyfile\", puis redémarrer le portier"
