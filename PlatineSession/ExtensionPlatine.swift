// L'extension de session distante : le système la lance quand une session Platine démarre ou change, et lui demande
// la carte « en cours de lecture » (contenu, état, commandes, appareils avec leur volume). Les commandes touchées sur
// l'écran verrouillé ou dans le Centre de contrôle arrivent ici et partent vers l'API d'OwnTone.
import ExtensionFoundation
import Foundation
import NowPlaying

@main
struct ExtensionPlatine: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        _ = Self.binaireAuLancement  // relevé dès le lancement du processus, avant toute réinstallation
        return RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributs: PlatineAttributs) async throws -> SessionPlatine {
        Self.quitterSiPerimee()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        JournalPartage.noter("session demandée (extension \(version)) : \(attributs.etat), piste \(attributs.pisteID), \(attributs.appareils.count) appareil(s), \(ClientOwnTone.adressePortier == nil ? "OwnTone en direct" : "par le portier")")
        let session = SessionPlatine(attributs: attributs)
        JournalPartage.noter("lignes de la carte : \(session.devices.map(\.name).joined(separator: ", "))")
        return session
    }
}

extension ExtensionPlatine {
    /// La date du binaire qui tourne. Lue par FileManager, sans le cache de valeurs d'une URL.
    fileprivate static let binaireAuLancement = dateDuBinaire()

    private static func dateDuBinaire() -> Date? {
        Bundle.main.executablePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
    }

    /// mediaremoted garde le processus de l'extension en vie et le réutilise, même après une réinstallation de l'app :
    /// l'ancien code continuerait de répondre. Si le binaire sur le disque a changé ou disparu depuis le lancement,
    /// l'extension s'arrête ; iOS lance la nouvelle version à l'appel suivant. Sans date au lancement, rien n'est jugé.
    static func quitterSiPerimee() {
        guard let auLancement = binaireAuLancement, dateDuBinaire() != auLancement else { return }
        JournalPartage.noter("extension périmée (nouvelle version installée) : arrêt, la suivante prendra le relais")
        exit(0)
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
        suivreJetonPush()
    }

    /// Le jeton de mise à jour de cette session, donné au relais. Redonné à chaque réveil de l'extension : le relais
    /// ignore un jeton qu'il connaît déjà.
    private func suivreJetonPush() {
        let id = id
        let present = pushToken
        // Pris avant le premier envoi (un jeton changé pendant cet envoi n'est pas perdu), et sans retenir la session.
        let nouveaux = pushTokenUpdates
        Task {
            if let jeton = present {
                let envoi = await JetonsPush.donnerSession(id, jeton: jeton)
                JournalPartage.noter("jeton de session : présent (…\(JetonsPush.hexadecimal(jeton).suffix(4))), \(envoi)")
            }
            for await jeton in nouveaux {
                let envoi = await JetonsPush.donnerSession(id, jeton: jeton)
                JournalPartage.noter("nouveau jeton de session (…\(JetonsPush.hexadecimal(jeton).suffix(4))), \(envoi)")
            }
        }
    }

    func update(_ attributs: PlatineAttributs) {
        ExtensionPlatine.quitterSiPerimee()
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
            timestamp: Date(timeIntervalSince1970: attributs.horodatage)
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

    /// Une paire stéréo : OwnTone voit deux sorties, la carte n'en montre qu'une, dont le curseur règle les deux.
    private struct Paire {
        var membres: [String]
        var nom: String?
    }

    /// Les paires de Config/Local.xcconfig : PLATINE_PAIRES = <id>+<id>[=<nom>], séparées par des virgules.
    private static let paires: [Paire] = {
        guard let texte = Bundle.main.object(forInfoDictionaryKey: "PlatinePaires") as? String else { return [] }
        return texte.split(separator: ",").compactMap { entree in
            let morceaux = entree.split(separator: "=", maxSplits: 1)
            guard let liste = morceaux.first else { return nil }
            let membres = liste.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            guard membres.count >= 2 else { return nil }
            return Paire(membres: membres, nom: morceaux.count > 1 ? morceaux[1].trimmingCharacters(in: .whitespaces) : nil)
        }
    }()

    var devices: [MediaDevice] {
        var restants = attributs.appareils
        var resultat: [MediaDevice] = []
        for paire in Self.paires {
            let membres = restants.filter { paire.membres.contains($0.id) }
            guard membres.count >= 2 else { continue }
            restants.removeAll { paire.membres.contains($0.id) }
            let ids = membres.map(\.id)
            let volume = membres.map(\.volume).reduce(0, +) / membres.count
            resultat.append(MediaDevice(
                id: "paire-" + ids.joined(separator: "-"),
                name: paire.nom ?? Self.nomCommun(membres.map(\.nom)),
                type: Self.typeGroupe,
                capabilities: [
                    .absoluteVolume(Float(volume) / 100) { niveau in
                        for id in ids {
                            try await self.changerVolume(Int((niveau * 100).rounded()), sortie: id)
                        }
                    }
                ]
            ))
        }
        return resultat + restants.map { appareil in
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

    /// Le type « groupe d'enceintes » n'existe qu'à partir d'iOS 27.2.
    private static var typeGroupe: MediaDevice.DeviceType {
        if #available(iOS 27.2, *) { return .speakerGroup }
        return .speaker
    }

    /// Le nom commun aux membres d'une paire : « Enceinte D » et « Enceinte G » donnent « Enceinte ».
    private static func nomCommun(_ noms: [String]) -> String {
        guard var prefixe = noms.first else { return "Paire stéréo" }
        for nom in noms.dropFirst() {
            prefixe = String(prefixe.commonPrefix(with: nom))
        }
        let nom = prefixe.trimmingCharacters(in: .whitespaces)
        return nom.isEmpty ? "Paire stéréo" : nom
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
