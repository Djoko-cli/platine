# Le relais, compilé sur le Mac par relais/deployer.sh (binaire statique linux/amd64). L'image de base apporte les
# certificats racines (pour joindre APNs) et les fuseaux horaires, rien d'autre : ni shell ni gestionnaire de paquets.
FROM gcr.io/distroless/static-debian12:nonroot
COPY relais /relais
ENTRYPOINT ["/relais"]
