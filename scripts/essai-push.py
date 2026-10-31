#!/usr/bin/env python3
"""Essai témoin des push nowplaying de Platine, depuis le Mac (étape 0 de la spec des push).

Usage : /usr/bin/python3 -I scripts/essai-push.py recuperer         lit les jetons push dans le conteneur partagé de l'iPhone
                                                                    (aussi pour relais/banc.sh jetons)
        /usr/bin/python3 -I scripts/essai-push.py journal           affiche le journal de l'extension
        /usr/bin/python3 -I scripts/essai-push.py start|update|end  envoie une push avec l'état réel d'OwnTone (portier)

Lit l'équipe, le portier et son jeton dans Config/Local.xcconfig, la clé APNs dans ~/.config/platine/apns/AuthKey_*.p8.
N'affiche jamais la clé, le jeton du portier, le jeton d'authentification APNs ni les jetons push en entier.
"""
import base64
import glob
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOSSIER = os.path.expanduser("~/.config/platine/apns")
JETONS = os.path.join(DOSSIER, "jetons-push.json")
APP = "io.github.djoko-cli.platine"
GROUPE = "group.io.github.djoko-cli.platine"
ID_SESSION = "owntone"
APNS = "https://api.sandbox.push.apple.com"


def reglages():
    valeurs = {}
    with open(os.path.join(RACINE, "Config", "Local.xcconfig")) as f:
        for ligne in f:
            if "=" in ligne and not ligne.lstrip().startswith("//"):
                cle, valeur = ligne.split("=", 1)
                valeurs[cle.strip()] = valeur.strip().replace("$()", "")
    return valeurs


def iphone():
    with tempfile.NamedTemporaryFile(suffix=".json") as sortie:
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", sortie.name],
                       check=True, capture_output=True)
        for appareil in json.load(open(sortie.name))["result"]["devices"]:
            materiel = appareil.get("hardwareProperties", {})
            if materiel.get("reality") == "physical" and materiel.get("deviceType") == "iPhone":
                return materiel["udid"]
    sys.exit("aucun iPhone physique")


def copier_depuis_iphone(nom):
    """Le contenu d'un fichier de Library/Caches dans le conteneur partagé de l'app."""
    with tempfile.TemporaryDirectory() as dossier:
        copie = os.path.join(dossier, nom)
        r = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", iphone(),
                            "--domain-type", "appGroupDataContainer", "--domain-identifier", GROUPE,
                            "--source", "Library/Caches/" + nom, "--destination", copie], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(copie):
            sys.exit("copie impossible : " + (r.stderr.strip().splitlines() or ["?"])[-1])
        return open(copie).read()


def journal():
    for ligne in copier_depuis_iphone("journal-extension.txt").splitlines()[-40:]:
        print(ligne)


def recuperer():
    os.makedirs(DOSSIER, mode=0o700, exist_ok=True)
    # Un fichier par processus : le jeton de démarrage vient de l'app, ceux des sessions de l'extension.
    contenu = {"demarrage": None, "sessions": {}}
    lus = 0
    for nom, lire in (("jetons-demarrage.json", lambda c: contenu.update(demarrage=c.get("demarrage"))),
                      ("jetons-session.json", lambda c: contenu["sessions"].update(c))):
        try:
            lire(json.loads(copier_depuis_iphone(nom)))
            lus += 1
        except SystemExit as absent:
            print(f"{nom} : {absent}")
    if not lus:
        sys.exit("aucun fichier de jetons lu : " + JETONS + " reste tel quel")
    descripteur = os.open(JETONS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descripteur, "w") as f:
        json.dump(contenu, f)
    demarrage = contenu.get("demarrage")
    print("jeton de démarrage :", "…" + demarrage[-4:] if demarrage else "absent")
    for session, jeton in contenu.get("sessions", {}).items():
        print(f"jeton de la session « {session} » : …{jeton[-4:]}")


def lire_owntone(portier, jeton, chemin):
    demande = urllib.request.Request(urllib.parse.urljoin(portier + "/", chemin),
                                     headers={"Authorization": "Bearer " + jeton})
    with urllib.request.urlopen(demande, timeout=8) as reponse:
        return json.load(reponse)


