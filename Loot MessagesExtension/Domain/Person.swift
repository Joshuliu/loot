//
//  Person.swift
//  Loot MessagesExtension
//
//  Canonical participant identity. Phase 2 of the architectural refactor:
//  unifies the three pre-refactor representations (SplitGuest with UUID,
//  SplitPayload.Guest with abbreviated fields, TabMember with memberId).
//
//  PersonID is a stable string-based identifier that round-trips losslessly
//  across draft <-> wire <-> storage formats. When a brand-new unidentified
//  guest is added in the split editor, generate `PersonID(rawValue: UUID().uuidString)`.
//  When a tab member or Keychain user is the participant, set `userId`.
//

import Foundation

struct PersonID: Hashable, Codable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Generates a fresh ID for a brand-new unidentified guest.
    static func newGuest() -> PersonID {
        PersonID(rawValue: UUID().uuidString)
    }

    init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct Person: Identifiable, Hashable, Codable, Sendable {
    let id: PersonID
    var displayName: String
    /// Keychain UUID of the underlying Loot user, or nil for unidentified guests.
    var userId: String?

    init(id: PersonID, displayName: String, userId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.userId = userId
    }

    /// Convenience for a brand-new unidentified guest with a generated ID.
    static func newGuest(displayName: String) -> Person {
        Person(id: .newGuest(), displayName: displayName, userId: nil)
    }

    /// Convenience for a Person whose Keychain `userId` is known (local user, tab
    /// member, or any wire slot with a non-nil `uid`). The PersonID is derived
    /// directly from `userId` so encode → decode → encode round-trips back to
    /// the same identity.
    static func identified(userId: String, displayName: String) -> Person {
        Person(id: PersonID(rawValue: userId), displayName: displayName, userId: userId)
    }

    /// Convenience for the wire-decode boundary. If `uid` is non-nil and non-empty,
    /// the resulting Person carries a stable PersonID derived from it; otherwise
    /// the slot becomes an anonymous Person with a fresh ID per decode.
    static func fromWireSlot(uid: String?, displayName: String) -> Person {
        if let uid, !uid.isEmpty {
            return .identified(userId: uid, displayName: displayName)
        }
        return Person(id: .newGuest(), displayName: displayName, userId: nil)
    }

    /// Returns true if `userId` matches the local Keychain user.
    /// Caller must pass `KeychainHelper.getOrCreateUserId()` (or equivalent) — this
    /// keeps the domain layer free of platform dependencies.
    func isMe(localUserId: String) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        return userId == localUserId
    }

    /// Returns the displayName trimmed of leading/trailing whitespace, falling back
    /// to a synthesized default when empty.
    func resolvedDisplayName(meFallback: String = "Me", guestFallback: (Int) -> String = { "Guest \($0 + 1)" }, guestIndex: Int? = nil) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if userId != nil { return meFallback }
        if let guestIndex { return guestFallback(guestIndex) }
        return meFallback
    }
}
