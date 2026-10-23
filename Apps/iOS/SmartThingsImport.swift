#if DEBUG
import Foundation
import LarCore

/// A SmartThings integration handed over from the Mac during development (`devicectl device copy to` into the app's
/// Documents): read once at launch, saved to the keychain, and the file deleted.
enum SmartThingsImport {
    static let fileName = "smartthings-import.json"

    private struct Payload: Decodable {
        var clientID: String
        var secret: String
        var refreshToken: String
    }

    /// Whether an integration came in (the watch is then sent the accounts again).
    @MainActor
    static func run(_ model: LarModel) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let file = documents.appending(path: fileName)
        guard let data = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.clientID.isEmpty, !payload.secret.isEmpty, !payload.refreshToken.isEmpty else { return false }
        model.settings.smartThings = .oauth(clientID: payload.clientID, secret: payload.secret, refreshToken: payload.refreshToken)
        model.accountsChanged()
        return true
    }
}
#endif