def attributs(portier, jeton):
    """Le même état que ClientOwnTone.lireEtat dans l'app (contrat PlatineAttributs)."""
    lecteur = lire_owntone(portier, jeton, "api/player")
    sorties = lire_owntone(portier, jeton, "api/outputs")["outputs"]
    piste = None
    if lecteur["item_id"]:
        piste = next((e for e in lire_owntone(portier, jeton, "api/queue")["items"] if e["id"] == lecteur["item_id"]),
                     None)
    piste = piste or {}
    pochette = piste.get("artwork_url")
    return {
        "id": ID_SESSION,
        "serveur": portier,
        "etat": lecteur["state"],
        "pisteID": piste.get("id", 0),
        "titre": piste.get("title", ""),
        "artiste": piste.get("artist", ""),
        "album": piste.get("album", ""),
        "pochette": urllib.parse.urljoin(portier + "/", pochette) if pochette else "",
        "dureeMs": piste.get("length_ms", lecteur["item_length_ms"]),
        "positionMs": lecteur["item_progress_ms"],
        "horodatage": time.time(),
        "appareils": [{"id": s["id"], "nom": s["name"], "volume": s["volume"]} for s in sorties if s["selected"]],
    }


def b64(octets):
    return base64.urlsafe_b64encode(octets).rstrip(b"=").decode()


def der_vers_brut(der):
    """Signature ECDSA DER (SEQUENCE de deux INTEGER) vers r||s sur 64 octets, comme l'attend JWT ES256."""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    morceaux = []
    for _ in range(2):
        assert der[i] == 0x02
        longueur = der[i + 1]
        morceaux.append(der[i + 2:i + 2 + longueur].lstrip(b"\x00").rjust(32, b"\x00"))
        i += 2 + longueur
    return b"".join(morceaux)


def jeton_apns(cle, id_cle, equipe):
    entete = b64(json.dumps({"alg": "ES256", "kid": id_cle}).encode())
    corps = b64(json.dumps({"iss": equipe, "iat": int(time.time())}).encode())
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", cle], input=f"{entete}.{corps}".encode(),
                               capture_output=True, check=True).stdout
    return f"{entete}.{corps}.{b64(der_vers_brut(signature))}"


def envoyer(evenement):
    r = reglages()
    cles = glob.glob(os.path.join(DOSSIER, "AuthKey_*.p8"))
    if len(cles) != 1:
        sys.exit("il faut exactement une clé AuthKey_*.p8 dans ~/.config/platine/apns")
    id_cle = os.path.basename(cles[0])[len("AuthKey_"):-len(".p8")]
    jetons = json.load(open(JETONS))
    cible = jetons.get("demarrage") if evenement == "start" else jetons.get("sessions", {}).get(ID_SESSION)
    if not cible:
        sys.exit("jeton absent : lancer d'abord « recuperer » (et, pour update ou end, démarrer la session)")
    if evenement == "end":
        etat = {"id": ID_SESSION}
    else:
        etat = attributs(r["PLATINE_PORTIER"], r["PLATINE_JETON"])
    charge = {"aps": {"event": evenement, "timestamp": int(time.time()), "attributes": etat}}
    with tempfile.TemporaryDirectory() as dossier:
        entetes = os.path.join(dossier, "entetes")
        descripteur = os.open(entetes, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(descripteur, "w") as f:
            f.write("authorization: bearer " + jeton_apns(cles[0], id_cle, r["DEVELOPMENT_TEAM"]) + "\n")
            f.write("apns-push-type: nowplaying\n")
            f.write(f"apns-topic: {APP}.push-type.nowplaying\n")
            f.write("apns-priority: 10\n")
        corps = os.path.join(dossier, "corps.json")
        with open(corps, "w") as f:
            json.dump(charge, f)
        reponse = subprocess.run(["curl", "-s", "--http2", "-m", "15", "-H", "@" + entetes, "--data-binary", "@" + corps,
                                  "-D", "-", f"{APNS}/3/device/{cible}"], capture_output=True, text=True).stdout
    statut = next((l.split()[1] for l in reponse.splitlines() if l.startswith("HTTP/")), "?")
    apns_id = next((l.split(":", 1)[1].strip() for l in reponse.splitlines() if l.lower().startswith("apns-id")), "?")
    raison = reponse.split("\r\n\r\n", 1)[-1].strip() if "\r\n\r\n" in reponse else ""
    print(f"push {evenement} vers …{cible[-4:]} : HTTP {statut}, apns-id {apns_id} {raison}".rstrip())
    if evenement != "end":
        print(f"  état envoyé : {etat['etat']}, piste {etat['pisteID']}, {len(etat['appareils'])} appareil(s), "
              f"{len(json.dumps(charge))} octets")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("recuperer", "journal", "start", "update", "end"):
        sys.exit(__doc__)
    {"recuperer": recuperer, "journal": journal}.get(sys.argv[1], lambda: envoyer(sys.argv[1]))()
