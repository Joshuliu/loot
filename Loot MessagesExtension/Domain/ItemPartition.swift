//
//  ItemPartition.swift
//  Loot MessagesExtension
//
//  Per-item claim model for byItems splitting. Replaces the flat
//  `assignedGuestIds: [PersonID]` field on SplitDraft.Item with a richer
//  representation that supports:
//
//    - .unclaimed                              — initial state, no one's claimed yet
//    - .shares(denominator: N, slots: [...])  — locked-denominator partition where
//                                                 each share is owned by a PersonID
//                                                 or `nil` (still unclaimed)
//    - .custom([CustomClaim])                 — per-claimer dollar amounts; sum
//                                                 may be < priceCents (remainder
//                                                 stays unclaimed and sticks to
//                                                 the payer in SplitMath)
//
//  The two non-empty cases are mutually exclusive — once an item enters
//  shares mode (any denom > 0) or custom mode, it stays there. The Tap-to-Claim
//  UI uses this to enforce "first splitter freezes the denominator."
//
//  Backward compat: `legacyAssignedGuests(_:)` builds a `.shares` partition
//  with denom = ids.count, each slot owned by the corresponding ID. This
//  preserves the pre-shares semantics where multi-assign meant equal split.
//

import Foundation

enum ItemPartition: Equatable, Hashable {
    case unclaimed
    case shares(denominator: Int, slots: [PersonID?])
    case custom([CustomClaim])
}

struct CustomClaim: Equatable, Hashable, Codable, Sendable {
    var personID: PersonID
    var cents: Int

    init(personID: PersonID, cents: Int) {
        self.personID = personID
        self.cents = cents
    }
}

// MARK: - Construction

extension ItemPartition {
    /// Legacy mapping: `[A, B, C]` → shares with denom 3, each slot owned by the
    /// corresponding ID. Empty list → `.unclaimed`. Mirrors the pre-shares
    /// semantics where multi-assign on byItems meant equal split among assignees.
    static func legacyAssignedGuests(_ ids: [PersonID]) -> ItemPartition {
        if ids.isEmpty { return .unclaimed }
        return .shares(denominator: ids.count, slots: ids.map { Optional($0) })
    }
}

// MARK: - Cents math

extension ItemPartition {
    /// Cents claimed by `personID` for an item priced `priceCents`. 0 for unclaimed
    /// or for a person not present in the partition.
    func centsClaimed(by personID: PersonID, priceCents: Int) -> Int {
        switch self {
        case .unclaimed:
            return 0
        case .shares(let denom, let slots):
            guard denom > 0 else { return 0 }
            let parts = Money.splitEvenly(totalCents: max(0, priceCents), count: denom)
            var sum = 0
            for (i, slot) in slots.enumerated() where slot == personID {
                if parts.indices.contains(i) { sum += parts[i] }
            }
            return sum
        case .custom(let claims):
            return claims.reduce(0) { $0 + ($1.personID == personID ? max(0, $1.cents) : 0) }
        }
    }

    /// Total cents claimed across all claimers. Equal to `priceCents - unclaimedCents`.
    func claimedCents(priceCents: Int) -> Int {
        switch self {
        case .unclaimed:
            return 0
        case .shares(let denom, let slots):
            guard denom > 0 else { return 0 }
            let parts = Money.splitEvenly(totalCents: max(0, priceCents), count: denom)
            var sum = 0
            for (i, slot) in slots.enumerated() where slot != nil {
                if parts.indices.contains(i) { sum += parts[i] }
            }
            return sum
        case .custom(let claims):
            return claims.reduce(0) { $0 + max(0, $1.cents) }
        }
    }
}

// MARK: - Read accessors

extension ItemPartition {
    /// Deduplicated PersonIDs that have any non-zero claim, in order of first
    /// appearance. Used as a backward-compat read accessor for call sites that
    /// previously read `assignedGuestIds: [PersonID]`.
    var claimerPersonIDs: [PersonID] {
        switch self {
        case .unclaimed:
            return []
        case .shares(_, let slots):
            var seen: Set<PersonID> = []
            return slots.compactMap { $0 }.filter { seen.insert($0).inserted }
        case .custom(let claims):
            var seen: Set<PersonID> = []
            return claims.map(\.personID).filter { seen.insert($0).inserted }
        }
    }
}

// MARK: - PersonID remapping

extension ItemPartition {
    /// Returns a copy of this partition with every claimer PersonID rewritten
    /// via `map`. Slots/claims whose PersonID is missing from `map` are dropped
    /// (custom mode) or replaced with `nil` (shares mode).
    ///
    /// Used at boundaries where a PersonID universe changes — e.g., converting
    /// draft-internal IDs (random UUIDs for anonymous slots) into wire-canonical
    /// IDs (`"slot-N"` fallback) before handing to consumers that resolve
    /// PersonIDs via `guests.personID(forSlot:)`.
    func remappingPersonIDs(_ map: [PersonID: PersonID]) -> ItemPartition {
        switch self {
        case .unclaimed:
            return .unclaimed
        case .shares(let denom, let slots):
            return .shares(denominator: denom, slots: slots.map { $0.flatMap { map[$0] } })
        case .custom(let claims):
            return .custom(claims.compactMap { c in
                map[c.personID].map { CustomClaim(personID: $0, cents: c.cents) }
            })
        }
    }

    /// Returns a copy with `personID` removed from every share/claim.
    /// Shares they held become unclaimed (`nil`); if nobody is left, the
    /// partition collapses to `.unclaimed`. Used when a user leaves a
    /// bill — their item claims must vanish entirely, as if they never
    /// joined (not just the slot label).
    func removingClaimer(_ personID: PersonID) -> ItemPartition {
        switch self {
        case .unclaimed:
            return .unclaimed
        case .shares(let denom, let slots):
            let newSlots = slots.map { $0 == personID ? nil : $0 }
            return newSlots.contains(where: { $0 != nil })
                ? .shares(denominator: denom, slots: newSlots)
                : .unclaimed
        case .custom(let claims):
            let kept = claims.filter { $0.personID != personID }
            return kept.isEmpty ? .unclaimed : .custom(kept)
        }
    }
}

// MARK: - Codable

extension ItemPartition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, denominator, slots, claims
    }

    private enum Kind: String, Codable {
        case unclaimed, shares, custom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .unclaimed:
            self = .unclaimed
        case .shares:
            let denom = try c.decode(Int.self, forKey: .denominator)
            let slots = try c.decode([PersonID?].self, forKey: .slots)
            self = .shares(denominator: denom, slots: slots)
        case .custom:
            let claims = try c.decode([CustomClaim].self, forKey: .claims)
            self = .custom(claims)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unclaimed:
            try c.encode(Kind.unclaimed, forKey: .kind)
        case .shares(let denom, let slots):
            try c.encode(Kind.shares, forKey: .kind)
            try c.encode(denom, forKey: .denominator)
            try c.encode(slots, forKey: .slots)
        case .custom(let claims):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(claims, forKey: .claims)
        }
    }
}
