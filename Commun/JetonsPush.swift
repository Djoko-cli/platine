// Les jetons push de Platine, rangés dans le conteneur partagé (App Group) : le jeton de démarrage, donné à l'app, et
// le jeton de mise à jour de chaque session, donné à l'extension. Pendant l'essai témoin, le Mac les lit par devicectl ;
// ensuite, ils iront au relais du NAS.
import Foundation
import os

enum JetonsPush {
    private static let verrou = OSAllocatedUnfairLock()

    private struct Contenu: Codable {
        var demarrage: String?
        var sessions: [String: String] = [:]
    }

    /// Dans Library/Caches : devicectl ne lit le conteneur partagé que sous Library.
    static var fichier: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JournalPartage.groupe)?
            .appending(path: "Library/Caches/jetons-push.json")
    }

    static func hexadecimal(_ jeton: Data) -> String {
        jeton.map { String(format: "%02x", $0) }.joined()
    }

    static func enregistrerDemarrage(_ jeton: Data) {
        modifier { $0.demarrage = hexadecimal(jeton) }
    }

    static func enregistrerSession(_ id: String, jeton: Data) {
        modifier { $0.sessions[id] = hexadecimal(jeton) }
    }

    private static func modifier(_ changement: @Sendable (inout Contenu) -> Void) {
        guard let fichier else { return }
        verrou.withLock {
            var contenu = (try? Data(contentsOf: fichier)).flatMap { try? JSONDecoder().decode(Contenu.self, from: $0) }
                ?? Contenu()
            changement(&contenu)
            if let data = try? JSONEncoder().encode(contenu) {
                try? data.write(to: fichier, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
}
