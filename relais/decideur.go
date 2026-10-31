// Le décideur : à partir des états successifs d'OwnTone, quelle push envoyer (start, update, end), et quand.
// Sans réseau ni horloge à lui : le relais lui passe l'heure, les tests aussi. Un seul fil d'exécution s'en sert.
package main

import (
	"reflect"
	"time"
)

const (
	Demarrer    = "start"
	MettreAJour = "update"
	Terminer    = "end"

	finApresArret = 2 * time.Minute
	finApresPause = 30 * time.Minute
	// Un end qui n'a pas pu partir (APNs ou réseau en panne) est retenté après ce délai.
	reessaiFin = 30 * time.Second
	// Un écart plus grand entre la position relevée et celle que le système extrapole : un saut dans le morceau.
	seuilSaut = 3000 // ms
)

type Push struct {
	Evenement string
	Attributs Attributs // ignoré pour end
}

type Decideur struct {
	ouverte bool       // une session existe sur l'iPhone : démarrée par push, ou jeton de session reçu
	envoye  *Attributs // le dernier état transmis ; nil : la prochaine observation le transmet
	finA    time.Time  // quand envoyer end ; zéro : pas de fin prévue
	etatFin string     // l'état qui a fixé finA
}

// NouveauDecideur : sessionOuverte quand le relais redémarre avec un jeton de session gardé.
func NouveauDecideur(sessionOuverte bool) *Decideur {
	return &Decideur{ouverte: sessionOuverte}
}

// Observer reçoit un état relu d'OwnTone et renvoie la push à envoyer, ou nil.
func (d *Decideur) Observer(a Attributs, maintenant time.Time) *Push {
	if !d.ouverte {
		// Une pause ou un arrêt sans carte ne mérite pas d'en faire apparaître une.
		if a.Etat != "play" {
			return nil
		}
		d.ouverte = true
		d.prevoirFin(a.Etat, maintenant)
		d.envoye = &a
		return &Push{Evenement: Demarrer, Attributs: a}
	}
	d.prevoirFin(a.Etat, maintenant)
	if d.envoye != nil && !change(*d.envoye, a) {
		return nil
	}
	d.envoye = &a
	return &Push{Evenement: MettreAJour, Attributs: a}
}

// Echeance renvoie la push end quand la fin prévue est passée. La session reste ouverte jusqu'à ce que le relais
// confirme l'envoi (SessionPerdue) ; sans confirmation, end revient après reessaiFin.
func (d *Decideur) Echeance(maintenant time.Time) *Push {
	if !d.ouverte || d.finA.IsZero() || maintenant.Before(d.finA) {
		return nil
	}
	d.finA = maintenant.Add(reessaiFin)
	return &Push{Evenement: Terminer}
}

// Injoignable : OwnTone ne répond plus depuis un moment. Rien ne joue, à notre connaissance : la carte passe à
// l'arrêt (si elle montrait autre chose) et se terminera comme après un arrêt.
func (d *Decideur) Injoignable(maintenant time.Time) *Push {
	if !d.ouverte {
		return nil
	}
	d.prevoirFin("stop", maintenant)
	if d.envoye == nil || d.envoye.Etat == "stop" {
		return nil
	}
	a := *d.envoye
	a.Etat = "stop"
	a.Horodatage = float64(maintenant.UnixMilli()) / 1000
	d.envoye = &a
	return &Push{Evenement: MettreAJour, Attributs: a}
}

// JetonSession : l'extension a donné le jeton d'une session, démarrée par une push ou par l'app. Une session que le
// relais ne connaissait pas reçoit l'état à la prochaine observation. Une session déjà ouverte ne change pas : sa carte
// montre déjà ce qui a été envoyé, et une push à chaque nouveau jeton réveillerait l'extension, qui en redonnerait un.
func (d *Decideur) JetonSession() {
	if d.ouverte {
		return
	}
	d.ouverte = true
	d.envoye = nil
}

// ARenvoyer : la dernière push n'est pas arrivée, la prochaine observation transmet l'état quoi qu'il en soit.
func (d *Decideur) ARenvoyer() {
	d.envoye = nil
}

// SessionPerdue : plus de session sur l'iPhone (end envoyé, jeton refusé, démarrage impossible, rien à terminer). La
// prochaine lecture repart par start.
func (d *Decideur) SessionPerdue() {
	*d = Decideur{}
}

// Ouverte : pour le journal.
func (d *Decideur) Ouverte() bool { return d.ouverte }

func (d *Decideur) prevoirFin(etat string, maintenant time.Time) {
	switch etat {
	case "play":
		d.finA = time.Time{}
	case "pause":
		if d.etatFin != "pause" {
			d.finA = maintenant.Add(finApresPause)
		}
	default:
		etat = "stop"
		if d.etatFin != "stop" {
			d.finA = maintenant.Add(finApresArret)
		}
	}
	d.etatFin = etat
}

// change : ce qui mérite une push. Tout sauf l'avancement, que le système extrapole ; un saut dans le morceau, oui.
func change(avant, apres Attributs) bool {
	if avant.Etat == apres.Etat && avant.PisteID == apres.PisteID {
		attendu := avant.PositionMs
		if avant.Etat == "play" {
			attendu += int((apres.Horodatage - avant.Horodatage) * 1000)
		}
		if ecart := apres.PositionMs - attendu; ecart > seuilSaut || ecart < -seuilSaut {
			return true
		}
	}
	avant.PositionMs, avant.Horodatage = 0, 0
	apres.PositionMs, apres.Horodatage = 0, 0
	return !reflect.DeepEqual(avant, apres)
}
