//
//  TabMembershipCache.swift
//  Loot
//
//  Synchronous "tabs I'm a member of" cache backed by UserDefaults.
//  The transcript-mode MessagesViewController runs in a lightweight
//  path with no Firebase auth and no `userTabs` fetch (see
//  `configureAsTranscript` / `renderTranscriptBubble`), so it can't
//  ask Firestore "am I in this tab?" synchronously while building
//  the invite bubble. This cache is mirrored from
//  `TabContextViewModel.userTabs` whenever that list changes, so the
//  transcript path can answer membership lookups instantly.
//
//  Sources of truth:
//    • `TabService.fetchUserTabs()` — extension launch
//    • `joinTab` / `createTab` — bumps userTabs which mirrors here
//    • `leaveTab` / `deleteTab` — same, removal mirrors here
//

import Foundation

enum TabMembershipCache {
    private static let key = "loot.tabMembershipCache.v1"

    /// True if the local user is recorded as a member of `tabId`.
    static func isMember(of tabId: String) -> Bool {
        let trimmed = tabId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return current().contains(trimmed)
    }

    /// Overwrites the cached set of tab IDs the user belongs to. Pass the
    /// list of `userTabs.compactMap(\.id)` after `userTabs` is set.
    /// No-op when the new set matches the cached one (avoids needless
    /// UserDefaults writes / KVO churn).
    static func replaceAll(tabIds: [String]) {
        let normalized = Set(tabIds.compactMap { id -> String? in
            let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        })
        if normalized == current() { return }
        UserDefaults.standard.set(Array(normalized), forKey: key)
    }

    /// Adds a tab ID to the cache (use after a successful join / create).
    static func add(_ tabId: String) {
        let trimmed = tabId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var set = current()
        if set.insert(trimmed).inserted {
            UserDefaults.standard.set(Array(set), forKey: key)
        }
    }

    /// Removes a tab ID from the cache (use after leave / delete).
    static func remove(_ tabId: String) {
        let trimmed = tabId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var set = current()
        if set.remove(trimmed) != nil {
            UserDefaults.standard.set(Array(set), forKey: key)
        }
    }

    private static func current() -> Set<String> {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return Set(arr)
    }
}
