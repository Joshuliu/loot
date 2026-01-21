import Foundation
import Combine
import UIKit

// MARK: - Loading State for async operations

enum LoadingState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(Error)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var value: T? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var error: Error? {
        if case .failed(let e) = self { return e }
        return nil
    }
}

// MARK: - Receipt display model (for ReceiptView preview)

struct ReceiptDisplay: Identifiable {

    struct Responsible: Hashable {
        let slotIndex: Int
        let displayName: String
        
        var badgeText: String {
            BadgeColors.initials(from: displayName, fallback: slotIndex)
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

enum AppScreen {
    case tabview
    case fill
    case tipview
    case confirmation
    case receipt
    case messageViewer
}

@MainActor
final class LootUIModel: ObservableObject {
    @Published var isExpanded: Bool = false

    // Screen state - persists across view recreations
    @Published var currentScreen: AppScreen = .tabview

    @Published var currentReceipt: ReceiptDisplay? = nil
    @Published var parsedReceipt: ParsedReceipt? = nil

    @Published var scanImageOriginal: UIImage? = nil
    @Published var scanImageCropped: UIImage? = nil

    // NEW: last split draft while creating (used by sender to encode into message)
    @Published var currentSplitDraft: SplitDraft? = nil

    // NEW: decoded message payload when user taps a Loot message
    @Published var openedMessagePayload: LootMessagePayload? = nil

    // Two-phase parsing: items loading state (phase 2 runs in background)
    @Published var itemsLoadingState: LoadingState<Phase2Result> = .idle
    var phase2Task: Task<Void, Never>? = nil

    func resetForNewReceipt() {
        // Cancel any running phase 2 task
        phase2Task?.cancel()
        phase2Task = nil

        parsedReceipt = nil
        currentReceipt = nil
        scanImageOriginal = nil
        scanImageCropped = nil
        currentSplitDraft = nil
        openedMessagePayload = nil
        itemsLoadingState = .idle
    }
}


// MARK: - Scan parse result (LLM output) — SIMPLIFIED + CONSISTENT

/// Matches the simplified schema:
/// required: merchant, total_cents, items, issues
/// optional: breakdown fields
struct ParsedReceipt: Codable, Equatable {

    struct Item: Codable, Equatable {
        let label: String
        let qty: Int
        let cents: Int?   // line total cents (null if not readable)
    }

    let merchant: String?
    let total_cents: Int?

    let subtotal_cents: Int?
    let tax_cents: Int?
    let tip_cents: Int?
    let fees_cents: Int?
    let discount_cents: Int?

    let items: [Item]
    let issues: [String]
}

extension ParsedReceipt {

    /// Best cents guess for an item: prefer explicit cents, else 0.
    fileprivate func itemCents(_ item: Item) -> Int {
        max(0, item.cents ?? 0)
    }

    /// MVP helper: create simple display items for preview UI (no assignments).
    func toDisplayItems() -> [ReceiptDisplay.Item] {
        items.map { it in
            // If qty > 1 and the label doesn't already include it, we annotate (keeps UI simple).
            let cleanLabel = it.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let labelWithQty: String = {
                guard it.qty > 1 else { return cleanLabel }
                // avoid doubling if receipt already encodes qty in label
                if cleanLabel.lowercased().contains("x\(it.qty)") { return cleanLabel }
                return "\(cleanLabel) ×\(it.qty)"
            }()

            return ReceiptDisplay.Item(
                id: UUID().uuidString,
                label: labelWithQty,
                priceCents: itemCents(it),
                responsible: []
            )
        }
        .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Best-effort breakdown with defaults (never negative in UI).
    func breakdownDefaults() -> (fees: Int, tax: Int, tip: Int, discount: Int) {
        (
            fees: max(0, fees_cents ?? 0),
            tax: max(0, tax_cents ?? 0),
            tip: max(0, tip_cents ?? 0),
            discount: max(0, discount_cents ?? 0)
        )
    }

    /// Best-effort receipt title for UI.
    func displayTitle(fallback: String = "New Receipt") -> String {
        let t = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    /// Best-effort total for UI (prefers total, else subtotal+tax+fees+tip-discount if present).
    func bestTotalCents() -> Int {
        if let t = total_cents { return max(0, t) }

        // If total missing, try compute from whatever exists (conservative).
        let sub = subtotal_cents
        if sub == nil { return 0 }

        let fees = fees_cents ?? 0
        let tax = tax_cents ?? 0
        let tip = tip_cents ?? 0
        let disc = discount_cents ?? 0
        return max(0, (sub ?? 0) + max(0, tax) + max(0, fees) + max(0, tip) - max(0, disc))
    }
}
