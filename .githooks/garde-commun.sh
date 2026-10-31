#!/bin/bash
# Fonctions partagées par les gardes de Platine (dépôt pouvant devenir public).
# La liste garde.local.txt (ignorée par git) donne une valeur réelle par ligne,
# comparée sans casse ; les lignes vides et les commentaires # sont ignorés
# (une ligne vide passée à grep -f correspondrait à tout).
# Modèles : gardes de haptool et de maillage-zigbee. Ne jamais contourner (pas de --no-verify).

garde_attendu="12185352+Djoko-cli@users.noreply.github.com"

# Écrit les motifs utiles de la liste dans le fichier $2 ; échoue si la liste manque ou est vide.
garde_motifs() { # $1 : nom du garde, $2 : fichier de sortie
  local liste
  liste="$(git rev-parse --show-toplevel)/garde.local.txt"
  if [ ! -s "$liste" ]; then
    echo "$1 : liste locale du garde absente ($liste) : refusé" >&2
    return 1
  fi
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$liste" > "$2" || true
  if [ ! -s "$2" ]; then
    echo "$1 : liste locale du garde vide : refusé" >&2
    return 1
  fi
}

# Lit un texte sur l'entrée standard et affiche la raison de chaque fuite trouvée,
# sans jamais afficher la valeur trouvée. Code de sortie 1 si au moins une fuite.
garde_examine() { # $1 : fichier des motifs
  local texte trouve=0
  texte=$(cat)
  if printf '%s\n' "$texte" | grep -Eq '(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}'; then
    echo "adresse IP privée (remplacer par 192.0.2.x)"; trouve=1
  fi
  if printf '%s\n' "$texte" | grep -viE '02:00:00:|AA:BB:CC:' | grep -Eq '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'; then
    echo "adresse MAC réelle (remplacer par 02:00:00:…)"; trouve=1
  fi
  if printf '%s\n' "$texte" | grep -Eq '/Users/[A-Za-z]'; then
    echo "chemin /Users/<nom>"; trouve=1
  fi
  if printf '%s\n' "$texte" | grep -qiF -f "$1"; then
    echo "identifiant réel de la liste locale"; trouve=1
  fi
  return "$trouve"
}
