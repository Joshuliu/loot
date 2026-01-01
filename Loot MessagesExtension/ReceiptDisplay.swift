import Foundation
import Combine

// MARK: - Receipt display model (for ReceiptView preview)

struct ReceiptDisplay: Identifiable {
    
    struct Responsible: Hashable {
        let slotIndex: Int
        let displayName: String
        var badgeText: String {
            let t = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.first.map { String($0).uppercased() } ?? String(slotIndex + 1)
        }
    }
    
    struct Item: Identifiable {
        let id: String
        let label: String
        let priceCents: Int
        let responsible: [Responsible]
    }

    let id: String
    let title: String
    let createdAt: Date?

    let subtotalCents: Int
    let feesCents: Int
    let taxCents: Int
    let tipCents: Int
    let discountCents: Int
    let totalCents: Int

    let items: [Item]

    var shouldShowOnlyTotal: Bool {
        feesCents == 0 && taxCents == 0 && tipCents == 0 && discountCents == 0
    }

    var dateText: String {
        guard let createdAt else { return "—" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: createdAt)
    }

    static func money(_ cents: Int) -> String {
        let absCents = abs(cents)
        let dollars = absCents / 100
        let rem = absCents % 100
        let sign = cents < 0 ? "-" : ""
        return "\(sign)$\(dollars).\(String(format: "%02d", rem))"
    }
}

// MARK: - UI state (MVP: in-memory only)

@MainActor
final class LootUIModel: ObservableObject {
    @Published var isExpanded: Bool = false

    // Preview-only receipt (ReceiptView)
    @Published var currentReceipt: ReceiptDisplay? = nil

    // Scan output (Fill -> Confirmation prefill + issues)
    @Published var parsedReceipt: ParsedReceipt? = nil

    func resetForNewReceipt() {
        parsedReceipt = nil
        currentReceipt = nil
    }
}

// MARK: - Scan parse result (LLM output)

struct ParsedReceipt: Codable, Equatable {
    struct Item: Codable, Equatable {
        let label: String
        let quantity: Int
        let unit_price_cents: Int?
        let line_total_cents: Int?
        let confidence: Double
    }

    struct Verification: Codable, Equatable {
        let items_sum_cents: Int?
        let computed_total_cents: Int?
        let delta_total_cents: Int?
        let passed: Bool
    }

    let merchant: String?
    let created_at_iso: String?
    let currency: String?

    let items: [Item]

    let subtotal_cents: Int?
    let tax_cents: Int?
    let fees_cents: Int?
    let tip_cents: Int?
    let discount_cents: Int?
    let total_cents: Int?

    let verification: Verification
    let issues: [String]
}

extension ParsedReceipt {
    /// Best cents guess for an item: prefer line_total, else quantity * unit, else 0.
    fileprivate func itemCents(_ item: Item) -> Int {
        if let lt = item.line_total_cents { return max(0, lt) }
        if let unit = item.unit_price_cents { return max(0, unit) * max(1, item.quantity) }
        return 0
    }

    /// MVP helper: create simple display items for preview UI (no assignments).
    func toDisplayItems() -> [ReceiptDisplay.Item] {
        items.map { it in
            ReceiptDisplay.Item(
                id: UUID().uuidString,
                label: it.label,
                priceCents: itemCents(it),
                responsible: []
            )
        }
        .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Best-effort breakdown with defaults.
    func breakdownDefaults() -> (fees: Int, tax: Int, tip: Int, discount: Int) {
        (
            fees: max(0, fees_cents ?? 0),
            tax: max(0, tax_cents ?? 0),
            tip: max(0, tip_cents ?? 0),
            discount: max(0, discount_cents ?? 0)
        )
    }
}
