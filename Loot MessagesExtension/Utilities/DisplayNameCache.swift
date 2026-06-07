//
//  DisplayNameCache.swift
//  Loot
//
//  Synchronous uid → displayName cache backed by UserDefaults so every
//  rendering path (transcript bubble, baked card image, splits summary,
//  tab receipts list) can resolve a guest's live name from the same
//  source. Without this, three different renderers were each falling
//  back to a different frozen value at a different lifecycle moment,
//  producing the "payer on the card ≠ payer in the summary" mismatch.
//
//  Populated by:
//    • SplitsSummaryView.fetchMissingDisplayNames (Firestore users/{uid})
//    • TabService.fetchUserTabs / listenToTab (tab.members displayName)
//    • TabService.joinTab (any displayName fetched in passing)
//    • AccountView.save (the local user's own name on update)
//
//  Read by:
//    • SplitPayload.slotDisplayName(...)
//    • MessagesViewController.applyMessage / renderCardImage
//    • TabView.payerLabel
//

import Foundation

enum DisplayNameCache {
    private static let key = "loot.displayNameCache.v1"

    /// Returns a non-empty trimmed name for the uid, or nil if unknown.
    static func lookup(_ uid: String) -> String? {
        let trimmedUid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUid.isEmpty else { return nil }
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return nil
        }
        let raw = dict[trimmedUid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Stores (or refreshes) a uid → name mapping. No-op for empty inputs.
    static func remember(uid: String, name: String) {
        let trimmedUid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUid.isEmpty, !trimmedName.isEmpty else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if dict[trimmedUid] == trimmedName { return }
        dict[trimmedUid] = trimmedName
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Convenience: write many at once.
    static func remember(_ pairs: [(uid: String, name: String)]) {
        guard !pairs.isEmpty else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        var changed = false
        for (uid, name) in pairs {
            let tu = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            let tn = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tu.isEmpty, !tn.isEmpty else { continue }
            if dict[tu] != tn {
                dict[tu] = tn
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(dict, forKey: key)
        }
    }

    /// Snapshot of the current cache. Used by callers that want to pass an
    /// immutable dictionary into the resolver rather than performing N
    /// synchronous reads.
    static func snapshot() -> [String: String] {
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
}
