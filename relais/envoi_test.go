package main

// Les suites d'une push selon la réponse d'APNs : ce que le relais garde, oublie ou retente.

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// relaisEssai : un relais dont APNs répond statut (et raison, si elle n'est pas vide), avec un jeton de session.
func relaisEssai(t *testing.T, statut *atomic.Int32, raison string) (*Relais, *bytes.Buffer) {
	t.Helper()
	_, fichier := cleEssai(t)
	apple := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(int(statut.Load()))
		if raison != "" {
			fmt.Fprintf(w, `{"reason":%q}`, raison)
		}
	}))
	apple.EnableHTTP2 = true
	apple.StartTLS()
	t.Cleanup(apple.Close)
	a, err := NouvelAPNs(apple.URL, "io.example.app", "EQUIPE0001", "CLE0000001", fichier)
	if err != nil {
		t.Fatal(err)
	}
	a.client = apple.Client()
	j, _ := OuvrirJetons(filepath.Join(t.TempDir(), "jetons.json"))
	j.Enregistrer(JetonDemarrage, "", jetonEssai)
	j.Enregistrer(JetonSession, idSession, jetonEssai)
	var journal bytes.Buffer
	return NouveauRelais(nil, a, j, slog.New(slog.NewTextHandler(&journal, nil))), &journal
}

func statutAPNs(s int) *atomic.Int32 {
	var v atomic.Int32
	v.Store(int32(s))
	return &v
}

func TestEndRetenteSurPanne(t *testing.T) {
	statut := statutAPNs(http.StatusServiceUnavailable)
	r, _ := relaisEssai(t, statut, "")
	r.decideur.Observer(etat("stop", 0, 0, t0), t0)
	fin := t0.Add(finApresArret)
	r.envoyer(context.Background(), *r.decideur.Echeance(fin))
	if r.jetons.Session(idSession) == "" || !r.decideur.Ouverte() {
		t.Fatal("end en échec passager : la session doit rester, pour un nouvel essai")
	}
	statut.Store(http.StatusOK)
	p := r.decideur.Echeance(fin.Add(reessaiFin))
	attendre(t, "nouvel essai", p, Terminer)
	r.envoyer(context.Background(), *p)
	if r.jetons.Session(idSession) != "" || r.decideur.Ouverte() {
		t.Error("end envoyé : session et jeton oubliés")
	}
	if _, err := r.jetons.Enregistrer(JetonSession, idSession, jetonEssai); err != ErrJetonTermine {
		t.Errorf("le jeton de la session finie ne doit plus être repris : %v", err)
	}
}

func TestEndRefusePourDeBon(t *testing.T) {
	r, _ := relaisEssai(t, statutAPNs(http.StatusBadRequest), "BadPayload")
	r.decideur.Observer(etat("stop", 0, 0, t0), t0)
	r.envoyer(context.Background(), *r.decideur.Echeance(t0.Add(finApresArret)))
	if r.decideur.Ouverte() {
		t.Error("un end refusé pour de bon ne doit pas être retenté toutes les 30 s")
	}
}

func TestUpdateAuJetonPerime(t *testing.T) {
	r, journal := relaisEssai(t, statutAPNs(http.StatusGone), "Unregistered")
	r.envoyer(context.Background(), *r.decideur.Observer(etat("play", 1, 0, t0), t0))
	if r.jetons.Session(idSession) != "" || r.decideur.Ouverte() {
		t.Error("jeton périmé : oublié, et la session avec")
	}
	attendre(t, "lecture suivante", r.decideur.Observer(etat("play", 1, 0, t0), t0), Demarrer)
	if !strings.Contains(journal.String(), "jeton refusé") {
		t.Errorf("journal : %s", journal)
	}
}

func TestStartAttendLeJetonDeSession(t *testing.T) {
	r, _ := relaisEssai(t, statutAPNs(http.StatusOK), "")
	r.decideur = NouveauDecideur(false)
	r.envoyer(context.Background(), *r.decideur.Observer(etat("play", 1, 0, t0), t0))
	if r.attenteJeton == nil || !r.decideur.Ouverte() {
		t.Error("start envoyé : session ouverte, jeton de session attendu")
	}
}

func TestPanneReseauSansJetonAuJournal(t *testing.T) {
	r, journal := relaisEssai(t, statutAPNs(http.StatusOK), "")
	r.apns.serveur = "https://127.0.0.1:1" // rien n'écoute
	r.envoyer(context.Background(), *r.decideur.Observer(etat("play", 1, 0, t0), t0))
	if strings.Contains(journal.String(), jetonEssai) {
		t.Fatalf("jeton push entier dans le journal : %s", journal)
	}
	if !strings.Contains(journal.String(), "push en échec") {
		t.Errorf("journal : %s", journal)
	}
	// Échec passager : la prochaine observation renvoie l'état, même inchangé.
	attendre(t, "après la panne", r.decideur.Observer(etat("play", 1, 0, t0), t0), MettreAJour)
}
