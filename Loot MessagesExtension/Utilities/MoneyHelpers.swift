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
func centsToDecimalString(_ cents: Int) -> String {
    let dollars = abs(cents) / 100
    let rem = abs(cents) % 100
    return "\(dollars).\(String(format: "%02d", rem))"
}
