//
//  SplitConfiguration.swift
//  Loot MessagesExtension
//
//  Canonical split configuration. Phase 2 of the architectural refactor:
//  unifies SplitMode (TabModels), SplitDraft.Mode (SplitView), and the wire
//  format SplitPayload.Mode ("eq"/"it"/"cu") at the domain layer. Wire
//  encoding still uses the abbreviated keys for compactness — translation
//  happens at the wire adapter boundary.
//

import Foundation

enum SplitMode: String, Codable, Hashable, Sendable, CaseIterable {
    case equally
    case byItems
    case custom
}

struct SplitConfiguration: Codable, Hashable, Sendable {
    var participants: [Person]
    /// IDs of participants who are part of this split (subset of participants).
    var includedIDs: Set<PersonID>
    var payerID: PersonID
    var mode: SplitMode
    /// Per-participant explicit amounts when mode == .custom. nil otherwise.
    var customCents: [PersonID: Int]?
    /// Set of participant IDs who have marked themselves paid.
    var paid: Set<PersonID>

    init(
        participants: [Person],
        includedIDs: Set<PersonID>,
        payerID: PersonID,
        mode: SplitMode,
        customCents: [PersonID: Int]? = nil,
        paid: Set<PersonID> = []
    ) {
        self.participants = participants
        self.includedIDs = includedIDs
        self.payerID = payerID
        self.mode = mode
        self.customCents = customCents
        self.paid = paid
    }

    /// Convenience constructor: include everyone, payer is first participant.
    static func defaultEqually(participants: [Person]) -> SplitConfiguration? {
        guard let first = participants.first else { return nil }
        return SplitConfiguration(
            participants: participants,
            includedIDs: Set(participants.map(\.id)),
            payerID: first.id,
            mode: .equally
        )
    }

    /// Returns participants in original order whose IDs are included.
    var includedParticipants: [Person] {
        participants.filter { includedIDs.contains($0.id) }
    }

    /// True when at least one participant is included and the payer is among them.
    var isValid: Bool {
        !includedIDs.isEmpty && participants.contains(where: { $0.id == payerID })
    }

    /// True when this person is included in the split.
    func isIncluded(_ id: PersonID) -> Bool {
        includedIDs.contains(id)
    }

    /// True when this person has marked themselves paid.
    func isPaid(_ id: PersonID) -> Bool {
        paid.contains(id)
    }

    /// Look up a participant by ID. Returns nil if not in the participant list.
    func participant(_ id: PersonID) -> Person? {
        participants.first(where: { $0.id == id })
    }

    /// Returns a copy with the included flag toggled for `id`.
    /// If `id` is not in `participants`, returns self unchanged.
    func togglingIncluded(_ id: PersonID) -> SplitConfiguration {
        guard participants.contains(where: { $0.id == id }) else { return self }
        var copy = self
        if copy.includedIDs.contains(id) {
            copy.includedIDs.remove(id)
        } else {
            copy.includedIDs.insert(id)
        }
        return copy
    }

    /// Returns a copy with the paid flag toggled for `id`.
    /// If `id` is not in `participants`, returns self unchanged.
    func togglingPaid(_ id: PersonID) -> SplitConfiguration {
        guard participants.contains(where: { $0.id == id }) else { return self }
        var copy = self
        if copy.paid.contains(id) {
            copy.paid.remove(id)
        } else {
            copy.paid.insert(id)
        }
        return copy
    }
}
