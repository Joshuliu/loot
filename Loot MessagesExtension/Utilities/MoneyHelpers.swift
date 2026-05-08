//
//  MoneyHelpers.swift
//  Loot MessagesExtension
//
//  Shared currency utilities used across the extension.
//

import Foundation

/// Parses a user-entered currency string (e.g. "$12.50", "12.50", "12") into integer cents.
/// Negative values are clamped to 0; for signed parsing use `signedStringToCents`.
func stringToCents(_ raw: String) -> Int {
    Money(parsing: raw).cents
}

/// Formats cents as a plain decimal string for text field display (e.g. 1250 → "12.50", no $ sign).
/// Preserves sign for negative values (e.g. -500 → "-5.00").
func centsToDecimalString(_ cents: Int) -> String {
    Money(cents: cents).inputString
}

/// Parses a signed currency string (e.g. "-5.00", "12.50") into integer cents.
/// Unlike stringToCents, this preserves negative values (used for fee/discount fields).
func signedStringToCents(_ raw: String) -> Int {
    Money(parsingSigned: raw).cents
}

/// Splits `total` cents across `count` participants, distributing remainder
/// cents to the earliest indices so shares always sum back to `total`.
func splitCentsEvenly(total: Int, count: Int) -> [Int] {
    guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
    var out = Array(repeating: total / count, count: count)
    let remainder = total - out.reduce(0, +)
    if remainder > 0 {
        for i in 0..<min(remainder, count) { out[i] += 1 }
    }
    return out
}

/// Computes one guest's by-items subtotal using deterministic remainder handling.
/// Guest ordering defines which assignees receive remainder cents first.
func byItemsGuestSubtotalCents(
    guestID: PersonID,
    guestOrder: [PersonID],
    items: [(priceCents: Int, assignedGuestIDs: [PersonID])]
) -> Int {
    let orderIndex: [PersonID: Int] = Dictionary(uniqueKeysWithValues: guestOrder.enumerated().map { ($1, $0) })

    return items.reduce(0) { acc, item in
        let assignedUnique = Set(item.assignedGuestIDs)
        let assignedSorted = assignedUnique.sorted { lhs, rhs in
            let li = orderIndex[lhs] ?? Int.max
            let ri = orderIndex[rhs] ?? Int.max
            if li == ri { return lhs.rawValue < rhs.rawValue }
            return li < ri
        }
        guard let guestPosition = assignedSorted.firstIndex(of: guestID) else { return acc }
        let shares = splitCentsEvenly(total: max(0, item.priceCents), count: assignedSorted.count)
        return acc + (shares.indices.contains(guestPosition) ? shares[guestPosition] : 0)
    }
}

// MARK: - Split Math (equal/custom/by-items)

enum SplitMath {
    static func computeOwedCents(
        mode: SplitPayload.Mode,
        guests: [SplitPayload.Guest],
        payerIndex: Int,
        totalCents: Int,
        perGuestActive: [Int]?,
        items: [(label: String, priceCents: Int, assignedSlots: [Int])],
        feesCents: Int,
        discountCents: Int,
        taxCents: Int,
        tipCents: Int
    ) -> [Int] {

        let included = guests.indices.filter { guests[$0].inc }
        guard !included.isEmpty else { return Array(repeating: 0, count: guests.count) }

        let safePayer = included.contains(payerIndex) ? payerIndex : (included.first ?? 0)

        var owed = Array(repeating: 0, count: guests.count)

        switch mode {
        case .equally:
            let shares = splitCentsEvenly(total: totalCents, count: included.count)
            for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            return owed

        case .custom:
            if let perGuestActive, perGuestActive.count == included.count {
                for (i, idx) in included.enumerated() { owed[idx] = max(0, perGuestActive[i]) }
            } else {
                let shares = splitCentsEvenly(total: totalCents, count: included.count)
                for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            }
            return owed

        case .byItems:
            var subtotals = Array(repeating: 0, count: guests.count)

            for it in items {
                let assigned = it.assignedSlots.filter { guests.indices.contains($0) && guests[$0].inc }
                let targets = assigned.isEmpty ? [safePayer] : assigned.sorted()
                let parts = splitCentsEvenly(total: max(0, it.priceCents), count: targets.count)
                for (i, gidx) in targets.enumerated() { subtotals[gidx] += parts[i] }
            }

            // Anchor `extras` on `totalCents - itemsTotal` rather than
            // `feesCents - discountCents + taxCents + tipCents`. The latter
            // formula assumed `sum(item.priceCents) == subtotal`, which
            // breaks whenever items don't fully account for the subtotal —
            // empty items array (Phase 2 OCR returned nothing), partial
            // capture, or items dropped by the `isComplete` filter at
            // payload-build time. Result of the old formula: per-guest
            // owed cents summed below `totalCents`, and the bill card
            // donut ring visibly under-filled. Anchoring on `totalCents`
            // guarantees `owed.sum == totalCents` for every input.
            let itemsTotal = subtotals.reduce(0, +)
            let extras = max(0, totalCents - itemsTotal)
            let extrasAlloc = allocateProportional(total: extras, base: subtotals, included: included)

            for idx in included {
                owed[idx] = max(0, subtotals[idx] + extrasAlloc[idx])
            }

            return owed
        }
    }

