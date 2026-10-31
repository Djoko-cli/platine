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
        SessionPlatine(attributs: attributs)
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
        return MusicContent(
            id: String(piste),
            songTitle: attributs.titre,
            artistName: attributs.artiste,
            albumName: attributs.album,
            type: .audio,
            duration: attributs.dureeMs > 0 ? .finite(Double(attributs.dureeMs) / 1000) : .live,
            artwork: Artwork(id: "piste-\(piste)") { _ in
                guard let client else { throw URLError(.badURL) }
                return try ArtworkRepresentation(data: try await client.pochette(pisteID: piste))
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
            .play { try await self.commander { try await $0.lecture() } },
            .pause { try await self.commander { try await $0.pause() } },
            .next { try await self.commander { try await $0.suivant() } },
            .previous { try await self.commander { try await $0.precedent() } },
            .seekToPosition { secondes in try await self.commander { try await $0.aller(a: secondes) } },
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
    private func commander(_ action: (ClientOwnTone) async throws -> Void) async throws {
        guard let client else { throw URLError(.badURL) }
        try await action(client)
        try? await Task.sleep(for: .milliseconds(400))
        if let etat = try? await client.lireEtat(id: id) {
            attributs = etat
        }
    }

    /// Règle le volume d'une sortie. Pas de relecture : elle ferait sauter le curseur pendant qu'on le fait glisser.
    private func changerVolume(_ niveau: Int, sortie: String) async throws {
        guard let client else { throw URLError(.badURL) }
        try await client.volume(niveau, sortie: sortie)
        if let index = attributs.appareils.firstIndex(where: { $0.id == sortie }) {
            attributs.appareils[index].volume = niveau
        }
    }
}
