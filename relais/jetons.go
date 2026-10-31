// Les jetons push donnés par l'iPhone (par le portier) : le jeton de démarrage, donné par l'app, et le jeton de mise à
// jour de chaque session, donné par l'extension. Gardés dans un fichier (droits 600) pour survivre à un redémarrage.
package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sync"
)

const (
	JetonDemarrage = "demarrage"
	JetonSession   = "session"
)

var formatJeton = regexp.MustCompile(`^[0-9a-f]{16,200}$`)

// ErrJetonTermine : le jeton d'une session finie pour le relais (end envoyé, ou jeton refusé par APNs). L'extension
// peut le redonner encore ; le reprendre rouvrirait une session finie (update, puis end deux minutes plus tard, et
// ainsi de suite).
var ErrJetonTermine = errors.New("jeton d'une session terminée")

// Les jetons de sessions finies gardés dans le fichier, pour survivre à un redémarrage : les plus récents suffisent.
const maxTermines = 20

type Jetons struct {
	mu      sync.Mutex
	fichier string
	contenu contenuJetons
}

type contenuJetons struct {
	Demarrage string            `json:"demarrage,omitempty"`
	Sessions  map[string]string `json:"sessions"`
	Termines  []string          `json:"termines,omitempty"` // voir ErrJetonTermine
}

func OuvrirJetons(fichier string) (*Jetons, error) {
	j := &Jetons{fichier: fichier, contenu: contenuJetons{Sessions: map[string]string{}}}
	data, err := os.ReadFile(fichier)
	if errors.Is(err, os.ErrNotExist) {
		return j, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &j.contenu); err != nil {
		return nil, err
	}
	if j.contenu.Sessions == nil {
		j.contenu.Sessions = map[string]string{}
	}
	return j, nil
}

func (j *Jetons) Demarrage() string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.contenu.Demarrage
}

func (j *Jetons) Session(id string) string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.contenu.Sessions[id]
}

// Enregistrer garde un jeton et dit s'il est nouveau. Un jeton déjà connu n'écrit rien.
func (j *Jetons) Enregistrer(genre, session, jeton string) (nouveau bool, err error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	switch genre {
	case JetonDemarrage:
		if j.contenu.Demarrage == jeton {
			return false, nil
		}
		j.contenu.Demarrage = jeton
	case JetonSession:
		if slices.Contains(j.contenu.Termines, jeton) {
			return false, ErrJetonTermine
		}
		if j.contenu.Sessions[session] == jeton {
			return false, nil
		}
		j.contenu.Sessions[session] = jeton
	default:
		return false, errors.New("genre de jeton inconnu")
	}
	return true, j.sauver()
}

// OublierDemarrage : ce jeton de démarrage a été refusé par APNs. Un jeton plus récent, arrivé pendant l'envoi, reste.
func (j *Jetons) OublierDemarrage(jeton string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.contenu.Demarrage != jeton {
		return nil
	}
	j.contenu.Demarrage = ""
	return j.sauver()
}

// OublierSession : la session de ce jeton est finie pour le relais (end envoyé, ou jeton refusé) ; le jeton ne sera
// plus repris (voir ErrJetonTermine). Un jeton plus récent, arrivé pendant l'envoi pour la même session, reste.
func (j *Jetons) OublierSession(id, jeton string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !slices.Contains(j.contenu.Termines, jeton) {
		j.contenu.Termines = append(j.contenu.Termines, jeton)
		if n := len(j.contenu.Termines); n > maxTermines {
			j.contenu.Termines = slices.Clone(j.contenu.Termines[n-maxTermines:])
		}
	}
	if j.contenu.Sessions[id] == jeton {
		delete(j.contenu.Sessions, id)
	}
	return j.sauver()
}

// sauver écrit à côté puis renomme : un arrêt en pleine écriture ne laisse pas un fichier tronqué.
func (j *Jetons) sauver() error {
	data, err := json.Marshal(j.contenu)
	if err != nil {
		return err
	}
	provisoire, err := os.CreateTemp(filepath.Dir(j.fichier), ".jetons-*")
	if err != nil {
		return err
	}
	defer os.Remove(provisoire.Name())
	if _, err := provisoire.Write(data); err != nil {
		provisoire.Close()
		return err
	}
	if err := provisoire.Close(); err != nil {
		return err
	}
	return os.Rename(provisoire.Name(), j.fichier)
}

// fin : les 4 derniers caractères, seuls à paraître dans le journal.
func fin(jeton string) string {
	if len(jeton) < 4 {
		return "…"
	}
	return "…" + jeton[len(jeton)-4:]
}
