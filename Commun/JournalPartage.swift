// Journal que l'extension écrit dans le conteneur partagé (App Group) et que l'app affiche : sans outil de journal
// de l'iPhone sur le Mac, c'est la seule façon de voir au banc ce que fait l'extension (commandes reçues, erreurs).
import Foundation
import os

enum JournalPartage {
    static let groupe = "group.io.github.djoko-cli.platine"
    private static let journal = Logger(subsystem: "io.github.djoko-cli.platine", category: "session")
    private static let verrou = OSAllocatedUnfairLock()

    /// Dans Library/Caches : devicectl peut l'y lire depuis le Mac (il ne lit le conteneur partagé que sous Library).
    static var fichier: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupe)?
            .appending(path: "Library/Caches/journal-extension.txt")
    }

    /// Reprend le journal rangé à la racine du conteneur par les versions d'avant (devicectl ne le lit pas là).
    static func reprendreAncien() {
        guard let fichier, let racine = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupe)
        else { return }
        let ancien = racine.appending(path: "journal-extension.txt")
        guard FileManager.default.fileExists(atPath: ancien.path()),
              !FileManager.default.fileExists(atPath: fichier.path()) else { return }
        try? FileManager.default.moveItem(at: ancien, to: fichier)
    }

    /// Ajoute une ligne horodatée et garde les 200 dernières.
    static func noter(_ texte: String) {
        journal.log("\(texte, privacy: .public)")
        guard let fichier else { return }
        verrou.withLock {
            let heure = Date.now.formatted(date: .omitted, time: .standard)
            var lignes = (try? String(contentsOf: fichier, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            lignes.append("\(heure)  \(texte)")
            try? lignes.suffix(200).joined(separator: "\n").write(to: fichier, atomically: true, encoding: .utf8)
        }
    }

    /// Les lignes du journal, la plus récente en premier.
    static func lire() -> [String] {
        guard let fichier, let texte = try? String(contentsOf: fichier, encoding: .utf8) else { return [] }
        return texte.split(separator: "\n").map(String.init).reversed()
    }

    /// Une erreur réseau en une ligne : son code, et la raison du refus quand iOS en donne une.
    static func resumer(_ erreur: any Error) -> String {
        let ns = erreur as NSError
        let sous = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let chemin = (sous?.userInfo["_NSURLErrorNWPathKey"] ?? ns.userInfo["_NSURLErrorNWPathKey"]).map { "\($0)" } ?? ""
        let raison = chemin.range(of: #"\(([^)]*)\)"#, options: .regularExpression).map { String(chemin[$0]) } ?? ""
        return "\(ns.domain == NSURLErrorDomain ? "URLError" : ns.domain) \(ns.code) \(raison)"
    }

    static func vider() {
        guard let fichier else { return }
        verrou.withLock { try? FileManager.default.removeItem(at: fichier) }
    }
}
