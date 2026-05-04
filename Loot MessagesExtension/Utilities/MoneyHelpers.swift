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

            let extras = feesCents - max(0, discountCents) + max(0, taxCents) + max(0, tipCents)
            let extrasAlloc = allocateProportional(total: extras, base: subtotals, included: included)

            for idx in included {
                owed[idx] = max(0, subtotals[idx] + extrasAlloc[idx])
            }

            return owed
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
