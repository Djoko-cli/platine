#!/bin/bash
# Essais du garde anti-fuite (voir garde-commun.sh).
#   .githooks/essai-garde.sh               rejoue les scénarios sur des dépôts jetables, avec une
#                                          liste inventée ; sort en erreur au moindre écart.
#   .githooks/essai-garde.sh --historique  passe le pre-push à blanc sur tout l'historique de ce
#                                          dépôt (clone temporaire sans remote) : branches, tags,
#                                          branches suivies et notes. La vraie liste n'est lue que
#                                          par le garde, qui n'affiche jamais une valeur.
#   .githooks/essai-garde.sh --installe    copie le garde dans .git/hooks (dossier commun à toutes
#                                          les copies de travail) et retire core.hooksPath : il ne
#                                          dépend plus de la branche extraite ni de l'emplacement
#                                          du dépôt. À relancer après chaque mise à jour de .githooks.
# Les valeurs de test sont assemblées à l'exécution : ce fichier passe lui-même le garde.
set -u
ici=$(cd "$(dirname "$0")" > /dev/null && pwd)
z=0000000000000000000000000000000000000000
noreply="12185352+Djoko-cli@users.noreply.github.com"
crochets=(garde-commun.sh pre-commit commit-msg pre-push)
dossier_actif() { # dossier où git cherche les crochets de ce dépôt (core.hooksPath, sinon .git/hooks)
  local v; v=$(git -C "$ici" config core.hooksPath) || { echo "$(git -C "$ici" rev-parse --path-format=absolute --git-common-dir)/hooks"; return; }
  case $v in /*) echo "$v" ;; *) echo "$(git -C "$ici" rev-parse --show-toplevel)/$v" ;; esac
}

if [ "${1:-}" = --installe ]; then
  dest="$(git -C "$ici" rev-parse --path-format=absolute --git-common-dir)/hooks" || exit 1
  mkdir -p "$dest" || exit 1
  for f in "${crochets[@]}"; do   # ne pas écraser un crochet étranger au garde
    if [ -e "$dest/$f" ] && ! grep -q -e garde-commun -e "Garde anti-fuite" "$dest/$f"; then echo "$dest/$f existe déjà et n'est pas le garde : installation refusée" >&2; exit 1; fi
  done
  for f in "${crochets[@]}"; do cp "$ici/$f" "$dest/$f" && chmod +x "$dest/$f" || exit 1; done
  git -C "$ici" config --unset-all core.hooksPath 2>/dev/null
  echo "Garde installé dans .git/hooks (core.hooksPath retiré). Le réinstaller après chaque mise à jour de .githooks."
  [ "$(dossier_actif)" = "$dest" ] || echo "ATTENTION : un autre core.hooksPath (global ou propre à cette copie de travail) l'emporte encore : $(dossier_actif)"
  exit 0
fi

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

if [ "${1:-}" = --historique ]; then
  racine=$(git -C "$ici" rev-parse --show-toplevel) || exit 1
  liste="$racine/garde.local.txt"
  [ -s "$liste" ] || liste="$(dirname "$(git -C "$ici" rev-parse --path-format=absolute --git-common-dir)")/garde.local.txt"
  [ -s "$liste" ] || { echo "liste locale du garde absente : passage à blanc impossible" >&2; exit 1; }
  git clone -q --no-local "$racine" "$tmp/clone" || exit 1
  cd "$tmp/clone" || exit 1
  # les branches du dépôt deviennent des branches locales du clone, sans remote : tout l'historique est neuf
  git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin | grep -vx HEAD |
    while read -r b; do git branch -q -f "$b" "origin/$b" 2>/dev/null; done
  # ses branches suivies (ce qui est déjà publié) et ses notes aussi
  git fetch -q --no-tags "$racine" '+refs/remotes/*:refs/heads/suivie/*' '+refs/notes/*:refs/notes/*' || exit 1
  git remote remove origin
  for f in "${crochets[@]}"; do cp "$ici/$f" ".githooks/$f" || exit 1; done   # le garde à essayer, pas celui du clone
  ln -s "$liste" garde.local.txt
  echo "Passage à blanc du pre-push : $(git for-each-ref refs/heads refs/tags refs/notes | wc -l | tr -d ' ') branches, tags et notes, $(git rev-list --all | wc -l | tr -d ' ') commits…"
  if git for-each-ref --format="%(refname) %(objectname) %(refname) $z" refs/heads refs/tags refs/notes | .githooks/pre-push; then
    echo "Historique accepté par ce garde."
  else
    echo "Historique REFUSÉ par ce garde (raisons ci-dessus)."; exit 1
  fi
  exit 0
fi

# Valeurs inventées, assemblées pour que ce fichier ne contienne aucun motif tel quel.
ip="10.11""2.13.14"             # IPv4 privée
ts4="100.10""1.102.103"         # Tailscale (100.64/10)
ll4="169.25""4.10.20"           # lien local
mac="0a:1b:2c"":3d:4e:5f"       # MAC qui n'est pas factice (administrée localement : d'aucun constructeur)
ula="fd12"":3456:789a::1"       # IPv6 ULA
g6="3fff"":1234:5678::1"        # IPv6 globale (préfixe que l'IANA n'attribue à personne)
tsn="exemple.ts"".net"          # nom Tailscale
chemin="/Use""rs/exemple/x"     # chemin d'un compte macOS
valeur="Test""prenom"           # valeur de la liste
accent="Test""èrié"             # valeur accentuée de la liste
sans="Test""erie"               # la même, sans accents
nonaccent="Sans""accentville"   # valeur inscrite sans accents dans la liste
tardive="Valeur""tardivé"       # ajoutée à la liste après coup (P7)
utf8() { perl -MEncode -MUnicode::Normalize -ne "print Encode::encode('UTF-8', $1(Encode::decode('UTF-8', \$_)))"; }
maj=$(printf '%s' "$accent" | utf8 uc)
nfd=$(printf '%s' "$accent" | utf8 NFD)
liste_inventee() { printf '# liste inventée\n  %s \n\n%s\n%s\n%s' "$valeur" "$accent" "$nonaccent" "${1:-}" > garde.local.txt; }

ecarts=0
raison=   # si non vide : texte que la sortie du garde doit contenir (prouve le chemin qui a refusé)
note() { # $1 libellé, $2 obtenu, $3 attendu, $4 sortie du garde (montrée en cas d'écart)
  local ok=1
  [ "$2" = "$3" ] || ok=0
  if [ -n "$raison" ] && ! printf '%s\n' "${4:-}" | grep -qF -- "$raison"; then ok=0; fi
  if [ "$ok" = 1 ]; then
    printf '%-60s %-8s\n' "$1" "$2"
  else
    ecarts=$((ecarts + 1))
    printf '%-60s %-8s <-- ÉCART (attendu : %s%s)\n' "$1" "$2" "$3" "${raison:+, raison « $raison »}"
    [ -n "${4:-}" ] && printf '%s\n' "$4" | sed 's/^/      | /'
  fi
  raison=
}
remet() { git reset -q --hard "$base"; git clean -qfdx -e garde.local.txt; }
cas() { # $1 libellé, $2 attendu, puis la commande (par défaut : git commit) ; l'index est prêt
  local libelle=$1 attendu=$2 r sortie; shift 2
  [ $# -gt 0 ] || set -- git commit -q -m essai
  if sortie=$("$@" 2>&1); then r=accepté; else r=refusé; fi
  note "$libelle" "$r" "$attendu" "$sortie"; remet
}
fige() { git add -A && git write-tree; remet; }   # arbre des fichiers écrits, sans crochet
pousse() { # $1 libellé, $2 attendu, $3 ligne de l'entrée standard du pre-push, puis remote et URL
  local lib=$1 att=$2 entree=$3 r sortie; shift 3
  if sortie=$(printf '%s\n' "$entree" | .githooks/pre-push "$@" 2>&1); then r=accepté; else r=refusé; fi
  note "$lib" "$r" "$att" "$sortie"
}

R="$tmp/depot"
git init -q -b main "$R" && cd "$R" || exit 1
git config user.name Djoko-cli; git config user.email "$noreply"; git config core.hooksPath .githooks
git config core.precomposeUnicode false   # garder les noms NFD tels quels (macOS les recompose sinon)
mkdir .githooks && cp "$ici"/essai-garde.sh .githooks/ && for f in "${crochets[@]}"; do cp "$ici/$f" .githooks/ || exit 1; done
liste_inventee; printf 'garde.local.txt\n' > .gitignore
echo "Scénarios du garde (dépôt jetable, liste inventée) :"
git add -A
if sortie=$(git commit -q -m "base du dépôt d'essai" 2>&1); then r=accepté; else r=refusé; fi
note "0. le garde se commite lui-même" "$r" accepté "$sortie"
[ "$r" = accepté ] || { echo "Arrêt : la base n'a pas pu être commitée."; exit 1; }
base=$(git rev-parse HEAD)

echo "-- commit (pre-commit, commit-msg)"
echo neutre > "releve-$ip.txt"; git add -A;               cas "1a. nom de fichier avec une IP privée" refusé
echo neutre > "capture-$nfd.txt"; git add -A;             cas "1b. nom de fichier avec une valeur accentuée (NFD)" refusé
printf '++ %s\n' "$ip" > notes.txt; git add -A;           cas "2. ligne ajoutée qui commence par ++" refusé
printf 'PNG\0\0%s\0' "$valeur" > capture.bin; git add -A; cas "3. binaire avec une valeur de la liste" refusé
printf 'auteur %s.\n' "$valeur" > t.txt; git add -A;      cas "4. valeur entourée d'espaces dans la liste" refusé
printf 'factice 02:00:00:00:00:01 réelle %s\n' "$mac" > t.txt; git add -A; cas "5. MAC réelle sur une ligne de MAC factice" refusé
printf 'tailnet %s\n' "$ts4" > t.txt; git add -A;         cas "6a. adresse Tailscale" refusé
printf 'auto %s\n' "$ll4" > t.txt; git add -A;            cas "6b. adresse de lien local" refusé
printf 'prefixe %s\n' "$ula" > t.txt; git add -A;         cas "6c. préfixe IPv6 ULA" refusé
printf 'fibre %s\n' "$g6" > t.txt; git add -A;            cas "6d. adresse IPv6 globale" refusé
printf 'nom %s\n' "$tsn" > t.txt; git add -A;             cas "6e. nom Tailscale" refusé
printf 'chemin %s\n' "$chemin" > t.txt; git add -A;       cas "6f. chemin d'un compte macOS" refusé
printf 'exemples fd00::1 2001:db8::1 2001:db8:0:1::5 192.0.2.10 127.0.0.1 1.10.0.0.1\n02:00:00:00:00:01 aa:bb:cc:00:00:02 00:00:00:00:00:00 ff:ff:ff:ff:ff:ff 00:00:5e:00:53:01\nmac.local hote.example garde.local.txt *.ts.net <tailnet>.ts.net /Users/Shared/x\n' > t.txt
git add -A;                                               cas "7. valeurs factices autorisées" accepté
printf 'chez %s\n' "$maj" > t.txt; git add -A;            cas "8a. valeur accentuée en capitales" refusé
printf 'chez %s\n' "$nfd" > t.txt; git add -A;            cas "8b. valeur accentuée décomposée (NFD)" refusé
printf 'chez %s\n' "$sans" > t.txt; git add -A;           cas "8c. valeur accentuée écrite sans accents" refusé
printf 'chez %s\n' "Sans""àccéntvillé" > t.txt; git add -A; cas "8d. valeur inscrite sans accents, écrite avec" refusé
echo x > m.txt; git add -A;                               cas "9a. message de commit avec une IP privée" refusé git commit -q -m "relevé de $ip"
echo x > m.txt; git add -A;                               cas "9b. message avec une valeur de la liste" refusé git commit -q -m "chez $maj"
printf 'hote %s\n' "$ip" > m.txt; fuite=$(echo "fuite, faite sans crochet" | git commit-tree "$(fige)" -p "$base")
git reset -q --hard "$fuite"; echo propre > m.txt; git add -A
cas "10. retrait d'une fuite avec git commit -v" accepté env GIT_EDITOR=true git commit -q -v -e -m retrait
mv garde.local.txt "$tmp/liste"; echo x > a.txt; git add -A
raison="liste locale du garde absente"; cas "11. liste locale absente" refusé; mv "$tmp/liste" garde.local.txt
mkdir "$tmp/sans-perl"; printf '#!/bin/sh\nexit 127\n' > "$tmp/sans-perl/perl"; chmod +x "$tmp/sans-perl/perl"
echo x > a.txt; git add -A; raison="perl";                cas "12. perl absent" refusé env PATH="$tmp/sans-perl:$PATH" .githooks/pre-commit
git worktree add -q "$tmp/copie" -b copie
if sortie=$(cd "$tmp/copie" && echo w > w.txt && git add w.txt && git commit -q -m copie 2>&1); then r=accepté; else r=refusé; fi
note "13a. commit dans une copie de travail (git worktree)" "$r" accepté "$sortie"
if sortie=$(cd "$tmp/copie" && printf 'chez %s\n' "$valeur" > w2.txt && git add w2.txt && git commit -q -m copie 2>&1); then r=accepté; else r=refusé; fi
raison="liste locale"; note "13b. fuite dans une copie de travail : liste principale lue" "$r" refusé "$sortie"
git worktree remove --force "$tmp/copie"; git branch -q -D copie
ln -s base.txt lien; git add lien; lien=$(echo lien | git commit-tree "$(fige)" -p "$base"); git reset -q --hard "$lien"
rm lien; printf 'hote %s\n' "$ip" > lien; git add lien; cas "14. lien remplacé par un fichier fautif (statut T)" refusé
git reset -q --hard "$base"

echo "-- push (pre-push)"
pousse "P0. historique propre, branche neuve sans remote" accepté "refs/heads/main $base refs/heads/main $z"
pousse "P1. commit poussé contenant une IP privée" refusé "refs/heads/x $fuite refs/heads/x $base"
echo a > n.txt; c=$(echo nom | GIT_AUTHOR_NAME="$valeur Nom" git commit-tree "$(fige)" -p "$base")
pousse "P2a. auteur au nom réel, e-mail noreply" refusé "refs/heads/x $c refs/heads/x $base"
echo a > n.txt; c=$(echo courriel | GIT_AUTHOR_EMAIL="quelquun@exemple.org" git commit-tree "$(fige)" -p "$base")
pousse "P2b. auteur hors noreply" refusé "refs/heads/x $c refs/heads/x $base"
echo cote > m2.txt; cote=$(echo cote | git commit-tree "$(fige)" -p "$base")
echo princ > m2.txt; princ=$(echo princ | git commit-tree "$(fige)" -p "$base")
printf 'resolu %s\n' "$ip" > m2.txt; fusion=$(echo fusion | git commit-tree "$(fige)" -p "$princ" -p "$cote")
pousse "P3. résolution de fusion qui ajoute une IP" refusé "refs/heads/x $fusion refs/heads/x $base"
git tag -a v-essai1 -m "publié depuis $ip" "$base"
pousse "P4a. tag annoté dont le message a une IP" refusé "refs/tags/v-essai1 $(git rev-parse v-essai1) refs/tags/v-essai1 $z"
GIT_COMMITTER_EMAIL="quelquun@exemple.org" git tag -a v-essai2 -m "version" "$base"
pousse "P4b. tag annoté au tagger hors noreply" refusé "refs/tags/v-essai2 $(git rev-parse v-essai2) refs/tags/v-essai2 $z"
git tag -a v-essai3 -m "version propre" "$base"
pousse "P4c. tag annoté propre" accepté "refs/tags/v-essai3 $(git rev-parse v-essai3) refs/tags/v-essai3 $z"
git tag -a v-essai4 -m "version propre" "$(git rev-parse v-essai1)" 2>/dev/null
pousse "P4d. tag annoté qui enveloppe un tag fautif" refusé "refs/tags/v-essai4 $(git rev-parse v-essai4) refs/tags/v-essai4 $z"
printf 'hote %s\n' "$ip" > m.txt; arbre=$(fige)
raison="non un commit"; pousse "P4e. tag vers un arbre (sans commit)" refusé "refs/tags/v-arbre $arbre refs/tags/v-arbre $z"
git tag -d v-essai1 v-essai2 v-essai3 v-essai4 >/dev/null
printf 'X\0%s\0' "$ip" > bin.dat; c=$(echo bin | git commit-tree "$(fige)" -p "$base")   # une IP : seul le diff peut la voir
pousse "P5. binaire poussé avec une IP" refusé "refs/heads/x $c refs/heads/x $base"
echo neutre > "photo-$nfd.jpg"; c1=$(echo nom | git commit-tree "$(fige)" -p "$base")
git read-tree "$c1"; git rm -q --cached "photo-$nfd.jpg"; c2=$(echo retrait | git commit-tree "$(git write-tree)" -p "$c1"); remet
pousse "P6. nom accentué ajouté puis retiré avant le push" refusé "refs/heads/x $c2 refs/heads/x $base"
printf 'chez %s\n' "$(printf '%s' "$tardive" | utf8 uc)" > ancien.txt; c7=$(echo ancien | git commit-tree "$(fige)" -p "$base")
git update-ref refs/remotes/origin/main "$c7"; liste_inventee "$tardive"
git read-tree "$c7"; echo neutre > n.txt; git add n.txt; c8=$(echo neutre | git commit-tree "$(git write-tree)" -p "$c7"); remet
pousse "P7. valeur ajoutée à la liste après coup (capitales)" refusé "refs/heads/main $c8 refs/heads/main $c7"
git update-ref -d refs/remotes/origin/main; liste_inventee
pousse "P8. suppression d'une branche" accepté "refs/heads/x $z refs/heads/x $base"
raison=": nom :"; pousse "P9. branche publiée sous un nom de la liste" refusé "refs/heads/main $base refs/heads/salon-$valeur $z"
git update-ref refs/remotes/prive/vieille "$fuite"; git init -q --bare "$tmp/public.git"
pousse "P10. branche neuve déjà suivie d'un autre remote" refusé "refs/heads/vieille $fuite refs/heads/vieille $z" public "$tmp/public.git"
git update-ref -d refs/remotes/prive/vieille
git update-ref refs/heads/publiee "$fuite"; git init -q --bare "$tmp/publie.git"
git -C "$tmp/publie.git" fetch -q "$R" refs/heads/publiee:refs/heads/main; git update-ref -d refs/heads/publiee
git read-tree "$fuite"; echo suite > s.txt; git add s.txt; suite=$(echo suite | git commit-tree "$(git write-tree)" -p "$fuite"); remet
pousse "P11. branche neuve sur un historique vraiment publié" accepté "refs/heads/suite $suite refs/heads/suite $z" origin "$tmp/publie.git"
git update-ref refs/remotes/origin/main "$fuite"   # suivi périmé : le remote a été purgé depuis
pousse "P12. branche neuve sur un suivi périmé" refusé "refs/heads/suite $suite refs/heads/suite $z" origin "$tmp/public.git"
git update-ref -d refs/remotes/origin/main
echo propre > m.txt; propre=$(echo propre | git commit-tree "$(fige)" -p "$base"); git replace "$fuite" "$propre"
pousse "P13. commit sale remplacé localement (git replace)" refusé "refs/heads/x $fuite refs/heads/x $base"
git replace -d "$fuite" > /dev/null
echo neutre > "releve-$ip.txt"; c7=$(echo ancien | git commit-tree "$(fige)" -p "$base"); git update-ref refs/remotes/origin/main "$c7"
git read-tree "$c7"; git rm -q --cached "releve-$ip.txt"; c8=$(echo nettoyage | git commit-tree "$(git write-tree)" -p "$c7"); remet
pousse "P14. nettoyage d'un nom fautif déjà publié" accepté "refs/heads/main $c8 refs/heads/main $c7"
git update-ref -d refs/remotes/origin/main
git update-ref refs/remotes/origin/main "$fuite"   # suivi local, mais le dépôt distant ne répond pas
raison="sans réponse"; pousse "P15. dépôt distant sans réponse : tout l'historique" refusé "refs/heads/suite $suite refs/heads/suite $z" origin "$tmp/absent.git"
git update-ref -d refs/remotes/origin/main

echo "-- erreurs de git (le garde doit refuser, pas laisser passer)"
printf 'contenu perdu %s\n' "$RANDOM" > e.txt; git add e.txt; blob=$(git rev-parse :e.txt)
rm -f ".git/objects/${blob:0:2}/${blob:2}" e.txt   # sans le fichier, git doit lire l'objet perdu
raison="lecture de l'index impossible"; cas "E1. objet illisible pendant l'examen de l'index" refusé .githooks/pre-commit
# objet perdu dans un commit poussé, absent de la tête : seul l'examen des commits le lit
printf 'contenu perdu %s\n' "$RANDOM" > e.txt; git add e.txt; blob=$(git rev-parse :e.txt); c1=$(echo e | git commit-tree "$(fige)" -p "$base")
git read-tree "$c1"; git rm -q --cached e.txt; c2=$(echo sans-e | git commit-tree "$(git write-tree)" -p "$c1"); remet
rm -f ".git/objects/${blob:0:2}/${blob:2}"
raison="lecture impossible"; pousse "E2. objet illisible dans un commit poussé" refusé "refs/heads/x $c2 refs/heads/x $base"
# objet perdu dans la tête, mais déjà publié : seul l'examen du contenu de l'arbre le lit
printf 'contenu perdu %s\n' "$RANDOM" > e.txt; git add e.txt; blob=$(git rev-parse :e.txt); c1=$(echo e | git commit-tree "$(fige)" -p "$base")
git read-tree "$c1"; echo n > n.txt; git add n.txt; c2=$(echo n | git commit-tree "$(git write-tree)" -p "$c1"); remet
rm -f ".git/objects/${blob:0:2}/${blob:2}"
raison="examen du contenu impossible"; pousse "E3. objet illisible dans l'arbre de la tête" refusé "refs/heads/x $c2 refs/heads/x $c1"

echo "-- installation hors de la copie extraite (--installe)"
git checkout -q --orphan sans-garde; git rm -q -r --cached . > /dev/null; rm -rf .githooks
echo x > x.txt; printf 'hote %s\n' "$ip" >> x.txt; git add x.txt
if sortie=$(git commit -q -m "sans garde" 2>&1); then r=accepté; else r=refusé; fi
note "I1. branche sans .githooks, core.hooksPath = .githooks (garde absent)" "$r" accepté "$sortie"
git checkout -q -f main; git branch -q -D sans-garde; git clean -qfdx -e garde.local.txt
.githooks/essai-garde.sh --installe > /dev/null || echo "installation impossible"
git checkout -q --orphan sans-garde; git rm -q -r --cached . > /dev/null; rm -rf .githooks
echo x > x.txt; printf 'hote %s\n' "$ip" >> x.txt; git add x.txt
if sortie=$(git commit -q -m "sans garde" 2>&1); then r=accepté; else r=refusé; fi
note "I2. même branche, garde installé dans .git/hooks (--installe)" "$r" refusé "$sortie"
git checkout -q -f main
if sortie=$(.githooks/essai-garde.sh --installe 2>&1); then r=accepté; else r=refusé; fi
note "I3. réinstallation par-dessus le garde déjà installé" "$r" accepté "$sortie"

echo
if [ "$ecarts" -eq 0 ]; then echo "Aucun écart : le garde se comporte comme attendu."; else echo "$ecarts écart(s)."; fi
if ! git -C "$ici" rev-parse > /dev/null 2>&1; then :   # script lancé hors d'un dépôt
elif actif=$(dossier_actif); [ "$actif" = "$(git -C "$ici" rev-parse --show-toplevel)/.githooks" ]; then
  echo "Garde actif (core.hooksPath = .githooks), mais il suit la branche extraite : préférer .githooks/essai-garde.sh --installe"
else
  ecart_install=0
  for f in "${crochets[@]}"; do cmp -s "$ici/$f" "$actif/$f" || ecart_install=1; done
  if [ "$ecart_install" = 0 ]; then echo "Garde actif, installé dans .git/hooks, identique à .githooks."
  else echo "ATTENTION : le garde actif ($actif) diffère de .githooks ou manque : .githooks/essai-garde.sh --installe"; fi
fi
[ "$ecarts" -eq 0 ]
