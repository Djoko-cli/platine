#!/bin/bash
# Garde anti-fuite des dépôts pouvant devenir publics : fonctions partagées par
# pre-commit, commit-msg et pre-push. Ce dossier .githooks est identique, octet
# pour octet, dans chaque dépôt qui l'utilise : le modifier dans platine, puis le
# recopier tel quel (comparer les md5). Tests : .githooks/essai-garde.sh.
# La liste garde.local.txt (ignorée par git, jamais affichée) donne une valeur
# réelle par ligne ; les lignes vides et les commentaires # sont ignorés. Une
# valeur est trouvée sans tenir compte de la casse ni des accents (perl requis).
# Toute erreur de lecture refuse, au lieu de laisser passer. Ne jamais contourner
# (pas de --no-verify).

export LC_ALL=C   # octets bruts : tr, sed et grep ne butent pas sur un binaire
export GIT_NO_REPLACE_OBJECTS=1   # objets réels, ceux que git push envoie, pas leurs remplaçants (git replace, filter-repo)

garde_attendu="12185352+Djoko-cli@users.noreply.github.com"

# IPv4 privées, Tailscale (100.64/10) et lien local (169.254/16)
garde_ipv4='(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168|169\.254|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))\.[0-9]{1,3}\.[0-9]{1,3}'
# IPv6 ULA (fdXX:XXXX:…, mais pas fd00::1) et globales (2000::/3, hors 2001:db8:: effacé avant)
garde_ipv6='(^|[^0-9a-z:])(fd[0-9a-f]{2}:[0-9a-f]{1,4}:|[23][0-9a-f]{3}:[0-9a-f]{1,4}:[0-9a-f]{0,4}:)'

# Dossier temporaire du crochet ($garde_tmp, avec $motifs et $texte), effacé à la sortie,
# même interrompue : garde_examine y écrit aussi ses copies du texte examiné.
garde_debut() { # $1 : nom du garde
  garde_tmp=$(mktemp -d) || { echo "$1 : dossier temporaire impossible : refusé" >&2; exit 1; }
  trap 'rm -rf "$garde_tmp"' EXIT
  motifs="$garde_tmp/motifs"; texte="$garde_tmp/texte"
}

# Écrit dans $2 les motifs de la liste, en minuscules, chacun en trois variantes
# (NFC, NFD, sans accents) ; échoue si la liste manque ou est vide, ou sans perl.
garde_motifs() { # $1 : nom du garde, $2 : fichier de sortie
  local liste commun
  liste="$(git rev-parse --show-toplevel)/garde.local.txt"
  if [ ! -s "$liste" ]; then   # copie de travail (git worktree) : la liste du dépôt principal
    commun=$(git rev-parse --path-format=absolute --git-common-dir) && liste="$(dirname "$commun")/garde.local.txt"
  fi
  if [ ! -s "$liste" ]; then
    echo "$1 : liste locale du garde absente ($liste) : refusé" >&2
    return 1
  fi
  if ! perl -MEncode -MUnicode::Normalize -ne '
      $_ = Encode::decode("UTF-8", $_); s/^\s+|\s+$//g; next if $_ eq "" || /^#/;
      my $c = lc NFC($_); my $d = NFD($c); (my $s = $d) =~ s/\p{Mn}//g; my %vu;
      for ($c, $d, $s) { print Encode::encode("UTF-8", $_), "\n" if $_ ne "" && !$vu{$_}++ }' "$liste" > "$2"; then
    echo "$1 : perl (Encode, Unicode::Normalize) indisponible : refusé" >&2
    return 1
  fi
  if [ ! -s "$2" ]; then
    echo "$1 : liste locale du garde vide : refusé" >&2
    return 1
  fi
}

