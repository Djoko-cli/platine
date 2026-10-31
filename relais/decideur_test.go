package main

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 31, 20, 0, 0, 0, time.UTC)

func etat(e string, piste, positionMs int, a time.Time, volumes ...int) Attributs {
	at := Attributs{ID: idSession, Etat: e, PisteID: piste, Titre: "Morceau", PositionMs: positionMs,
		Horodatage: float64(a.UnixMilli()) / 1000, Appareils: []Appareil{}}
	for i, v := range volumes {
		at.Appareils = append(at.Appareils, Appareil{ID: string(rune('1' + i)), Nom: "Pièce", Volume: v})
	}
	return at
}

func evenement(p *Push) string {
	if p == nil {
		return "rien"
	}
	return p.Evenement
}

func attendre(t *testing.T, quoi string, p *Push, voulu string) {
	t.Helper()
	if got := evenement(p); got != voulu {
		t.Fatalf("%s : %s, attendu %s", quoi, got, voulu)
	}
}

func TestDemarrageSeulementALaLecture(t *testing.T) {
	d := NouveauDecideur(false)
	attendre(t, "pause sans carte", d.Observer(etat("pause", 1, 0, t0), t0), "rien")
	attendre(t, "arrêt sans carte", d.Observer(etat("stop", 0, 0, t0), t0), "rien")
	attendre(t, "lecture", d.Observer(etat("play", 1, 0, t0), t0), Demarrer)
	attendre(t, "même état", d.Observer(etat("play", 1, 0, t0), t0), "rien")
}

func TestAvancementSansPushMaisSautOui(t *testing.T) {
	d := NouveauDecideur(false)
	d.Observer(etat("play", 1, 10_000, t0), t0)
	plus := t0.Add(20 * time.Second)
	attendre(t, "avancement normal", d.Observer(etat("play", 1, 30_400, plus), plus), "rien")
	attendre(t, "saut en avant", d.Observer(etat("play", 1, 90_000, plus), plus), MettreAJour)
	attendre(t, "saut en arrière", d.Observer(etat("play", 1, 5_000, plus), plus), MettreAJour)
	// En pause, la position ne bouge pas, quelle que soit l'heure.
	d.Observer(etat("pause", 1, 5_000, plus), plus)
	tard := plus.Add(time.Minute)
	attendre(t, "pause qui dure", d.Observer(etat("pause", 1, 5_000, tard), tard), "rien")
}

func TestChangementsQuiDonnentUneMiseAJour(t *testing.T) {
	d := NouveauDecideur(false)
	d.Observer(etat("play", 1, 0, t0, 40), t0)
	attendre(t, "volume", d.Observer(etat("play", 1, 0, t0, 55), t0), MettreAJour)
	attendre(t, "sortie ajoutée", d.Observer(etat("play", 1, 0, t0, 55, 30), t0), MettreAJour)
	attendre(t, "piste", d.Observer(etat("play", 2, 0, t0, 55, 30), t0), MettreAJour)
	attendre(t, "pause", d.Observer(etat("pause", 2, 0, t0, 55, 30), t0), MettreAJour)
	radio := etat("pause", 2, 0, t0, 55, 30)
	radio.Titre = "Autre titre"
	attendre(t, "titre d'un flux", d.Observer(radio, t0), MettreAJour)
}

func TestFinApresArretEtPause(t *testing.T) {
	d := NouveauDecideur(false)
	d.Observer(etat("play", 1, 0, t0), t0)
	d.Observer(etat("stop", 0, 0, t0), t0)
	attendre(t, "1 min après l'arrêt", d.Echeance(t0.Add(time.Minute)), "rien")
	// Un nouvel arrêt relu ne repousse pas la fin.
	d.Observer(etat("stop", 0, 0, t0.Add(time.Minute)), t0.Add(time.Minute))
	attendre(t, "2 min après l'arrêt", d.Echeance(t0.Add(finApresArret)), Terminer)
	d.SessionPerdue() // le relais confirme l'envoi
	attendre(t, "après la fin", d.Echeance(t0.Add(time.Hour)), "rien")
	attendre(t, "lecture après la fin", d.Observer(etat("play", 1, 0, t0), t0), Demarrer)

	d.Observer(etat("pause", 1, 0, t0), t0)
	attendre(t, "29 min de pause", d.Echeance(t0.Add(29*time.Minute)), "rien")
	attendre(t, "30 min de pause", d.Echeance(t0.Add(finApresPause)), Terminer)
}

