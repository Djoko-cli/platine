// Les jetons push de Platine : le jeton de démarrage, donné à l'app, et le jeton de mise à jour de chaque session,
// donné à l'extension. Chacun part au relais du NAS par le portier (relais/), et reste aussi dans le conteneur partagé
// (App Group), où le Mac le lit par devicectl (scripts/essai-push.py recuperer). Un fichier par processus : l'app et
// l'extension n'ont pas de verrou commun.
import Foundation
import os

enum JetonsPush {
    private static let verrou = OSAllocatedUnfairLock()

    static func hexadecimal(_ jeton: Data) -> String {
        jeton.map { String(format: "%02x", $0) }.joined()
    }

    /// Dans Library/Caches : devicectl ne lit le conteneur partagé que sous Library.
    private static func fichier(_ nom: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JournalPartage.groupe)?
            .appending(path: "Library/Caches/\(nom)")
    }

    /// Par l'app. Renvoie ce que le journal doit dire de l'envoi au relais.
    static func donnerDemarrage(_ jeton: Data) async -> String {
        let hex = hexadecimal(jeton)
        ecrire("jetons-demarrage.json") { $0["demarrage"] = hex }
        return await envoyer(type: "demarrage", session: "", jeton: hex)
    }

    /// Par l'extension.
    static func donnerSession(_ id: String, jeton: Data) async -> String {
        let hex = hexadecimal(jeton)
        ecrire("jetons-session.json") { $0[id] = hex }
        return await envoyer(type: "session", session: id, jeton: hex)
    }

    private static func ecrire(_ nom: String, _ changement: @Sendable (inout [String: String]) -> Void) {
        guard let fichier = fichier(nom) else { return }
        verrou.withLock {
            var contenu = (try? Data(contentsOf: fichier)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                ?? [:]
            changement(&contenu)
            if let data = try? JSONEncoder().encode(contenu) {
                try? data.write(to: fichier, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    private static func envoyer(type: String, session: String, jeton: String) async -> String {
        guard let portier = ClientOwnTone.portier else { return "relais : portier non réglé" }
        do {
            try await portier.donnerJeton(type: type, session: session, jeton: jeton)
            return "donné au relais"
        } catch {
            return "relais injoignable : \(JournalPartage.resumer(error))"
        }
    }
}
