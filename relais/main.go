// Le relais des push de Platine (docs/specs/2026-10-31-push-nowplaying.md) : il écoute OwnTone sur le NAS et tient la
// carte « en cours de lecture » de l'iPhone à jour par des push nowplaying, app fermée. Il ne parle qu'en local et ne
// sort que vers APNs ; les jetons de l'iPhone lui arrivent par le portier.
//
// Réglages par l'environnement (relais/.env sur le NAS, jamais versionné) : voir relais/compose.yaml.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func reglage(nom, defaut string) string {
	if v := os.Getenv(nom); v != "" {
		return v
	}
	return defaut
}

func obligatoire(nom string) (string, error) {
	if v := os.Getenv(nom); v != "" {
		return v, nil
	}
	return "", fmt.Errorf("%s manquant", nom)
}

func main() {
	journal := slog.New(slog.NewTextHandler(ouvrirJournal(), nil))
	if err := lancer(journal); err != nil {
		journal.Error("arrêt du relais", "erreur", err)
		os.Exit(1)
	}
}

func lancer(journal *slog.Logger) error {
	portier, err := obligatoire("PORTIER")
	if err != nil {
		return err
	}
	equipe, err := obligatoire("APNS_EQUIPE")
	if err != nil {
		return err
	}
	idCle, err := obligatoire("APNS_CLE_ID")
	if err != nil {
		return err
	}
	owntone, err := NouvelOwnTone(reglage("OWNTONE", "http://127.0.0.1:3689"), reglage("OWNTONE_WS", "ws://127.0.0.1:3688"), portier)
	if err != nil {
		return err
	}
	serveurAPNs := reglage("APNS_SERVEUR", "https://api.sandbox.push.apple.com")
	apns, err := NouvelAPNs(serveurAPNs, reglage("APP", "io.github.djoko-cli.platine"), equipe, idCle,
		reglage("APNS_CLE", "/cle/AuthKey.p8"))
	if err != nil {
		return err
	}
	jetons, err := OuvrirJetons(reglage("JETONS", "/donnees/jetons.json"))
	if err != nil {
		return fmt.Errorf("fichier des jetons : %w", err)
	}
	relais := NouveauRelais(owntone, apns, jetons, journal)

	ctx, arreter := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer arreter()

	routes := http.NewServeMux()
	routes.HandleFunc("/platine/jetons", relais.RecevoirJeton)
	serveur := &http.Server{
		Addr:              reglage("ECOUTE", "127.0.0.1:18090"),
		Handler:           routes,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second, // une réponse peut attendre la boucle, le temps d'une push
	}
	erreurServeur := make(chan error, 1)
	go func() { erreurServeur <- serveur.ListenAndServe() }()

	journal.Info("relais démarré", "ecoute", serveur.Addr, "apns", serveurAPNs,
		"jeton de démarrage", jetons.Demarrage() != "", "session ouverte", relais.decideur.Ouverte())
	go owntone.Ecouter(ctx, relais.Signaler, journal)
	go relais.Tourner(ctx)

	select {
	case <-ctx.Done():
	case err := <-erreurServeur:
		return err
	}
	fermeture, fin := context.WithTimeout(context.Background(), 5*time.Second)
	defer fin()
	if err := serveur.Shutdown(fermeture); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	journal.Info("relais arrêté")
	return nil
}
