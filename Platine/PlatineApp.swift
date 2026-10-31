// Platine, essai témoin des sessions distantes d'iOS 27 : l'app lit ce que joue OwnTone, démarre une session distante
// avec cet état et la tient à jour tant qu'elle est ouverte (pas encore de push). Le journal à l'écran sert au banc.
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

    var adresse: String {
        didSet { UserDefaults.standard.set(adresse, forKey: "adresse") }
    }
    private(set) var journal: [String] = []
    private(set) var session: RemoteMediaSession<PlatineAttributs>?
    private(set) var dernier: PlatineAttributs?
    private var suivi: Task<Void, Never>?

    init() {
        let parDefaut = Bundle.main.object(forInfoDictionaryKey: "OwnToneURL") as? String ?? ""
        adresse = UserDefaults.standard.string(forKey: "adresse") ?? parDefaut
    }

    func noter(_ texte: String) {
        journal.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(texte)", at: 0)
    }

    /// Au lancement : reprend une session restée ouverte, et dit si le jeton de démarrage par push existe.
    func reprendre() async {
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
        noter("jeton de démarrage par push : \(RemoteMediaSession<PlatineAttributs>.pushToStartToken == nil ? "absent" : "présent")")
    }

    func demarrer() async {
        guard let client = ClientOwnTone(adresse: adresse) else { return noter("adresse d'OwnTone invalide") }
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
                guard let self, let session = self.session, let client = ClientOwnTone(adresse: self.adresse) else { continue }
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
                    TextField("http://adresse-du-nas:3689", text: $relais.adresse)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Session distante") {
                    Button("Démarrer ou mettre à jour") { Task { await relais.demarrer() } }
                    Button("Mettre en avant") { Task { await relais.mettreEnAvant() } }
                        .disabled(relais.session == nil)
                    Button("Arrêter", role: .destructive) { Task { await relais.arreter() } }
                        .disabled(relais.session == nil)
                }
                Section("Journal") {
                    ForEach(Array(relais.journal.enumerated()), id: \.offset) { _, ligne in
                        Text(ligne).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Platine")
        }
        .task { await relais.reprendre() }
    }
}
