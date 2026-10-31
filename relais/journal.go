// Le fichier du journal : sur le NAS, docker logs exige sudo ; ce fichier se lit par ssh. Au-delà de 1 Mo, il passe
// en .1 (un seul ancien gardé).
package main

import (
	"fmt"
	"io"
	"os"
	"sync"
)

const tailleJournal = 1 << 20

type journalTournant struct {
	mu     sync.Mutex
	nom    string
	f      *os.File
	taille int64
}

// ouvrirJournal : la sortie standard, et aussi le fichier JOURNAL quand il est réglé.
func ouvrirJournal() io.Writer {
	nom := os.Getenv("JOURNAL")
	if nom == "" {
		return os.Stdout
	}
	j := &journalTournant{nom: nom}
	if err := j.ouvrir(); err != nil {
		fmt.Fprintln(os.Stderr, "journal impossible à ouvrir :", err)
		return os.Stdout
	}
	return io.MultiWriter(os.Stdout, j)
}

func (j *journalTournant) ouvrir() error {
	f, err := os.OpenFile(j.nom, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	j.f, j.taille = f, info.Size()
	return nil
}

func (j *journalTournant) Write(p []byte) (int, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.taille+int64(len(p)) > tailleJournal {
		j.f.Close()
		os.Rename(j.nom, j.nom+".1")
		if err := j.ouvrir(); err != nil {
			return 0, err
		}
	}
	n, err := j.f.Write(p)
	j.taille += int64(n)
	return n, err
}
