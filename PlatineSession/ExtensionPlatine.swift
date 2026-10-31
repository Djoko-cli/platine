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
        JournalPartage.noter("session demandée : \(attributs.etat), piste \(attributs.pisteID), \(attributs.appareils.count) appareil(s), \(ClientOwnTone.adressePortier == nil ? "OwnTone en direct" : "par le portier")")
        return SessionPlatine(attributs: attributs)
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

    /// Les volumes demandés pendant qu'un envoi est en cours : seule la dernière valeur de chaque sortie part.
    private var volumesEnAttente: [String: Int] = [:]
    private var volumesEnCours: Set<String> = []

    /// Le portier : iOS refuse le réseau local à l'extension. Sans portier, elle ne joint OwnTone que par l'adresse
    /// transmise par l'app, donc hors de la maison, par un tunnel.
    private var client: ClientOwnTone? { ClientOwnTone.portier ?? ClientOwnTone(adresse: attributs.serveur) }

    /// La pochette servie par OwnTone pointe vers son adresse locale : on la fait passer par le portier. Une pochette
    /// hébergée ailleurs reste telle quelle (et ne reçoit pas le jeton).
    private var adressePochette: String {
        guard let portier = ClientOwnTone.adressePortier.flatMap({ URLComponents(string: $0) }),
              var pochette = URLComponents(string: attributs.pochette),
              pochette.host == URL(string: attributs.serveur)?.host else {
            return attributs.pochette
        }
        pochette.scheme = portier.scheme
        pochette.host = portier.host
        pochette.port = portier.port
        return pochette.string ?? attributs.pochette
    }

    var content: (any MediaContentRepresentable)? {
        guard attributs.pisteID != 0 else { return nil }
        let client = client
        let piste = attributs.pisteID
        let pochette = adressePochette
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
        JournalPartage.noter("commande reçue : \(nom) → \(client?.serveur.host() ?? "?")")
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

    /// Règle le volume d'une sortie. Un curseur qui glisse envoie une rafale de valeurs : pendant qu'un envoi est en
    /// cours, seule la dernière valeur est gardée, puis envoyée. Pas de relecture d'OwnTone : elle ferait sauter le
    /// curseur pendant qu'on le fait glisser.
    private func changerVolume(_ niveau: Int, sortie: String) async throws {
        if let index = attributs.appareils.firstIndex(where: { $0.id == sortie }) {
            attributs.appareils[index].volume = niveau
        }
        volumesEnAttente[sortie] = niveau
        guard !volumesEnCours.contains(sortie) else { return }
        guard let client else { throw URLError(.badURL) }
        volumesEnCours.insert(sortie)
        defer { volumesEnCours.remove(sortie) }
        while let valeur = volumesEnAttente.removeValue(forKey: sortie) {
            do {
                try await client.volume(valeur, sortie: sortie)
                JournalPartage.noter("volume envoyé : \(valeur) pour la sortie \(sortie)")
            } catch {
                JournalPartage.noter("volume en échec : \(JournalPartage.resumer(error))")
                throw error
            }
        }
    }
}
