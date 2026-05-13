//
//  SplitDraft.swift
//  Loot MessagesExtension
//
//  In-flight split state used by ConfirmationView, SplitView, and EditSplitView.
//  Owns a Person list, an inclusion set, the payer identity, and per-mode
//  amounts/items. Pure Foundation so the TestHarness SPM target can exercise
//  it; no SwiftUI/UIKit imports.
//
//  Phase 2.8: replaces the legacy `SplitGuest` (UUID id, isIncluded, isMe, uid)
//  with `Person` plus a separate `includedIDs: Set<PersonID>`. The wire format
//  in `SplitPayload` is unchanged; conversion happens at the wire boundary.
//

import Foundation

struct SplitDraft: Equatable, Codable {
    enum Mode: String, CaseIterable, Codable {
        case equally = "Split Equally"
        case byItems = "Split by Items"
        case custom = "Custom Split"
    }

    struct Item: Identifiable, Equatable, Codable {
        let id: UUID
        var label: String
        var priceCents: Int
        var partition: ItemPartition

        init(id: UUID, label: String, priceCents: Int, partition: ItemPartition) {
            self.id = id
            self.label = label
            self.priceCents = priceCents
            self.partition = partition
        }

        /// Convenience: builds a `.shares` partition with one slot per assignee
        /// (or `.unclaimed` when empty). Preserves the pre-shares semantics so
        /// existing call sites compile without modification.
        init(id: UUID, label: String, priceCents: Int, assignedGuestIds: [PersonID]) {
            self.init(
                id: id,
                label: label,
                priceCents: priceCents,
                partition: .legacyAssignedGuests(assignedGuestIds)
            )
        }

        /// Backward-compat read accessor for sites that previously read
        /// `assignedGuestIds`. New code should read `partition` directly.
        var assignedGuestIds: [PersonID] {
            partition.claimerPersonIDs
        }

        enum CodingKeys: String, CodingKey {
            case id, label, priceCents, partition
            case assignedGuestIds  // legacy
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            priceCents = try c.decode(Int.self, forKey: .priceCents)
            if let p = try? c.decode(ItemPartition.self, forKey: .partition) {
                partition = p
            } else if let legacy = try? c.decode([PersonID].self, forKey: .assignedGuestIds) {
                partition = .legacyAssignedGuests(legacy)
            } else {
                partition = .unclaimed
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(priceCents, forKey: .priceCents)
            try c.encode(partition, forKey: .partition)
        }
    }

    var guests: [Person]
    /// Subset of `guests` (by PersonID) participating in this split.
    /// Replaces the per-guest `isIncluded` Bool from the legacy `SplitGuest`.
    var includedIDs: Set<PersonID>
    var payerID: PersonID
    var mode: Mode
    var totalCents: Int
    /// Per-included-guest amounts in the order they appear in `guests`.
    var perGuestCents: [Int]
    var items: [Item]
    var feesCents: Int
    var discountCents: Int
    var taxCents: Int
    var tipCents: Int
    /// Tap-to-Claim variant of `byItems`: recipients claim their own items in
    /// chat. Only meaningful when `mode == .byItems`. Round-trips through the
    /// wire payload's `cl` flag.
    var claimMode: Bool

    init(
        guests: [Person],
        includedIDs: Set<PersonID>? = nil,
        payerID: PersonID,
        mode: Mode,
        totalCents: Int,
        perGuestCents: [Int],
        items: [Item],
        feesCents: Int,
        discountCents: Int,
        taxCents: Int,
        tipCents: Int,
        claimMode: Bool = false
    ) {
        self.guests = guests
        self.includedIDs = includedIDs ?? Set(guests.map(\.id))
        self.payerID = payerID
        self.mode = mode
        self.totalCents = totalCents
        self.perGuestCents = perGuestCents
        self.items = items
        self.feesCents = feesCents
        self.discountCents = discountCents
        self.taxCents = taxCents
        self.tipCents = tipCents
        self.claimMode = claimMode
    }

    /// Guests included in this split, in the order they appear in `guests`.
    var includedGuests: [Person] {
        guests.filter { includedIDs.contains($0.id) }
    }

