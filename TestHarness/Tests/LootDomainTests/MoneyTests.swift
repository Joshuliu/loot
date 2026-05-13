import XCTest
@testable import LootDomain

final class MoneyTests: XCTestCase {

    // MARK: - displayString (with $)

    func testDisplayStringZero() {
        XCTAssertEqual(Money(cents: 0).displayString, "$0.00")
    }

    func testDisplayStringWholeDollars() {
        XCTAssertEqual(Money(cents: 1200).displayString, "$12.00")
    }

    func testDisplayStringWithCents() {
        XCTAssertEqual(Money(cents: 1234).displayString, "$12.34")
    }

    func testDisplayStringSingleDigitCents() {
        XCTAssertEqual(Money(cents: 1205).displayString, "$12.05")
    }

    func testDisplayStringNegative() {
        XCTAssertEqual(Money(cents: -500).displayString, "-$5.00")
    }

    func testDisplayStringNegativeWithCents() {
        XCTAssertEqual(Money(cents: -1234).displayString, "-$12.34")
    }

    func testDisplayStringLargeAmount() {
        XCTAssertEqual(Money(cents: 1234567).displayString, "$12345.67")
    }

    // MARK: - inputString (no $)

    func testInputStringZero() {
        XCTAssertEqual(Money(cents: 0).inputString, "0.00")
    }

    func testInputStringWithCents() {
        XCTAssertEqual(Money(cents: 1234).inputString, "12.34")
    }

    func testInputStringSingleDigitCents() {
        XCTAssertEqual(Money(cents: 1205).inputString, "12.05")
    }

    func testInputStringNegative() {
        XCTAssertEqual(Money(cents: -500).inputString, "-5.00")
    }

    // MARK: - parsing (unsigned)

    func testParseEmpty() {
        XCTAssertEqual(Money(parsing: "").cents, 0)
    }

    func testParseWhitespace() {
        XCTAssertEqual(Money(parsing: "   ").cents, 0)
    }

    func testParseDollarsOnly() {
        XCTAssertEqual(Money(parsing: "12").cents, 1200)
    }

    func testParseDollarsAndCents() {
        XCTAssertEqual(Money(parsing: "12.50").cents, 1250)
    }

    func testParseWithDollarSign() {
        XCTAssertEqual(Money(parsing: "$12.50").cents, 1250)
    }

    func testParseWithComma() {
        XCTAssertEqual(Money(parsing: "1,234.56").cents, 123456)
    }

    func testParseWithDollarSignAndComma() {
        XCTAssertEqual(Money(parsing: "$1,234.56").cents, 123456)
    }

    func testParseWithLeadingTrailingWhitespace() {
        XCTAssertEqual(Money(parsing: "  $12.50  ").cents, 1250)
    }

    func testParseSingleDigitCent() {
        // "12.5" → 12 dollars 50 cents (padded to 50)
        XCTAssertEqual(Money(parsing: "12.5").cents, 1250)
    }

    func testParseTrailingDot() {
        // "12." → 12 dollars 0 cents
        XCTAssertEqual(Money(parsing: "12.").cents, 1200)
    }

    func testParseExtraDecimalsTruncated() {
        // "12.567" → first two cent-digits used: 1256
        XCTAssertEqual(Money(parsing: "12.567").cents, 1256)
    }

    func testParseUnsignedClampsNegative() {
        // Negative input clamped to 0 in unsigned parser
        XCTAssertEqual(Money(parsing: "-5.00").cents, 0)
    }

    // MARK: - parsing (signed)

    func testParseSignedZero() {
        XCTAssertEqual(Money(parsingSigned: "").cents, 0)
        XCTAssertEqual(Money(parsingSigned: "0").cents, 0)
        XCTAssertEqual(Money(parsingSigned: "-0").cents, 0)
    }

    func testParseSignedNegative() {
        XCTAssertEqual(Money(parsingSigned: "-5.00").cents, -500)
    }

    func testParseSignedNegativeWithDollarSign() {
        XCTAssertEqual(Money(parsingSigned: "-$5.00").cents, -500)
    }

    func testParseSignedPositive() {
        XCTAssertEqual(Money(parsingSigned: "5.00").cents, 500)
    }

    func testParseSignedNegativeWithCents() {
        XCTAssertEqual(Money(parsingSigned: "-12.34").cents, -1234)
    }

    // MARK: - round-trip

    func testRoundTripDisplayUnchanged() {
        for cents in [0, 1, 99, 100, 1000, 1234567] {
            let m = Money(cents: cents)
            // displayString includes $; parsing strips it; round-trip preserves cents
            XCTAssertEqual(Money(parsing: m.displayString).cents, cents, "failed for cents=\(cents)")
        }
    }

    func testRoundTripInputSigned() {
        for cents in [-500, -1, 0, 1, 1234567] {
            let m = Money(cents: cents)
            XCTAssertEqual(Money(parsingSigned: m.inputString).cents, cents, "failed for cents=\(cents)")
        }
    }

    // MARK: - arithmetic

    func testAddition() {
        XCTAssertEqual((Money(cents: 1000) + Money(cents: 250)).cents, 1250)
    }

    func testSubtraction() {
        XCTAssertEqual((Money(cents: 1000) - Money(cents: 250)).cents, 750)
    }

    func testNegation() {
        XCTAssertEqual((-Money(cents: 1000)).cents, -1000)
        XCTAssertEqual((-Money(cents: -1000)).cents, 1000)
    }

    func testZeroConstant() {
        XCTAssertEqual(Money.zero.cents, 0)
    }

    // MARK: - Codable (encodes as JSON Int)

    func testCodableEncodesAsInt() throws {
        let m = Money(cents: 1234)
        let data = try JSONEncoder().encode(m)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "1234")
    }

    func testCodableDecodesFromInt() throws {
        let data = "1234".data(using: .utf8)!
        let m = try JSONDecoder().decode(Money.self, from: data)
        XCTAssertEqual(m.cents, 1234)
    }

    func testCodableRoundTrip() throws {
        let original = Money(cents: -567)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Money.self, from: data)
        XCTAssertEqual(decoded.cents, original.cents)
    }

    // MARK: - hashable / equatable

    func testEquality() {
        XCTAssertEqual(Money(cents: 100), Money(cents: 100))
        XCTAssertNotEqual(Money(cents: 100), Money(cents: 101))
    }

    func testHashable() {
        let set: Set<Money> = [Money(cents: 100), Money(cents: 100), Money(cents: 200)]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - cross-check parity with old free-function semantics

    func testParityWithOldStringToCents() {
        // The old `stringToCents` clamped negatives to 0 and accepted "$"/","/whitespace
        for input in ["", "12", "12.50", "$12.50", "1,234.56", "  $42.00  ", "-5.00", "12.567"] {
            let viaMoney = Money(parsing: input).cents
            // Reproduce the original logic to confirm parity
            let expected: Int = {
                let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
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
            }()
            XCTAssertEqual(viaMoney, expected, "parity broken for input=\(input)")
        }
    }
}