# Texte sur l'entrée standard → minuscules NFC (octets non UTF-8 remplacés), et chaque
# ligne accentuée une seconde fois sans ses accents : une valeur inscrite sans accents
# trouve aussi le texte accentué.
garde_normalise() {
  perl -MEncode -MUnicode::Normalize -ne '
    chomp; my $c = lc NFC(Encode::decode("UTF-8", $_)); (my $s = NFD($c)) =~ s/\p{Mn}//g; $s = NFC($s);
    print Encode::encode("UTF-8", $c), "\n"; print Encode::encode("UTF-8", $s), "\n" if $s ne $c'
}

# Garde les lignes ajoutées d'un diff (sans le « + »), seulement à l'intérieur des blocs @@ :
# l'en-tête « +++ b/… » est écarté, mais pas une ligne ajoutée qui commence elle-même par « ++ ».
garde_ajouts() {
  awk '/^diff --git /{h=0; next} /^@@/{h=1; next} h && /^\+/{print substr($0, 2)}'
}

# grep -q sur un fichier, sans tube (un tube vers grep -q perd la fuite sous pipefail) :
# affiche $1 si trouvé, et refuse aussi si grep échoue.
garde_cherche() { # $1 : raison ; le reste : arguments de grep
  local raison=$1; shift
  grep -q "$@"
  case $? in
    0) echo "$raison"; return 0 ;;
    1) return 1 ;;
    *) echo "examen impossible (grep)"; return 0 ;;
  esac
}

# Lit un texte sur l'entrée standard et affiche la raison de chaque fuite trouvée,
# sans jamais afficher la valeur trouvée. Code de sortie 1 si au moins une fuite.
# L'appelant traite aussi un code non nul sans raison comme un refus.
garde_examine() { # $1 : fichier des motifs
  local brut trouve=0
  [ -n "${garde_tmp:-}" ] && [ -d "$garde_tmp" ] || { echo "examen impossible (dossier temporaire)"; return 1; }
  brut="$garde_tmp/brut"
  # binaires examinés en texte, sans octets nuls ; MAC factices (02:00:00:…, aa:bb:cc:…,
  # nulle, de diffusion, de documentation 00:00:5e:00:53:…), IPv6 de documentation et
  # /Users/Shared effacés un à un (pas la ligne entière) ; liste comparée au texte normalisé
  if ! { tr -d '\000' > "$brut" &&
         sed -E -e 's/(02:00:00|[Aa][Aa]:[Bb][Bb]:[Cc][Cc])(:[0-9A-Fa-f]{2}){3}//g' \
                -e 's/00:00:5[Ee]:00:53:[0-9A-Fa-f]{2}|00(:00){5}|[Ff][Ff](:[Ff][Ff]){5}//g' \
                -e 's/2001:0{0,3}[Dd][Bb]8:[0-9A-Fa-f:]*//g' \
                -e 's#/Users/Shared([^A-Za-z0-9._-]|$)#\1#g' "$brut" > "$brut.epure" &&
         garde_normalise < "$brut" > "$brut.norme"; }; then
    echo "examen impossible (perl ?)"; return 1
  fi
  garde_cherche "adresse IP privée (remplacer par 192.0.2.x)" -E "$garde_ipv4" "$brut" && trouve=1
  garde_cherche "adresse MAC réelle (remplacer par 02:00:00:…)" -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$brut.epure" && trouve=1
  garde_cherche "adresse IPv6 réelle (remplacer par fd00::1 ou 2001:db8::1)" -iE "$garde_ipv6" "$brut.epure" && trouve=1
  # un vrai nom (machine.tailnet…) a un caractère de nom avant « .ts.net » ; le joker « *.ts.net » passe
  garde_cherche "nom d'hôte Tailscale (remplacer par hote.example)" -iE '[a-z0-9-]\.ts\.net([^a-z0-9-]|$)' "$brut" && trouve=1
  garde_cherche "chemin /Users/<nom>" -E '/Users/[A-Za-z]' "$brut.epure" && trouve=1
  garde_cherche "identifiant réel de la liste locale" -F -f "$1" "$brut.norme" && trouve=1
  return "$trouve"
}
