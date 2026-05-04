//
//  Money.swift
//  Loot MessagesExtension
//
//  Canonical money value type. Replaces scattered ad-hoc cent <-> string conversions.
//  Phase 1 of the architectural refactor: free functions in MoneyHelpers.swift now
//  delegate here. New call sites should use Money directly.
//

import Foundation

struct Money: Hashable, Codable {
    let cents: Int

    static let zero = Money(cents: 0)

    init(cents: Int) {
        self.cents = cents
    }

    /// Parse an unsigned currency string (e.g. "$12.50", "12.50", "12") into integer cents.
    /// Negative inputs are clamped to 0. For signed parsing, use `Money(parsingSigned:)`.
    init(parsing raw: String) {
        self.cents = Self.parseUnsigned(raw)
    }

    /// Parse a signed currency string (e.g. "-5.00", "12.50") into integer cents.
    init(parsingSigned raw: String) {
        self.cents = Self.parseSigned(raw)
    }

    /// Display string with $ and sign: "$12.50", "-$5.00".
    var displayString: String {
        let absCents = abs(cents)
        let dollars = absCents / 100
        let rem = absCents % 100
        let sign = cents < 0 ? "-" : ""
        return "\(sign)$\(dollars).\(String(format: "%02d", rem))"
    }

    /// Plain decimal string for text fields: "12.50", "-5.00" (no $).
    var inputString: String {
        let dollars = abs(cents) / 100
        let rem = abs(cents) % 100
        let sign = cents < 0 ? "-" : ""
        return "\(sign)\(dollars).\(String(format: "%02d", rem))"
    }

    static func + (l: Money, r: Money) -> Money { Money(cents: l.cents + r.cents) }
    static func - (l: Money, r: Money) -> Money { Money(cents: l.cents - r.cents) }
    static prefix func - (m: Money) -> Money { Money(cents: -m.cents) }

    init(from decoder: Decoder) throws {
        self.cents = try decoder.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(cents)
    }

    private static func parseUnsigned(_ raw: String) -> Int {
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

    private static func parseSigned(_ raw: String) -> Int {
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
}
