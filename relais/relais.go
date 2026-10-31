// La boucle du relais : regroupe les événements d'OwnTone, relit l'état, demande au décideur quelle push envoyer et
// l'envoie. Un seul fil d'exécution touche au décideur ; les jetons reçus lui arrivent par un canal.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"
)

const (
	// Une seconde de calme avant de relire OwnTone : un curseur de volume qui glisse, ou une rafale d'événements, ne
	// donne qu'une push, avec le dernier état. Au plus 5 s d'attente si les événements ne cessent pas.
	regroupement        = time.Second
	plafondRegroupement = 5 * time.Second
	// Une relecture de secours : un événement perdu (websocket coupée sans bruit) ne laisse pas la carte en retard.
	releveDeSecours = time.Minute
	// OwnTone muet depuis ce délai : la carte passe à l'arrêt.
	delaiInjoignable = 2 * time.Minute
	// Après un start, le jeton de session de l'extension devrait arriver dans ce délai ; sinon, le journal le dit.
	attenteJetonSession = 30 * time.Second
)

type jetonRecu struct {
	genre   string
	nouveau bool
}

type Relais struct {
	owntone  *OwnTone
	apns     *APNs
	jetons   *Jetons
	decideur *Decideur
	journal  *slog.Logger

	changements chan struct{}
	jetonsRecus chan jetonRecu

	// Touchés par la boucle seulement.
	injoignableDepuis time.Time
	injoignableTraite bool
	attenteJeton      <-chan time.Time
	sansJetonSignale  bool // l'absence de jeton de démarrage n'est dite qu'une fois
}

func NouveauRelais(o *OwnTone, a *APNs, j *Jetons, journal *slog.Logger) *Relais {
	return &Relais{
		owntone:     o,
		apns:        a,
		jetons:      j,
		decideur:    NouveauDecideur(j.Session(idSession) != ""),
		journal:     journal,
		changements: make(chan struct{}, 1),
		jetonsRecus: make(chan jetonRecu, 8),
	}
}

// Signaler : OwnTone a changé. Ne bloque jamais ; plusieurs signaux rapprochés n'en font qu'un.
func (r *Relais) Signaler() {
	select {
	case r.changements <- struct{}{}:
	default:
	}
}

// delaiRegroupement : combien attendre encore avant de relire OwnTone, quand un événement arrive à maintenant et que
// le premier événement pas encore traité est arrivé à premier.
func delaiRegroupement(premier, maintenant time.Time) time.Duration {
	return max(min(regroupement, premier.Add(plafondRegroupement).Sub(maintenant)), 0)
}

func (r *Relais) Tourner(ctx context.Context) {
	regroupe := time.NewTimer(regroupement)
	regroupe.Stop()
	var premier time.Time // le premier événement pas encore traité ; zéro : aucun
	attendre := func() {
		maintenant := time.Now()
		if premier.IsZero() {
			premier = maintenant
		}
		regroupe.Reset(delaiRegroupement(premier, maintenant))
	}
	releve := time.NewTicker(releveDeSecours)
	defer releve.Stop()
	echeances := time.NewTicker(5 * time.Second)
	defer echeances.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.changements:
			attendre()
		case j := <-r.jetonsRecus:
			switch j.genre {
			case JetonSession:
				r.decideur.JetonSession()
			case JetonDemarrage:
				r.sansJetonSignale = false
			}
			// Un jeton nouveau peut débloquer une push (démarrage sans jeton jusqu'ici, update en attente du jeton de
			// session, session démarrée par l'app).
			if j.nouveau {
				attendre()
			}
		case <-regroupe.C:
			premier = time.Time{}
			r.observer(ctx)
		case <-releve.C:
			r.observer(ctx)
		case maintenant := <-echeances.C:
			if p := r.decideur.Echeance(maintenant); p != nil {
				r.envoyer(ctx, *p)
			}
		case <-r.attenteJeton:
			r.attenteJeton = nil
			if r.decideur.Ouverte() && r.jetons.Session(idSession) == "" {
				r.journal.Warn("pas de jeton de session 30 s après le start : ni update ni end possibles pour cette " +
					"carte (journal de l'extension : scripts/essai-push.py journal)")
			}
		}
	}
}

func (r *Relais) observer(ctx context.Context) {
	lecture, fin := context.WithTimeout(ctx, 10*time.Second)
	a, err := r.owntone.Etat(lecture)
	fin()
	maintenant := time.Now()
	if err != nil {
		if r.injoignableDepuis.IsZero() {
			r.injoignableDepuis = maintenant
			r.journal.Warn("OwnTone illisible", "erreur", err)
		}
		if !r.injoignableTraite && maintenant.Sub(r.injoignableDepuis) >= delaiInjoignable {
			r.injoignableTraite = true
			r.journal.Warn("OwnTone muet depuis 2 min : carte à l'arrêt")
			if p := r.decideur.Injoignable(maintenant); p != nil {
				r.envoyer(ctx, *p)
			}
		}
		return
	}
	if !r.injoignableDepuis.IsZero() {
		r.journal.Info("OwnTone de nouveau lisible", "apres", maintenant.Sub(r.injoignableDepuis).Round(time.Second))
		r.injoignableDepuis, r.injoignableTraite = time.Time{}, false
	}
	if p := r.decideur.Observer(a, maintenant); p != nil {
		r.envoyer(ctx, *p)
	}
}

