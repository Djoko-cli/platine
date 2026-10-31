// Platine, essai des sessions distantes d'iOS 27 : l'app lit ce que joue OwnTone par le portier, démarre une session
// distante avec cet état et la tient à jour tant qu'elle est ouverte (pas encore de push). Le journal sert au banc.
import NowPlaying
import SwiftUI

@main
struct PlatineApp: App {
    var body: some Scene {
        WindowGroup {
            Ecran()
        }
    }
}

@MainActor
@Observable
final class Relais {
    static let idSession = "owntone"

    private(set) var journal: [String] = []
    private(set) var journalExtension: [String] = []
    private(set) var session: RemoteMediaSession<PlatineAttributs>?
    private(set) var dernier: PlatineAttributs?
    private var suivi: Task<Void, Never>?
    private var lectureJournal: Task<Void, Never>?
    private var suiviJeton: Task<Void, Never>?

    func noter(_ texte: String) {
        journal.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(texte)", at: 0)
    }

    /// Au lancement : reprend une session restée ouverte, et dit si le jeton de démarrage par push existe.
    func reprendre() async {
        JournalPartage.reprendreAncien()
        lectureJournal?.cancel()
        lectureJournal = Task { [weak self] in
            while !Task.isCancelled {
                self?.journalExtension = JournalPartage.lire()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        noter(JournalPartage.fichier == nil ? "conteneur partagé introuvable" : "conteneur partagé disponible")
        do {
            let ouvertes = try await RemoteMediaSession<PlatineAttributs>.sessions()
            noter("sessions ouvertes : \(ouvertes.count)")
            if let ouverte = ouvertes.first(where: { $0.id == Self.idSession }) {
                session = ouverte
                suivre()
            }
        } catch {
            noter("lecture des sessions impossible : \(error)")
        }
        // Le flux des nouveaux jetons est pris avant le premier envoi : un jeton changé pendant cet envoi n'est pas perdu.
        let present = RemoteMediaSession<PlatineAttributs>.pushToStartToken
        let nouveaux = RemoteMediaSession<PlatineAttributs>.pushToStartTokenUpdates
        if present == nil {
            noter("jeton de démarrage par push : absent pour l'instant")
        }
        suiviJeton?.cancel()
        suiviJeton = Task { [weak self] in
            // Redonné au relais à chaque lancement : un envoi raté la fois d'avant se rattrape.
            if let jeton = present {
                let envoi = await JetonsPush.donnerDemarrage(jeton)
                self?.noter("jeton de démarrage par push : présent (…\(JetonsPush.hexadecimal(jeton).suffix(4))), \(envoi)")
            }
            for await jeton in nouveaux {
                let envoi = await JetonsPush.donnerDemarrage(jeton)
                self?.noter("nouveau jeton de démarrage par push (…\(JetonsPush.hexadecimal(jeton).suffix(4))), \(envoi)")
            }
        }
    }

    func demarrer() async {
        guard let client = ClientOwnTone.portier else { return noter("portier non réglé (Config/Local.xcconfig)") }
        do {
            let etat = try await client.lireEtat(id: Self.idSession)
            noter("OwnTone : \(etat.etat), \(etat.titre.isEmpty ? "aucune piste" : etat.titre), \(etat.appareils.count) sortie(s)")
            if let session {
                try await session.update(etat)
                noter("session existante mise à jour")
            } else {
                session = try await RemoteMediaSession.start(attributes: etat)
                noter("session démarrée")
            }
            dernier = etat
            await mettreEnAvant()
            suivre()
        } catch {
            noter("démarrage impossible : \(error)")
        }
    }

    func mettreEnAvant() async {
        guard let session else { return noter("aucune session") }
        do {
            try await session.requestToBecomeSystemPrimary()
            noter("demande de mise en avant envoyée (principale : \(session.isSystemPrimary ? "oui" : "non"))")
        } catch {
            noter("mise en avant refusée : \(error)")
        }
    }

    func arreter() async {
        suivi?.cancel()
        suivi = nil
        guard let session else { return noter("aucune session") }
        do {
            try await session.end()
            noter("session arrêtée")
        } catch {
            noter("arrêt impossible : \(error)")
        }
        self.session = nil
        dernier = nil
    }

    /// Relit OwnTone toutes les 2 s et met la session à jour quand la lecture, la piste ou un volume change.
    private func suivre() {
        suivi?.cancel()
        suivi = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let session = self.session, let client = ClientOwnTone.portier else { continue }
                guard let etat = try? await client.lireEtat(id: Self.idSession) else { continue }
                guard etat.signature != self.dernier?.signature else { continue }
                do {
                    try await session.update(etat)
                    self.dernier = etat
                    self.noter("mise à jour : \(etat.etat), \(etat.titre.isEmpty ? "aucune piste" : etat.titre), \(etat.appareils.count) sortie(s)")
                } catch {
                    self.noter("mise à jour refusée : \(error)")
                }
            }
        }
    }
}

struct Ecran: View {
    @State private var relais = Relais()

    var body: some View {
        NavigationStack {
            Form {
                Section("OwnTone") {
                    LabeledContent("Portier", value: ClientOwnTone.portier?.serveur.host() ?? "non réglé")
                }
                Section("Session distante") {
                    Button("Démarrer ou mettre à jour") { Task { await relais.demarrer() } }
                    Button("Mettre en avant") { Task { await relais.mettreEnAvant() } }
                        .disabled(relais.session == nil)
                    Button("Arrêter", role: .destructive) { Task { await relais.arreter() } }
                        .disabled(relais.session == nil)
                }
                Section("Journal de l'app") {
                    ForEach(Array(relais.journal.enumerated()), id: \.offset) { _, ligne in
                        Text(ligne).font(.caption.monospaced())
                    }
                }
                Section {
                    ForEach(Array(relais.journalExtension.enumerated()), id: \.offset) { _, ligne in
                        Text(ligne).font(.caption.monospaced())
                    }
                } header: {
                    HStack {
                        Text("Journal de l'extension")
                        Spacer()
                        Button("Vider") { JournalPartage.vider() }.font(.caption)
                    }
                }
            }
            .navigationTitle("Platine")
        }
        .task { await relais.reprendre() }
    }
}