    /// Computes per-guest owed amounts from an in-flight `SplitDraft`,
    /// falling back to an equal split across `participantCount` when no
    /// draft exists yet (Phase 1 still running). Used by ConfirmationView's
    /// bill card to drive the owed-ring rendering. Lifted out of
    /// ConfirmationView in Phase 4 — pure compute, depends only on inputs.
    static func owedFromDraft(
        _ draft: SplitDraft?,
        fallbackTotalCents: Int,
        participantCount: Int
    ) -> [Int]? {
        if let draft {
            guard !draft.includedGuests.isEmpty else { return nil }

            let mode: SplitPayload.Mode = {
                switch draft.mode {
                case .equally: return .equally
                case .custom: return .custom
                case .byItems: return .byItems
                }
            }()

            let guests: [SplitPayload.Guest] = draft.guests.map { p in
                SplitPayload.Guest(n: p.displayName, inc: draft.includedIDs.contains(p.id), uid: p.userId)
            }

            let payerIndex = draft.guests.firstIndex(where: { $0.id == draft.payerID }) ?? 0

            let items: [(label: String, priceCents: Int, assignedSlots: [Int])] = draft.items.map { item in
                let slots = item.assignedGuestIds.compactMap { gid in
                    draft.guests.firstIndex(where: { $0.id == gid })
                }
                return (label: item.label, priceCents: item.priceCents, assignedSlots: slots)
            }

            // Prefer the draft's total; fall back to the live `amount` prop
            // when the draft total is still 0 (Phase 1 not yet returned).
            let effectiveTotal = (draft.totalCents > 0) ? draft.totalCents : fallbackTotalCents

            return computeOwedCents(
                mode: mode,
                guests: guests,
                payerIndex: payerIndex,
                totalCents: effectiveTotal,
                perGuestActive: draft.perGuestCents,
                items: items,
                feesCents: draft.feesCents,
                discountCents: draft.discountCents,
                taxCents: draft.taxCents,
                tipCents: draft.tipCents
            )
        } else {
            guard participantCount > 0 else { return nil }
            return splitCentsEvenly(total: fallbackTotalCents, count: participantCount)
        }
    }

    private static func allocateProportional(total: Int, base: [Int], included: [Int]) -> [Int] {
        var out = Array(repeating: 0, count: base.count)
        guard total != 0 else { return out }

        let sumBase = included.reduce(0) { $0 + max(0, base[$1]) }
        if sumBase <= 0 {
            let shares = splitCentsEvenly(total: total, count: included.count)
            for (i, idx) in included.enumerated() { out[idx] = shares[i] }
            return out
        }

        var floors: [Int] = []
        var fracs: [(idx: Int, frac: Double)] = []

        var used = 0
        for idx in included {
            let b = Double(max(0, base[idx]))
            let raw = (Double(total) * b) / Double(sumBase)
            let f = Int(floor(raw))
            floors.append(f)
            used += f
            fracs.append((idx: idx, frac: raw - Double(f)))
        }

        for (i, idx) in included.enumerated() {
            out[idx] = floors[i]
        }

        var rem = total - used
        if rem > 0 {
            fracs.sort { $0.frac > $1.frac }
            var j = 0
            while rem > 0 && !fracs.isEmpty {
                out[fracs[j % fracs.count].idx] += 1
                rem -= 1
                j += 1
            }
        }
        return out
    }
}