func (r *Relais) envoyer(ctx context.Context, p Push) {
	jeton := r.jetons.Session(idSession)
	if p.Evenement == Demarrer {
		jeton = r.jetons.Demarrage()
	}
	if jeton == "" {
		switch p.Evenement {
		case Demarrer:
			if !r.sansJetonSignale {
				r.journal.Warn("push start impossible : pas de jeton de démarrage (ouvrir Platine sur l'iPhone)")
				r.sansJetonSignale = true
			}
			r.decideur.SessionPerdue()
		case MettreAJour:
			// Session démarrée par push, jeton de l'extension pas encore reçu : son arrivée relancera la mise à jour.
			r.journal.Info("push update en attente du jeton de session")
			r.decideur.ARenvoyer()
		case Terminer:
			r.decideur.SessionPerdue() // sans jeton, rien à terminer
		}
		return
	}

	err := r.apns.Envoyer(ctx, jeton, p)
	var refus *RefusAPNs
	invalide := errors.As(err, &refus) && refus.JetonInvalide()
	// Passager : réseau, Apple surchargé, jeton d'authentification à refaire. Le reste ne passera pas mieux tel quel.
	passager := err != nil && !invalide && (refus == nil || refus.Passager())
	switch {
	case err == nil:
		attributs := []any{"evenement", p.Evenement, "jeton", fin(jeton)}
		if p.Evenement != Terminer {
			attributs = append(attributs, "etat", p.Attributs.Etat, "piste", p.Attributs.PisteID,
				"appareils", len(p.Attributs.Appareils))
		}
		r.journal.Info("push envoyée", attributs...)
	case invalide:
		r.journal.Warn("jeton refusé par APNs, oublié", "evenement", p.Evenement, "jeton", fin(jeton), "erreur", err)
	default:
		r.journal.Warn("push en échec", "evenement", p.Evenement, "jeton", fin(jeton), "erreur", err,
			"nouvel essai", passager)
	}

	switch p.Evenement {
	case Demarrer:
		if err == nil {
			r.attenteJeton = time.After(attenteJetonSession)
			return
		}
		if invalide {
			r.oublier(r.jetons.OublierDemarrage())
		}
		r.decideur.SessionPerdue()
	case MettreAJour:
		if invalide {
			r.oublier(r.jetons.OublierSession(idSession))
			r.decideur.SessionPerdue()
		} else if passager {
			r.decideur.ARenvoyer()
		}
	case Terminer:
		// Envoyé, ou refusé pour de bon : la session est finie pour le relais. Sinon, le décideur réessaie dans 30 s.
		if !passager {
			r.oublier(r.jetons.OublierSession(idSession))
			r.decideur.SessionPerdue()
		}
	}
}

func (r *Relais) oublier(err error) {
	if err != nil {
		r.journal.Error("fichier des jetons impossible à écrire", "erreur", err)
	}
}

// RecevoirJeton : POST /platine/jetons, par le portier (qui a vérifié son jeton et plafonné la taille).
// Corps : {"type": "demarrage" | "session", "session": "owntone", "jeton": "<hexadécimal>"}.
func (r *Relais) RecevoirJeton(w http.ResponseWriter, demande *http.Request) {
	if demande.Method != http.MethodPost {
		http.Error(w, "", http.StatusMethodNotAllowed)
		return
	}
	var corps struct {
		Type    string `json:"type"`
		Session string `json:"session"`
		Jeton   string `json:"jeton"`
	}
	lecteur := json.NewDecoder(http.MaxBytesReader(w, demande.Body, 1024))
	lecteur.DisallowUnknownFields()
	if err := lecteur.Decode(&corps); err != nil ||
		(corps.Type != JetonDemarrage && corps.Type != JetonSession) ||
		(corps.Type == JetonSession && corps.Session != idSession) ||
		!formatJeton.MatchString(corps.Jeton) {
		http.Error(w, "", http.StatusBadRequest)
		return
	}
	nouveau, err := r.jetons.Enregistrer(corps.Type, corps.Session, corps.Jeton)
	if errors.Is(err, ErrJetonTermine) {
		r.journal.Info("jeton d'une session terminée, ignoré", "jeton", fin(corps.Jeton))
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// Un fichier impossible à écrire n'empêche pas de se servir du jeton : seul un redémarrage le perdrait.
	r.oublier(err)
	r.journal.Info("jeton reçu", "type", corps.Type, "jeton", fin(corps.Jeton), "nouveau", nouveau)
	r.jetonsRecus <- jetonRecu{genre: corps.Type, nouveau: nouveau}
	w.WriteHeader(http.StatusNoContent)
}
