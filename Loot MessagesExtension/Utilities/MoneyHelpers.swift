//
//  MoneyHelpers.swift
//  Loot MessagesExtension
//
//  Shared currency utilities used across the extension.
//

import Foundation

/// Parses a user-entered currency string (e.g. "$12.50", "12.50", "12") into integer cents.
func stringToCents(_ raw: String) -> Int {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "$", with: "")
        .replacingOccurrences(of: ",", with: "")
    guard !s.isEmpty else { return 0 }
    if s.contains(".") {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let dollars = Int(parts.first ?? "0") ?? 0
        let centsRaw = parts.count > 1 ? String(parts[1]) : ""
        let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
        let cents = Int(String(cents2.prefix(2))) ?? 0
        return max(0, dollars * 100 + cents)
    }
    return max(0, (Int(s) ?? 0) * 100)
}

/// Formats cents as a plain decimal string for text field display (e.g. 1250 → "12.50", no $ sign).
/// Preserves sign for negative values (e.g. -500 → "-5.00").
func centsToDecimalString(_ cents: Int) -> String {
    let dollars = abs(cents) / 100
    let rem = abs(cents) % 100
    let sign = cents < 0 ? "-" : ""
    return "\(sign)\(dollars).\(String(format: "%02d", rem))"
}

/// Parses a signed currency string (e.g. "-5.00", "12.50") into integer cents.
/// Unlike stringToCents, this preserves negative values (used for fee/discount fields).
func signedStringToCents(_ raw: String) -> Int {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "$", with: "")
        .replacingOccurrences(of: ",", with: "")
    guard !s.isEmpty else { return 0 }
    let isNegative = s.hasPrefix("-")
    let abs = isNegative ? String(s.dropFirst()) : s
    let value: Int
    if abs.contains(".") {
        let parts = abs.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let dollars = Int(parts.first ?? "0") ?? 0
        let centsRaw = parts.count > 1 ? String(parts[1]) : ""
        let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
        let cents = Int(String(cents2.prefix(2))) ?? 0
        value = dollars * 100 + cents
    } else {
        value = (Int(abs) ?? 0) * 100
    }
    return isNegative ? -value : value
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
            let shares = splitEvenly(total: totalCents, count: included.count)
            for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            return owed

        case .custom:
            if let perGuestActive, perGuestActive.count == included.count {
                for (i, idx) in included.enumerated() { owed[idx] = max(0, perGuestActive[i]) }
            } else {
                let shares = splitEvenly(total: totalCents, count: included.count)
                for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            }
            return owed

        case .byItems:
            var subtotals = Array(repeating: 0, count: guests.count)

            for it in items {
                let assigned = it.assignedSlots.filter { guests.indices.contains($0) && guests[$0].inc }
                let targets = assigned.isEmpty ? [safePayer] : assigned.sorted()
                let parts = splitEvenly(total: max(0, it.priceCents), count: targets.count)
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

    private static func splitEvenly(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) { out[i] += 1 }
        }
        return out
    }

    private static func allocateProportional(total: Int, base: [Int], included: [Int]) -> [Int] {
        var out = Array(repeating: 0, count: base.count)
        guard total != 0 else { return out }

        let sumBase = included.reduce(0) { $0 + max(0, base[$1]) }
        if sumBase <= 0 {
            let shares = splitEvenly(total: total, count: included.count)
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