    func isIncluded(_ id: PersonID) -> Bool {
        includedIDs.contains(id)
    }

    // MARK: - Codable (legacy-tolerant)

    enum CodingKeys: String, CodingKey {
        case guests, includedIDs, payerID
        case payerGuestId  // legacy field name from pre-Phase-2.8 sessions
        case mode, totalCents, perGuestCents, items
        case feesCents, discountCents, taxCents, tipCents
        case claimMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // guests: try modern shape ([Person]) first, fall back to the legacy
        // SplitGuest shape so SessionPersistence JSON written before Phase 2.8
        // still loads.
        let modernGuests = try? c.decode([Person].self, forKey: .guests)
        let legacyGuests = (modernGuests == nil)
            ? (try? c.decode([LegacySplitGuestEntry].self, forKey: .guests))
            : nil

        if let modern = modernGuests {
            self.guests = modern
        } else if let legacy = legacyGuests {
            self.guests = legacy.map { lg in
                Person(
                    id: PersonID(rawValue: lg.id.uuidString),
                    displayName: lg.name,
                    userId: lg.uid
                )
            }
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath + [CodingKeys.guests],
                debugDescription: "guests is neither [Person] nor legacy [SplitGuest]"
            ))
        }

        // includedIDs: try the new field first; fall back to per-guest isIncluded
        // from the legacy shape; if neither, default to "everyone included".
        if let inc = try? c.decode(Set<PersonID>.self, forKey: .includedIDs) {
            self.includedIDs = inc
        } else if let legacy = legacyGuests {
            self.includedIDs = Set(
                legacy
                    .filter(\.isIncluded)
                    .map { PersonID(rawValue: $0.id.uuidString) }
            )
        } else {
            self.includedIDs = Set(self.guests.map(\.id))
        }

        // payerID: try the new key, else fall back to legacy `payerGuestId: UUID`.
        if let pid = try? c.decode(PersonID.self, forKey: .payerID) {
            self.payerID = pid
        } else if let legacyPayer = try? c.decode(UUID.self, forKey: .payerGuestId) {
            self.payerID = PersonID(rawValue: legacyPayer.uuidString)
        } else {
            self.payerID = self.guests.first?.id ?? PersonID(rawValue: "")
        }

        self.mode = try c.decode(Mode.self, forKey: .mode)
        self.totalCents = try c.decode(Int.self, forKey: .totalCents)
        self.perGuestCents = try c.decode([Int].self, forKey: .perGuestCents)
        self.items = try c.decode([Item].self, forKey: .items)
        self.feesCents = try c.decode(Int.self, forKey: .feesCents)
        self.discountCents = try c.decode(Int.self, forKey: .discountCents)
        self.taxCents = try c.decode(Int.self, forKey: .taxCents)
        self.tipCents = try c.decode(Int.self, forKey: .tipCents)
        self.claimMode = (try? c.decode(Bool.self, forKey: .claimMode)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guests, forKey: .guests)
        try c.encode(includedIDs, forKey: .includedIDs)
        try c.encode(payerID, forKey: .payerID)
        try c.encode(mode, forKey: .mode)
        try c.encode(totalCents, forKey: .totalCents)
        try c.encode(perGuestCents, forKey: .perGuestCents)
        try c.encode(items, forKey: .items)
        try c.encode(feesCents, forKey: .feesCents)
        try c.encode(discountCents, forKey: .discountCents)
        try c.encode(taxCents, forKey: .taxCents)
        try c.encode(tipCents, forKey: .tipCents)
        if claimMode { try c.encode(true, forKey: .claimMode) }
    }
}

/// Mirrors the pre-Phase-2.8 `SplitGuest` JSON shape so SessionPersistence
/// records written by older builds still decode. Used only inside SplitDraft's
/// custom `init(from:)` — never surfaces to call sites.
private struct LegacySplitGuestEntry: Codable {
    let id: UUID
    let name: String
    let isIncluded: Bool
    let isMe: Bool
    let uid: String?
}
