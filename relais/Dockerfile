# Le relais, compilé sur le Mac par relais/deployer.sh (binaire statique linux/amd64). L'image de base apporte les
# certificats racines (pour joindre APNs) et les fuseaux horaires, rien d'autre : ni shell ni gestionnaire de paquets.
# Épinglée par son empreinte (relevée le 31/10/2026) : une nouvelle version n'entre que par un changement de ce fichier.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY relais /relais
ENTRYPOINT ["/relais"]