func TestLaLectureAnnuleLaFin(t *testing.T) {
	d := NouveauDecideur(false)
	d.Observer(etat("play", 1, 0, t0), t0)
	d.Observer(etat("pause", 1, 0, t0), t0)
	reprise := t0.Add(10 * time.Minute)
	d.Observer(etat("play", 1, 0, reprise), reprise)
	attendre(t, "après la reprise", d.Echeance(t0.Add(time.Hour)), "rien")
	// Une nouvelle pause relance les 30 minutes.
	pause := t0.Add(2 * time.Hour)
	d.Observer(etat("pause", 1, 0, pause), pause)
	attendre(t, "nouvelle pause", d.Echeance(pause.Add(29*time.Minute)), "rien")
	attendre(t, "nouvelle pause finie", d.Echeance(pause.Add(30*time.Minute)), Terminer)
}

func TestFinRetentee(t *testing.T) {
	d := NouveauDecideur(false)
	d.Observer(etat("play", 1, 0, t0), t0)
	d.Observer(etat("stop", 0, 0, t0), t0)
	fin := t0.Add(finApresArret)
	attendre(t, "fin", d.Echeance(fin), Terminer)
	// Pas de confirmation du relais (APNs en panne) : end revient 30 s plus tard, pas avant.
	attendre(t, "10 s après l'échec", d.Echeance(fin.Add(10*time.Second)), "rien")
	attendre(t, "30 s après l'échec", d.Echeance(fin.Add(reessaiFin)), Terminer)
	// Une lecture entre-temps garde la carte.
	d.Observer(etat("play", 1, 0, fin), fin)
	attendre(t, "lecture reprise", d.Echeance(fin.Add(time.Hour)), "rien")
}

func TestInjoignable(t *testing.T) {
	d := NouveauDecideur(false)
	attendre(t, "sans session", d.Injoignable(t0), "rien")
	d.Observer(etat("play", 1, 0, t0, 40), t0)
	p := d.Injoignable(t0)
	attendre(t, "OwnTone muet en lecture", p, MettreAJour)
	if p.Attributs.Etat != "stop" || p.Attributs.PisteID != 1 {
		t.Errorf("la carte passe à l'arrêt sur la même piste : %+v", p.Attributs)
	}
	attendre(t, "encore muet", d.Injoignable(t0), "rien")
	attendre(t, "fin comme après un arrêt", d.Echeance(t0.Add(finApresArret)), Terminer)
	d.SessionPerdue()
	attendre(t, "retour d'OwnTone", d.Observer(etat("play", 1, 0, t0), t0), Demarrer)
}

func TestJetonDeSession(t *testing.T) {
	// Session démarrée par l'app : le relais l'apprend par le jeton et transmet l'état.
	d := NouveauDecideur(false)
	d.JetonSession()
	attendre(t, "après le jeton", d.Observer(etat("play", 1, 0, t0), t0), MettreAJour)
	// Un jeton reçu pour une session ouverte, nouveau ou non, ne relance pas de push : l'extension le redonne à chaque
	// réveil, et chaque update la réveille (sinon : une boucle).
	d.JetonSession()
	attendre(t, "jeton redonné", d.Observer(etat("play", 1, 0, t0), t0), "rien")
	// Après un start, le jeton de session arrive : la carte a déjà l'état du start.
	d2 := NouveauDecideur(false)
	attendre(t, "start", d2.Observer(etat("play", 1, 0, t0), t0), Demarrer)
	d2.JetonSession()
	attendre(t, "jeton après le start", d2.Observer(etat("play", 1, 0, t0), t0), "rien")
	// Une session ouverte à l'arrêt se termine comme les autres.
	d.Observer(etat("stop", 0, 0, t0), t0)
	attendre(t, "fin", d.Echeance(t0.Add(finApresArret)), Terminer)
}

func TestRedemarrageDuRelais(t *testing.T) {
	d := NouveauDecideur(true)
	attendre(t, "premier état", d.Observer(etat("pause", 1, 0, t0), t0), MettreAJour)
}

func TestARenvoyer(t *testing.T) {
	d := NouveauDecideur(false)
	d.Observer(etat("play", 1, 0, t0), t0)
	d.ARenvoyer()
	attendre(t, "même état après un échec", d.Observer(etat("play", 1, 0, t0), t0), MettreAJour)
}

func TestDelaiRegroupement(t *testing.T) {
	for _, c := range []struct {
		depuis time.Duration // depuis le premier événement pas encore traité
		voulu  time.Duration
	}{
		{0, regroupement},
		{3 * time.Second, regroupement},
		{plafondRegroupement - 300*time.Millisecond, 300 * time.Millisecond},
		{plafondRegroupement + time.Second, 0},
	} {
		if got := delaiRegroupement(t0, t0.Add(c.depuis)); got != c.voulu {
			t.Errorf("%v après le premier événement : %v, attendu %v", c.depuis, got, c.voulu)
		}
	}
}
