package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const jetonEssai = "00000000000000000000000000000000000000000000000000000000000000a1"

func cleEssai(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	cle, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(cle)
	fichier := filepath.Join(t.TempDir(), "AuthKey_ESSAI.p8")
	os.WriteFile(fichier, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	return cle, fichier
}

func TestPushVersAPNs(t *testing.T) {
	cle, fichier := cleEssai(t)
	var recue *http.Request
	var corps []byte
	apple := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recue, corps = r, must(io.ReadAll(r.Body))
		if strings.HasSuffix(r.URL.Path, "perime") {
			w.WriteHeader(http.StatusGone)
			w.Write([]byte(`{"reason":"Unregistered"}`))
		}
	}))
	apple.EnableHTTP2 = true
	apple.StartTLS()
	defer apple.Close()

	a, err := NouvelAPNs(apple.URL, "io.example.app", "EQUIPE0001", "CLE0000001", fichier)
	if err != nil {
		t.Fatal(err)
	}
	a.client = apple.Client()
	p := Push{Evenement: MettreAJour, Attributs: etat("play", 7, 1000, t0, 40)}
	if err := a.Envoyer(context.Background(), jetonEssai, p); err != nil {
		t.Fatal(err)
	}
	if recue.ProtoMajor != 2 {
		t.Errorf("protocole %s, attendu HTTP/2", recue.Proto)
	}
	if recue.URL.Path != "/3/device/"+jetonEssai {
		t.Errorf("chemin %s", recue.URL.Path)
	}
	for nom, voulu := range map[string]string{"apns-push-type": "nowplaying", "apns-topic": "io.example.app.push-type.nowplaying"} {
		if got := recue.Header.Get(nom); got != voulu {
			t.Errorf("%s : %q", nom, got)
		}
	}
	var charge struct {
		Aps struct {
			Event      string         `json:"event"`
			Timestamp  int64          `json:"timestamp"`
			Attributes map[string]any `json:"attributes"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(corps, &charge); err != nil {
		t.Fatal(err)
	}
	if charge.Aps.Event != "update" || charge.Aps.Attributes["pisteID"] != 7.0 || charge.Aps.Timestamp == 0 {
		t.Errorf("charge inattendue : %s", corps)
	}
	if _, ok := charge.Aps.Attributes["horodatage"].(float64); !ok {
		t.Errorf("horodatage doit être un nombre : %s", corps)
	}
	verifierJWT(t, strings.TrimPrefix(recue.Header.Get("authorization"), "bearer "), &cle.PublicKey)

	// Le jeton d'authentification est gardé d'une push à l'autre.
	premier := recue.Header.Get("authorization")
	a.Envoyer(context.Background(), jetonEssai, Push{Evenement: Terminer})
	if recue.Header.Get("authorization") != premier {
		t.Error("jeton d'authentification renouvelé trop tôt")
	}
	if !strings.Contains(string(corps), `"attributes":{"id":"owntone"}`) {
		t.Errorf("end : %s", corps)
	}

	err = a.Envoyer(context.Background(), "perime", p)
	refus, ok := err.(*RefusAPNs)
	if !ok || !refus.JetonInvalide() {
		t.Errorf("jeton périmé : %v", err)
	}
}

func verifierJWT(t *testing.T, jwt string, cle *ecdsa.PublicKey) {
	t.Helper()
	morceaux := strings.Split(jwt, ".")
	if len(morceaux) != 3 {
		t.Fatalf("JWT mal formé")
	}
	var entete map[string]string
	json.Unmarshal(must(base64.RawURLEncoding.DecodeString(morceaux[0])), &entete)
	if entete["alg"] != "ES256" || entete["kid"] != "CLE0000001" {
		t.Errorf("en-tête JWT : %v", entete)
	}
	signature := must(base64.RawURLEncoding.DecodeString(morceaux[2]))
	empreinte := sha256.Sum256([]byte(morceaux[0] + "." + morceaux[1]))
	r, s := new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])
	if len(signature) != 64 || !ecdsa.Verify(cle, empreinte[:], r, s) {
		t.Error("signature JWT invalide")
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func TestJetonsGardesEtRecus(t *testing.T) {
	fichier := filepath.Join(t.TempDir(), "jetons.json")
	j, _ := OuvrirJetons(fichier)
	r := NouveauRelais(nil, nil, j, slog.New(slog.NewTextHandler(io.Discard, nil)))

	poster := func(corps string) int {
		w := httptest.NewRecorder()
		r.RecevoirJeton(w, httptest.NewRequest(http.MethodPost, "/platine/jetons", strings.NewReader(corps)))
		return w.Code
	}
	if code := poster(`{"type":"session","session":"owntone","jeton":"` + jetonEssai + `"}`); code != http.StatusNoContent {
		t.Fatalf("jeton valide : HTTP %d", code)
	}
	if got := <-r.jetonsRecus; got != (jetonRecu{JetonSession, true}) {
		t.Errorf("signal : %+v", got)
	}
	poster(`{"type":"session","session":"owntone","jeton":"` + jetonEssai + `"}`)
	if got := <-r.jetonsRecus; got.nouveau {
		t.Error("le même jeton n'est pas nouveau")
	}
	for _, mauvais := range []string{
		`{"type":"autre","jeton":"` + jetonEssai + `"}`,
		`{"type":"session","session":"ailleurs","jeton":"` + jetonEssai + `"}`,
		`{"type":"demarrage","jeton":"ZZ` + jetonEssai + `"}`,
		`{"type":"demarrage","jeton":"` + jetonEssai + `","en_trop":1}`,
		`{"type":"demarrage","jeton":"` + strings.Repeat("a", 2000) + `"}`,
	} {
		if code := poster(mauvais); code != http.StatusBadRequest {
			t.Errorf("%.60s… : HTTP %d", mauvais, code)
		}
	}

	info, err := os.Stat(fichier)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("fichier des jetons : %v %v", info.Mode(), err)
	}
	relu, _ := OuvrirJetons(fichier)
	if relu.Session(idSession) != jetonEssai {
		t.Error("jeton perdu au redémarrage")
	}

	// Après end, le même jeton redonné par l'extension ne rouvre pas la session, même après un redémarrage.
	j.OublierSession(idSession, jetonEssai)
	if _, err := j.Enregistrer(JetonSession, idSession, jetonEssai); err != ErrJetonTermine {
		t.Errorf("jeton d'une session terminée : %v", err)
	}
	relu, _ = OuvrirJetons(fichier)
	if _, err := relu.Enregistrer(JetonSession, idSession, jetonEssai); err != ErrJetonTermine {
		t.Errorf("jeton d'une session terminée, après un redémarrage : %v", err)
	}
}

func TestOublierGardeLeJetonPlusRecent(t *testing.T) {
	j, _ := OuvrirJetons(filepath.Join(t.TempDir(), "jetons.json"))
	ancien, recent := strings.Repeat("a", 64), strings.Repeat("b", 64)
	j.Enregistrer(JetonSession, idSession, ancien)
	j.Enregistrer(JetonSession, idSession, recent) // arrivé pendant l'envoi qui a fini l'ancienne session
	j.OublierSession(idSession, ancien)
	if j.Session(idSession) != recent {
		t.Error("le jeton de la nouvelle session a été effacé avec l'ancien")
	}
	j.Enregistrer(JetonDemarrage, "", recent)
	j.OublierDemarrage(ancien)
	if j.Demarrage() != recent {
		t.Error("jeton de démarrage plus récent effacé")
	}
	// La liste des jetons finis reste bornée.
	for i := range 2 * maxTermines {
		j.OublierSession(idSession, fmt.Sprintf("%064x", i))
	}
	if n := len(j.contenu.Termines); n != maxTermines {
		t.Errorf("%d jetons finis gardés, attendu %d", n, maxTermines)
	}
}

func TestJetonOublieEnAttenteNeRouvrePas(t *testing.T) {
	j, _ := OuvrirJetons(filepath.Join(t.TempDir(), "jetons.json"))
	r := NouveauRelais(nil, nil, j, slog.New(slog.NewTextHandler(io.Discard, nil)))
	// Le jeton est arrivé, puis a été oublié (end envoyé) avant que la boucle lise son message.
	j.Enregistrer(JetonSession, idSession, jetonEssai)
	j.OublierSession(idSession, jetonEssai)
	r.prendreJeton(jetonRecu{genre: JetonSession, nouveau: false})
	if r.decideur.Ouverte() {
		t.Error("session rouverte sans jeton : le prochain start serait bloqué")
	}
}
