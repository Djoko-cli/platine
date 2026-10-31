// L'extension de session distante : le système la lance quand une session Platine démarre ou change, et lui demande
// la carte « en cours de lecture » (contenu, état, commandes, appareils avec leur volume). Les commandes touchées sur
// l'écran verrouillé ou dans le Centre de contrôle arrivent ici et partent vers l'API d'OwnTone.
import ExtensionFoundation
import Foundation
import NowPlaying

@main
struct ExtensionPlatine: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributs: PlatineAttributs) async throws -> SessionPlatine {
        JournalPartage.noter("session demandée : \(attributs.etat), piste \(attributs.pisteID), \(attributs.appareils.count) appareil(s)")
        Task { await Self.sonderReseau(serveur: attributs.serveur) }
        return SessionPlatine(attributs: attributs)
    }

    /// Essai témoin : quels chemins réseau l'extension a-t-elle le droit d'emprunter ?
    private static func sonderReseau(serveur: String) async {
        var cibles = [("Internet", "https://www.apple.com/library/test/success.html"), ("réseau local", serveur + "/api/config")]
        if let tailscale = Bundle.main.object(forInfoDictionaryKey: "PlatineSondeTailscale") as? String, !tailscale.isEmpty {
            cibles.append(("Tailscale", tailscale + "/api/config"))
        }
        for (nom, adresse) in cibles {
            guard let url = URL(string: adresse) else { continue }
            do {
                let (_, reponse) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
                JournalPartage.noter("sonde \(nom) : HTTP \((reponse as? HTTPURLResponse)?.statusCode ?? 0)")
            } catch {
                JournalPartage.noter("sonde \(nom) : \(JournalPartage.resumer(error))")
            }
        }
    }
}

@MainActor
@Observable
final class SessionPlatine: RemoteMediaSessionRepresentable {
    let id: String
    var attributs: PlatineAttributs

    init(attributs: PlatineAttributs) {
        id = attributs.id
        self.attributs = attributs
    }

    func update(_ attributs: PlatineAttributs) {
        self.attributs = attributs
    }

    private var client: ClientOwnTone? { ClientOwnTone(adresse: attributs.serveur) }

    var content: (any MediaContentRepresentable)? {
        guard attributs.pisteID != 0 else { return nil }
        let client = client
        let piste = attributs.pisteID
        let pochette = attributs.pochette
        return MusicContent(
            id: String(piste),
            songTitle: attributs.titre,
            artistName: attributs.artiste,
            albumName: attributs.album,
            type: .audio,
            duration: attributs.dureeMs > 0 ? .finite(Double(attributs.dureeMs) / 1000) : .live,
            artwork: pochette.isEmpty ? nil : Artwork(id: pochette) { taille in
                JournalPartage.noter("pochette demandée : piste \(piste), \(Int(taille.width))×\(Int(taille.height))")
                guard let client else { throw URLError(.badURL) }
                do {
                    let data = try await client.pochette(adresse: pochette)
                    JournalPartage.noter("pochette reçue : \(data.count) octets")
                    return try ArtworkRepresentation(data: data)
                } catch {
                    JournalPartage.noter("pochette en échec : \(JournalPartage.resumer(error))")
                    throw error
                }
            }
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        let etat: MediaPlaybackSnapshot.PlaybackState = switch attributs.etat {
        case "play": .playing()
        case "pause": .paused
        default: .stopped
        }
        return MediaPlaybackSnapshot(
            state: etat,
            elapsedTime: Double(attributs.positionMs) / 1000,
            timestamp: attributs.horodatage
        )
    }

    var commands: [MediaCommand] {
        [
            .play { try await self.commander("lecture") { try await $0.lecture() } },
            .pause { try await self.commander("pause") { try await $0.pause() } },
            .next { try await self.commander("suivant") { try await $0.suivant() } },
            .previous { try await self.commander("précédent") { try await $0.precedent() } },
            .seekToPosition { secondes in
                try await self.commander("position \(Int(secondes)) s") { try await $0.aller(a: secondes) }
            },
        ]
    }

    var devices: [MediaDevice] {
        attributs.appareils.map { appareil in
            MediaDevice(
                id: appareil.id,
                name: appareil.nom,
                type: .speaker,
                capabilities: [
                    .absoluteVolume(Float(appareil.volume) / 100) { niveau in
                        try await self.changerVolume(Int((niveau * 100).rounded()), sortie: appareil.id)
                    }
                ]
            )
        }
    }

    /// Envoie la commande, puis relit l'état d'OwnTone : la carte suit sans attendre une mise à jour de l'app.
    private func commander(_ nom: String, _ action: (ClientOwnTone) async throws -> Void) async throws {
        JournalPartage.noter("commande reçue : \(nom) → \(attributs.serveur)")
        guard let client else { throw URLError(.badURL) }
        do {
            try await action(client)
            JournalPartage.noter("commande acceptée par OwnTone : \(nom)")
        } catch {
            JournalPartage.noter("commande en échec : \(nom) : \(JournalPartage.resumer(error))")
            throw error
        }
        try? await Task.sleep(for: .milliseconds(400))
        if let etat = try? await client.lireEtat(id: id) {
            attributs = etat
        }
    }

    /// Règle le volume d'une sortie. Pas de relecture : elle ferait sauter le curseur pendant qu'on le fait glisser.
    private func changerVolume(_ niveau: Int, sortie: String) async throws {
        JournalPartage.noter("volume demandé : \(niveau) pour la sortie \(sortie)")
        guard let client else { throw URLError(.badURL) }
        do {
            try await client.volume(niveau, sortie: sortie)
        } catch {
            JournalPartage.noter("volume en échec : \(JournalPartage.resumer(error))")
            throw error
        }
        if let index = attributs.appareils.firstIndex(where: { $0.id == sortie }) {
            attributs.appareils[index].volume = niveau
        }
    }
}
