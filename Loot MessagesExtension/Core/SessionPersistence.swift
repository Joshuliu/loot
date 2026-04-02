import UIKit

// MARK: - Persisted session snapshot

struct PersistedSession: Codable {
    let savedAt: Date
    let screenName: String
    let currentReceipt: ReceiptDisplay?
    let parsedReceipt: ParsedReceipt?
    let splitDraft: SplitDraft?
}

// MARK: - Save / load / clear

enum SessionPersistence {

    /// Sessions older than this are discarded on load.
    private static let ttl: TimeInterval = 3600 // 1 hour

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Save

    static func save(
        screen: AppScreen,
        receipt: ReceiptDisplay?,
        parsedReceipt: ParsedReceipt?,
        splitDraft: SplitDraft?,
        image: UIImage?,
        conversationKey: String
    ) {
        let session = PersistedSession(
            savedAt: Date(),
            screenName: screen.persistenceKey,
            currentReceipt: receipt,
            parsedReceipt: parsedReceipt,
            splitDraft: splitDraft
        )
        if let data = try? encoder.encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey(conversationKey))
        }
        if let image, let data = image.jpegData(compressionQuality: 0.75) {
            try? data.write(to: imageURL(conversationKey))
        }
    }

    // MARK: Load

    static func load(conversationKey: String) -> PersistedSession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey(conversationKey)),
              let session = try? decoder.decode(PersistedSession.self, from: data)
        else { return nil }

        guard Date().timeIntervalSince(session.savedAt) < ttl else {
            clear(conversationKey: conversationKey)
            return nil
        }
        return session
    }

    static func loadImage(conversationKey: String) -> UIImage? {
        guard let data = try? Data(contentsOf: imageURL(conversationKey)) else { return nil }
        return UIImage(data: data)
    }

    // MARK: Clear

    static func clear(conversationKey: String) {
        UserDefaults.standard.removeObject(forKey: sessionKey(conversationKey))
        try? FileManager.default.removeItem(at: imageURL(conversationKey))
    }

    // MARK: Helpers

    private static func sessionKey(_ key: String) -> String { "loot_session_\(key)" }

    private static func imageURL(_ key: String) -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("loot_crop_\(key).jpg")
    }
}

// MARK: - AppScreen persistence helpers

extension AppScreen {
    var persistenceKey: String {
        switch self {
        case .confirmation:      return "confirmation"
        case .fill:              return "fill"
        case .tipview:           return "tipview"
        case .paymentMethods:    return "paymentMethods"
        case .account:           return "account"
        default:                 return "tabview"
        }
    }

    /// Screens worth saving so the user lands back in the right place on reopen.
    var isPersistableScreen: Bool {
        switch self {
        case .confirmation, .fill, .tipview,
             .paymentMethods, .account:
            return true
        default:
            return false
        }
    }
}

extension AppScreen {
    static func from(persistenceKey key: String) -> AppScreen {
        switch key {
        case "fill":           return .fill
        case "tipview":        return .tipview
        case "paymentMethods": return .paymentMethods
        case "account":        return .account
        case "confirmation":   return .confirmation
        default:               return .tabview
        }
    }
}
