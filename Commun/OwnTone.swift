// Ce que l'app et l'extension partagent : l'état d'une lecture d'OwnTone, tel que la session distante le transporte,
// et un petit client de l'API JSON d'OwnTone (lecture de l'état, commandes, volume par sortie, pochette).
import Foundation
import NowPlaying

/// L'état d'OwnTone transmis au système. L'app le donne à `RemoteMediaSession.start` et `update` ; le système le
/// remet à l'extension, qui en tire la carte « en cours de lecture ».
struct PlatineAttributs: RemoteMediaSessionAttributes, Equatable {
    struct Appareil: Codable, Equatable, Sendable {
        var id: String
        var nom: String
        var volume: Int  // 0 à 100, comme OwnTone
    }

    var id: String
    var serveur: String  // l'adresse d'OwnTone, pour que l'extension sache où envoyer les commandes
    var etat: String  // "play", "pause" ou "stop"
    var pisteID: Int  // 0 quand rien n'est en file
    var titre: String
    var artiste: String
    var album: String
    var pochette: String  // l'adresse complète de la pochette donnée par OwnTone, vide s'il n'y en a pas
    var dureeMs: Int
    var positionMs: Int
    var horodatage: Date  // moment où positionMs a été relevée
    var appareils: [Appareil]  // les sorties d'OwnTone actives

    /// Ce qui mérite une mise à jour de la session : tout sauf l'avancement, que le système extrapole.
    var signature: String {
        "\(etat)|\(pisteID)|\(appareils.map { "\($0.id):\($0.volume)" }.joined(separator: ","))"
    }
}

struct ClientOwnTone: Sendable {
    let serveur: URL

    init?(adresse: String) {
        guard let url = URL(string: adresse.trimmingCharacters(in: .whitespaces)), url.host != nil else { return nil }
        serveur = url
    }

    private struct Lecteur: Decodable {
        var state: String
        var item_id: Int
        var item_length_ms: Int
        var item_progress_ms: Int
    }

    private struct Sorties: Decodable {
        struct Sortie: Decodable {
            var id: String
            var name: String
            var selected: Bool
            var volume: Int
        }
        var outputs: [Sortie]
    }

    private struct File: Decodable {
        struct Element: Decodable {
            var id: Int
            var title: String?
            var artist: String?
            var album: String?
            var length_ms: Int?
            var artwork_url: String?  // relative à OwnTone (« ./artwork/item/<morceau>?v=… ») ou absolue
        }
        var items: [Element]
    }

    private func lire<T: Decodable>(_ chemin: String, comme type: T.Type) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: serveur.appending(path: chemin))
        return try JSONDecoder().decode(type, from: data)
    }

    func lireEtat(id: String) async throws -> PlatineAttributs {
        async let lecteur = lire("api/player", comme: Lecteur.self)
        async let sorties = lire("api/outputs", comme: Sorties.self)
        let (l, s) = try await (lecteur, sorties)
        let piste = l.item_id != 0
            ? try await lire("api/queue", comme: File.self).items.first { $0.id == l.item_id }
            : nil
        return PlatineAttributs(
            id: id,
            serveur: serveur.absoluteString,
            etat: l.state,
            pisteID: piste?.id ?? 0,
            titre: piste?.title ?? "",
            artiste: piste?.artist ?? "",
            album: piste?.album ?? "",
            pochette: piste?.artwork_url.flatMap { URL(string: $0, relativeTo: serveur.appending(path: ""))?.absoluteString } ?? "",
            dureeMs: piste?.length_ms ?? l.item_length_ms,
            positionMs: l.item_progress_ms,
            horodatage: .now,
            appareils: s.outputs.filter(\.selected).map { .init(id: $0.id, nom: $0.name, volume: $0.volume) }
        )
    }

    private func envoyer(_ chemin: String, requete: [URLQueryItem] = [], corps: [String: Int]? = nil) async throws {
        var demande = URLRequest(url: serveur.appending(path: chemin).appending(queryItems: requete))
        demande.httpMethod = "PUT"
        if let corps {
            demande.setValue("application/json", forHTTPHeaderField: "Content-Type")
            demande.httpBody = try JSONEncoder().encode(corps)
        }
        let (_, reponse) = try await URLSession.shared.data(for: demande)
        let code = (reponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
    }

    func lecture() async throws { try await envoyer("api/player/play") }
    func pause() async throws { try await envoyer("api/player/pause") }
    func suivant() async throws { try await envoyer("api/player/next") }
    func precedent() async throws { try await envoyer("api/player/previous") }

    func aller(a secondes: TimeInterval) async throws {
        try await envoyer("api/player/seek", requete: [URLQueryItem(name: "position_ms", value: String(Int(secondes * 1000)))])
    }

    func volume(_ niveau: Int, sortie: String) async throws {
        try await envoyer("api/outputs/\(sortie)", corps: ["volume": min(max(niveau, 0), 100)])
    }

    func pochette(adresse: String) async throws -> Data {
        guard var url = URL(string: adresse) else { throw URLError(.badURL) }
        if url.host == serveur.host {
            url.append(queryItems: [URLQueryItem(name: "maxwidth", value: "600"), URLQueryItem(name: "maxheight", value: "600")])
        }
        let (data, reponse) = try await URLSession.shared.data(from: url)
        guard (reponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return data
    }
}
