package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// fauxOwnTone : un OwnTone qui joue la piste 7 sur une sortie choisie parmi deux.
func fauxOwnTone(t *testing.T) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/player":
			fmt.Fprint(w, `{"state":"play","item_id":7,"item_length_ms":1,"item_progress_ms":1000}`)
		case "/api/outputs":
			fmt.Fprint(w, `{"outputs":[{"id":"1","name":"Pièce 1","selected":true,"volume":40},`+
				`{"id":"2","name":"Pièce 2","selected":false,"volume":10}]}`)
		case "/api/queue":
			if r.URL.Query().Get("id") != "7" {
				t.Errorf("file lue sans le filtre de la piste en cours : %s", r.URL.RawQuery)
			}
			fmt.Fprint(w, `{"items":[{"id":7,"title":"Morceau","artist":"Artiste","album":"Album",`+
				`"length_ms":200000,"artwork_url":"./artwork/item/7?v=1"}]}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func TestEtatDOwnTone(t *testing.T) {
	s := fauxOwnTone(t)
	o, err := NouvelOwnTone(s.URL, "ws://inutilise", "https://portier.example")
	if err != nil {
		t.Fatal(err)
	}
	a, err := o.Etat(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	voulu := Attributs{ID: idSession, Serveur: "https://portier.example", Etat: "play", PisteID: 7, Titre: "Morceau",
		Artiste: "Artiste", Album: "Album", Pochette: "https://portier.example/artwork/item/7?v=1", DureeMs: 200000,
		PositionMs: 1000, Horodatage: a.Horodatage, Appareils: []Appareil{{ID: "1", Nom: "Pièce 1", Volume: 40}}}
	if !reflect.DeepEqual(a, voulu) {
		t.Errorf("état lu :\n%+v\nattendu :\n%+v", a, voulu)
	}
	if a.Horodatage == 0 {
		t.Error("horodatage absent")
	}
}

// Le contrat avec l'app : les clés JSON de Attributs et Appareil sont exactement les propriétés de PlatineAttributs
// (Commun/OwnTone.swift). Un renommage d'un seul côté fait rejeter les push sans aucune erreur visible.
func TestContratAvecLApp(t *testing.T) {
	swift, err := os.ReadFile("../Commun/OwnTone.swift")
	if err != nil {
		t.Fatal(err)
	}
	texte := string(swift)
	debut := strings.Index(texte, "struct PlatineAttributs")
	if debut < 0 {
		t.Fatal("struct PlatineAttributs introuvable")
	}
	fin := strings.Index(texte[debut:], "\n}\n")
	if fin < 0 {
		t.Fatal("fin de struct PlatineAttributs introuvable")
	}
	var coteApp []string
	// Les propriétés stockées : « var nom: Type », sans accolade (une propriété calculée en a une).
	for _, m := range regexp.MustCompile(`(?m)^\s*var (\w+): [^{\n]*$`).FindAllStringSubmatch(texte[debut:debut+fin], -1) {
		coteApp = append(coteApp, m[1])
	}
	var coteRelais []string
	for _, typ := range []reflect.Type{reflect.TypeFor[Attributs](), reflect.TypeFor[Appareil]()} {
		for i := range typ.NumField() {
			coteRelais = append(coteRelais, strings.Split(typ.Field(i).Tag.Get("json"), ",")[0])
		}
	}
	slices.Sort(coteApp)
	slices.Sort(coteRelais)
	if !slices.Equal(slices.Compact(coteApp), slices.Compact(coteRelais)) {
		t.Errorf("contrat rompu :\napp    %v\nrelais %v", coteApp, coteRelais)
	}
}
