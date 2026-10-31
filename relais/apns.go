// L'envoi des push à APNs : HTTP/2, jeton d'authentification JWT (ES256) signé avec la clé APNs, renouvelé toutes les
// 50 minutes (Apple le refuse au-delà d'une heure, et s'il change plus souvent que toutes les 20 minutes).
package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"
)

const dureeJWT = 50 * time.Minute

type APNs struct {
	serveur string // https://api.sandbox.push.apple.com tant que l'app passe par Xcode
	sujet   string // <identifiant de l'app>.push-type.nowplaying
	equipe  string
	idCle   string
	cle     *ecdsa.PrivateKey
	client  *http.Client

	jwt   string
	jwtDe time.Time
}

// RefusAPNs : APNs a répondu, mais pas 200.
type RefusAPNs struct {
	Statut int
	Raison string
}

func (r *RefusAPNs) Error() string { return fmt.Sprintf("APNs : HTTP %d %s", r.Statut, r.Raison) }

// JetonInvalide : le jeton push n'est plus bon (app désinstallée, session finie, jeton d'un autre environnement).
func (r *RefusAPNs) JetonInvalide() bool {
	switch r.Raison {
	case "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken":
		return true
	}
	return r.Statut == http.StatusGone
}

// Passager : réessayer plus tard peut réussir (Apple surchargé, jeton d'authentification à refaire).
func (r *RefusAPNs) Passager() bool {
	return r.Statut == http.StatusTooManyRequests || r.Statut >= 500 ||
		r.Raison == "ExpiredProviderToken" || r.Raison == "InvalidProviderToken"
}

func NouvelAPNs(serveur, app, equipe, idCle, fichierCle string) (*APNs, error) {
	pemCle, err := os.ReadFile(fichierCle)
	if err != nil {
		return nil, fmt.Errorf("clé APNs illisible : %w", err)
	}
	bloc, _ := pem.Decode(pemCle)
	if bloc == nil {
		return nil, errors.New("clé APNs : pas de bloc PEM")
	}
	cle, err := x509.ParsePKCS8PrivateKey(bloc.Bytes)
	if err != nil {
		return nil, fmt.Errorf("clé APNs : %w", err)
	}
	ec, ok := cle.(*ecdsa.PrivateKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, errors.New("clé APNs : pas une clé ECDSA P-256")
	}
	return &APNs{
		serveur: serveur,
		sujet:   app + ".push-type.nowplaying",
		equipe:  equipe,
		idCle:   idCle,
		cle:     ec,
		client: &http.Client{
			Timeout:   15 * time.Second,
			Transport: &http.Transport{ForceAttemptHTTP2: true, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}},
		},
	}, nil
}

func base64URL(octets []byte) string { return base64.RawURLEncoding.EncodeToString(octets) }

func (a *APNs) jetonAuthentification(maintenant time.Time) (string, error) {
	if a.jwt != "" && maintenant.Sub(a.jwtDe) < dureeJWT {
		return a.jwt, nil
	}
	entete, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.idCle})
	corps, _ := json.Marshal(map[string]any{"iss": a.equipe, "iat": maintenant.Unix()})
	signe := base64URL(entete) + "." + base64URL(corps)
	empreinte := sha256.Sum256([]byte(signe))
	r, s, err := ecdsa.Sign(rand.Reader, a.cle, empreinte[:])
	if err != nil {
		return "", err
	}
	// JWT ES256 : r et s bout à bout, 32 octets chacun (pas le DER de l'ASN.1).
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	a.jwt, a.jwtDe = signe+"."+base64URL(signature), maintenant
	return a.jwt, nil
}

// charge : le corps d'une push nowplaying. Pour end, les attributs se réduisent à l'identifiant de la session.
func charge(p Push, maintenant time.Time) ([]byte, error) {
	var attributs any = p.Attributs
	if p.Evenement == Terminer {
		attributs = map[string]string{"id": idSession}
	}
	return json.Marshal(map[string]any{
		"aps": map[string]any{"event": p.Evenement, "timestamp": maintenant.Unix(), "attributes": attributs},
	})
}

// Envoyer envoie la push au jeton donné. Renvoie un *RefusAPNs quand APNs répond autre chose que 200.
func (a *APNs) Envoyer(ctx context.Context, jeton string, p Push) error {
	maintenant := time.Now()
	corps, err := charge(p, maintenant)
	if err != nil {
		return err
	}
	authentification, err := a.jetonAuthentification(maintenant)
	if err != nil {
		return err
	}
	demande, err := http.NewRequestWithContext(ctx, http.MethodPost, a.serveur+"/3/device/"+jeton, bytes.NewReader(corps))
	if err != nil {
		return errors.New("adresse APNs invalide") // l'erreur d'origine citerait le jeton
	}
	demande.Header.Set("authorization", "bearer "+authentification)
	demande.Header.Set("apns-push-type", "nowplaying")
	demande.Header.Set("apns-topic", a.sujet)
	demande.Header.Set("apns-priority", "10")
	demande.Header.Set("content-type", "application/json")
	reponse, err := a.client.Do(demande)
	if err != nil {
		// L'erreur de net/http cite l'adresse, donc le jeton push en entier : on n'en garde que la cause.
		var erreurURL *url.Error
		if errors.As(err, &erreurURL) {
			return fmt.Errorf("APNs injoignable : %w", erreurURL.Err)
		}
		return err
	}
	defer reponse.Body.Close()
	if reponse.StatusCode == http.StatusOK {
		return nil
	}
	var erreur struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(reponse.Body).Decode(&erreur)
	if erreur.Reason == "ExpiredProviderToken" || erreur.Reason == "InvalidProviderToken" {
		a.jwt = "" // renouvelé à la prochaine push
	}
	return &RefusAPNs{Statut: reponse.StatusCode, Raison: erreur.Reason}
}
