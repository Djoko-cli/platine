package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// La boucle de bout en bout : un événement d'OwnTone qui joue donne un start après le regroupement ; le jeton de session
// qui arrive ensuite ne donne aucune push de plus.
func TestBoucleDeBoutEnBout(t *testing.T) {
	_, fichier := cleEssai(t)
	evenements := make(chan string, 8)
	apple := httptest.NewUnstartedServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		var charge struct {
			Aps struct {
				Event string `json:"event"`
			} `json:"aps"`
		}
		json.NewDecoder(r.Body).Decode(&charge)
		evenements <- charge.Aps.Event
	}))
	apple.EnableHTTP2 = true
	apple.StartTLS()
	t.Cleanup(apple.Close)
	a, err := NouvelAPNs(apple.URL, "io.example.app", "EQUIPE0001", "CLE0000001", fichier)
	if err != nil {
		t.Fatal(err)
	}
	a.client = apple.Client()
	o, _ := NouvelOwnTone(fauxOwnTone(t).URL, "ws://inutilise", "https://portier.example")
	j, _ := OuvrirJetons(filepath.Join(t.TempDir(), "jetons.json"))
	j.Enregistrer(JetonDemarrage, "", jetonEssai)
	r := NouveauRelais(o, a, j, slog.New(slog.NewTextHandler(io.Discard, nil)))

	ctx, arreter := context.WithCancel(context.Background())
	defer arreter()
	go r.Tourner(ctx)
	r.Signaler()
	select {
	case e := <-evenements:
		if e != Demarrer {
			t.Fatalf("première push : %s, attendu start", e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("aucune push 5 s après l'événement")
	}

	w := httptest.NewRecorder()
	corps := `{"type":"session","session":"owntone","jeton":"` + strings.Repeat("b", 64) + `"}`
	r.RecevoirJeton(w, httptest.NewRequest(http.MethodPost, "/platine/jetons", strings.NewReader(corps)))
	select {
	case e := <-evenements:
		t.Errorf("push %s après le jeton de session : la carte a déjà l'état du start", e)
	case <-time.After(2 * regroupement):
	}
}
