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
        items: [(label: String, priceCents: Int, partition: ItemPartition)],
        feesCents: Int,
        discountCents: Int,
        taxCents: Int,
        tipCents: Int,
        claimMode: Bool = false
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
                var attributedToSlots = 0
                for slotIndex in guests.indices where guests[slotIndex].inc {
                    let pid = guests.personID(forSlot: slotIndex)
                    let cents = it.partition.centsClaimed(by: pid, priceCents: it.priceCents)
                    subtotals[slotIndex] += cents
                    attributedToSlots += cents
                }

                let unattributed = max(0, it.priceCents - attributedToSlots)
                if unattributed > 0 && !included.isEmpty && !claimMode {
                    // Non-claim byItems: distribute unclaimed cents evenly among
                    // included guests. UI hint in `byItemPanel` calls this out
                    // to the sender so the math feels predictable. Also covers
                    // any items-vs-subtotal OCR-capture gap (so owed.sum stays
                    // anchored on totalCents).
                    let shares = splitCentsEvenly(total: unattributed, count: included.count)
                    for (i, slotIndex) in included.enumerated() {
                        subtotals[slotIndex] += shares[i]
                    }
                }
                // Claim mode: unclaimed stays unattributed — recipients claim
                // it via the in-chat tap-to-claim UI; owed.sum < totalCents
                // until everything's claimed.
            }

            // Non-claim mode anchors extras on totalCents so the subtotal gap
            // is absorbed; claim mode scales overhead to the claimed fraction
            // of the receipt so unclaimed items' tax/tip stays unowed.
            let itemsTotal = subtotals.reduce(0, +)
            let extras: Int
            if claimMode {
                let fullOverhead = max(0, feesCents - discountCents + taxCents + tipCents)
                let fullItemSubtotal = items.reduce(0) { $0 + max(0, $1.priceCents) }
                // Each claimer bears overhead proportional to their claimed
                // items vs. the WHOLE receipt subtotal — not vs. the
                // claimed-so-far total. Allocating fullOverhead over only the
                // claimed subtotal made one claimer's tax/tip depend on how
                // much everyone else had claimed (bug: $40.51 vs $24.70).
                extras = fullItemSubtotal > 0
                    ? min(fullOverhead,
                          Int((Double(fullOverhead) * Double(itemsTotal)
                               / Double(fullItemSubtotal)).rounded()))
                    : 0
            } else {
                extras = max(0, totalCents - itemsTotal)
            }
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

            // Remap draft-internal PersonIDs (random UUIDs for anonymous slots)
            // to wire-canonical (uid or "slot-N"). SplitMath uses the wire form
            // when resolving slot → PersonID, so anonymous-slot claims wouldn't
            // match without this remap. Same fix as in `SplitPayload.from(draft:)`.
            let remap: [PersonID: PersonID] = Dictionary(uniqueKeysWithValues:
                draft.guests.enumerated().map { (idx, p) in
                    let canonical = (p.userId?.isEmpty == false)
                        ? PersonID(rawValue: p.userId!)
                        : PersonID(rawValue: "slot-\(idx)")
                    return (p.id, canonical)
                })
            let items: [(label: String, priceCents: Int, partition: ItemPartition)] = draft.items.map { item in
                (label: item.label,
                 priceCents: item.priceCents,
                 partition: item.partition.remappingPersonIDs(remap))
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
                tipCents: draft.tipCents,
                claimMode: draft.claimMode && mode == .byItems
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
