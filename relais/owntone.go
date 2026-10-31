// L'écoute d'OwnTone : sa websocket signale les changements, son API JSON donne l'état, mis en forme comme
// PlatineAttributs dans l'app (Commun/OwnTone.swift).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// L'identifiant de la session distante, le même que dans l'app.
const idSession = "owntone"

// Attributs : exactement la structure PlatineAttributs de l'app. Un champ renommé ici doit l'être là-bas, sinon iOS
// rejette la push sans réveiller l'extension.
type Attributs struct {
	ID         string     `json:"id"`
	Serveur    string     `json:"serveur"`
	Etat       string     `json:"etat"` // "play", "pause" ou "stop"
	PisteID    int        `json:"pisteID"`
	Titre      string     `json:"titre"`
	Artiste    string     `json:"artiste"`
	Album      string     `json:"album"`
	Pochette   string     `json:"pochette"`
	DureeMs    int        `json:"dureeMs"`
	PositionMs int        `json:"positionMs"`
	Horodatage float64    `json:"horodatage"` // secondes depuis 1970 : une date en texte fait rejeter la push
	Appareils  []Appareil `json:"appareils"`
}

type Appareil struct {
	ID     string `json:"id"`
	Nom    string `json:"nom"`
	Volume int    `json:"volume"`
}

type OwnTone struct {
	api     *url.URL // l'API JSON, en local sur le NAS
	ws      string   // la websocket, en local aussi
	portier *url.URL // l'adresse publique du portier : celle que l'extension joint, pour les commandes et la pochette
	client  *http.Client
}

func NouvelOwnTone(api, ws, portier string) (*OwnTone, error) {
	a, err := url.Parse(api)
	if err != nil || a.Host == "" {
		return nil, fmt.Errorf("adresse d'OwnTone invalide : %q", api)
	}
	p, err := url.Parse(portier)
	if err != nil || p.Host == "" {
		return nil, fmt.Errorf("adresse du portier invalide : %q", portier)
	}
	return &OwnTone{api: a, ws: ws, portier: p, client: &http.Client{Timeout: 8 * time.Second}}, nil
}

func (o *OwnTone) lire(ctx context.Context, chemin string, requete url.Values, v any) error {
	adresse := o.api.JoinPath(chemin)
	adresse.RawQuery = requete.Encode()
	demande, err := http.NewRequestWithContext(ctx, http.MethodGet, adresse.String(), nil)
	if err != nil {
		return err
	}
	reponse, err := o.client.Do(demande)
	if err != nil {
		return err
	}
	defer reponse.Body.Close()
	if reponse.StatusCode != http.StatusOK {
		return fmt.Errorf("%s : HTTP %d", chemin, reponse.StatusCode)
	}
	return json.NewDecoder(reponse.Body).Decode(v)
}

// Etat relit OwnTone, comme ClientOwnTone.lireEtat dans l'app.
func (o *OwnTone) Etat(ctx context.Context) (Attributs, error) {
	var lecteur struct {
		State          string `json:"state"`
		ItemID         int    `json:"item_id"`
		ItemLengthMs   int    `json:"item_length_ms"`
		ItemProgressMs int    `json:"item_progress_ms"`
	}
	var sorties struct {
		Outputs []struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			Selected bool   `json:"selected"`
			Volume   int    `json:"volume"`
		} `json:"outputs"`
	}
	if err := o.lire(ctx, "api/player", nil, &lecteur); err != nil {
		return Attributs{}, err
	}
	horodatage := float64(time.Now().UnixMilli()) / 1000
	if err := o.lire(ctx, "api/outputs", nil, &sorties); err != nil {
		return Attributs{}, err
	}
	a := Attributs{
		ID:         idSession,
		Serveur:    o.portier.String(),
		Etat:       lecteur.State,
		DureeMs:    lecteur.ItemLengthMs,
		PositionMs: lecteur.ItemProgressMs,
		Horodatage: horodatage,
		Appareils:  []Appareil{},
	}
	for _, s := range sorties.Outputs {
		if s.Selected {
			a.Appareils = append(a.Appareils, Appareil{ID: s.ID, Nom: s.Name, Volume: s.Volume})
		}
	}
	if lecteur.ItemID == 0 {
		return a, nil
	}
	var file struct {
		Items []struct {
			ID         int    `json:"id"`
			Title      string `json:"title"`
			Artist     string `json:"artist"`
			Album      string `json:"album"`
			LengthMs   *int   `json:"length_ms"`
			ArtworkURL string `json:"artwork_url"` // relative à OwnTone (« ./artwork/item/<morceau>?v=… ») ou absolue
		} `json:"items"`
	}
	// Seulement la piste en cours : la file entière peut compter des milliers de morceaux.
	if err := o.lire(ctx, "api/queue", url.Values{"id": {strconv.Itoa(lecteur.ItemID)}}, &file); err != nil {
		return Attributs{}, err
	}
	for _, e := range file.Items {
		if e.ID != lecteur.ItemID {
			continue
		}
		a.PisteID, a.Titre, a.Artiste, a.Album = e.ID, e.Title, e.Artist, e.Album
		if e.LengthMs != nil {
			a.DureeMs = *e.LengthMs
		}
		if e.ArtworkURL != "" {
			if p, err := url.Parse(e.ArtworkURL); err == nil {
				a.Pochette = o.portier.JoinPath("/").ResolveReference(p).String()
			}
		}
	}
	return a, nil
}

// Ecouter suit la websocket d'OwnTone et appelle signaler à chaque événement, et à chaque reconnexion (l'état a pu
// changer pendant la coupure). Ne rend la main qu'à la fin du contexte.
func (o *OwnTone) Ecouter(ctx context.Context, signaler func(), journal *slog.Logger) {
	attente := time.Second
	for ctx.Err() == nil {
		debut := time.Now()
		err := o.ecouterUneFois(ctx, signaler, journal)
		if ctx.Err() != nil {
			return
		}
		if time.Since(debut) > time.Minute {
			attente = time.Second
		}
		journal.Warn("websocket d'OwnTone coupée", "erreur", err, "nouvel essai dans", attente)
		select {
		case <-ctx.Done():
			return
		case <-time.After(attente):
		}
		attente = min(attente*2, 30*time.Second)
	}
}

func (o *OwnTone) ecouterUneFois(ctx context.Context, signaler func(), journal *slog.Logger) error {
	connexion, cancel := context.WithTimeout(ctx, 10*time.Second)
	c, _, err := websocket.Dial(connexion, o.ws, &websocket.DialOptions{Subprotocols: []string{"notify"}})
	cancel()
	if err != nil {
		return err
	}
	defer c.CloseNow()
	abonnement := map[string][]string{"notify": {"player", "outputs", "volume", "queue"}}
	if err := wsjson.Write(ctx, c, abonnement); err != nil {
		return err
	}
	journal.Info("websocket d'OwnTone ouverte")
	signaler()

	// Un ping toutes les 30 s : une connexion morte en silence est fermée, puis rouverte par Ecouter.
	veille, arreter := context.WithCancel(ctx)
	defer arreter()
	go func() {
		minuterie := time.NewTicker(30 * time.Second)
		defer minuterie.Stop()
		for {
			select {
			case <-veille.Done():
				return
			case <-minuterie.C:
				p, fin := context.WithTimeout(veille, 10*time.Second)
				err := c.Ping(p)
				fin()
				if err != nil && veille.Err() == nil {
					c.CloseNow()
					return
				}
			}
		}
	}()

	for {
		if _, _, err := c.Read(ctx); err != nil {
			return err
		}
		signaler()
	}
}
