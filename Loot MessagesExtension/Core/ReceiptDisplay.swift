import Foundation
import UIKit
import Messages

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

struct ReceiptDisplay: Identifiable, Codable, Equatable {

    struct Item: Identifiable, Codable, Equatable {
        let id: String
        let label: String
        let priceCents: Int
        /// Per-item claim partition. Drives by-items math (SplitMath reads
        /// `partition` directly) and the wire format (ReceiptPayload.from
        /// emits sh/cu/rs from it).
        let partition: ItemPartition

        /// Backward-compat read accessor — deduplicated PersonIDs that have
        /// any claim. Sites that rendered avatar lists from the flat
        /// `assigneeIDs` continue to work without modification.
        var assigneeIDs: [PersonID] { partition.claimerPersonIDs }

        init(id: String, label: String, priceCents: Int, partition: ItemPartition = .unclaimed) {
            self.id = id
            self.label = label
            self.priceCents = priceCents
            self.partition = partition
        }

        /// Convenience for legacy call sites. Builds `.shares` with one slot
        /// per assignee (or `.unclaimed` when empty).
        init(id: String, label: String, priceCents: Int, assigneeIDs: [PersonID]) {
            self.init(
                id: id, label: label, priceCents: priceCents,
                partition: .legacyAssignedGuests(assigneeIDs)
            )
        }

        // Custom Codable: prefer the new `partition` field, fall back to
        // the legacy `assigneeIDs` flat list. Pre-Phase-2.7 SessionPersistence
        // data with `responsible` keys is tolerated — that key is silently
        // dropped during decode.
        private enum CodingKeys: String, CodingKey {
            case id, label, priceCents, partition, assigneeIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.label = try c.decode(String.self, forKey: .label)
            self.priceCents = try c.decode(Int.self, forKey: .priceCents)
            if let p = try? c.decode(ItemPartition.self, forKey: .partition) {
                self.partition = p
            } else if let legacy = try? c.decode([PersonID].self, forKey: .assigneeIDs) {
                self.partition = .legacyAssignedGuests(legacy)
            } else {
                self.partition = .unclaimed
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(priceCents, forKey: .priceCents)
            if partition != .unclaimed {
                try c.encode(partition, forKey: .partition)
            }
        }
    }

    /// Individual tax/fee/discount line items for display (e.g. "Tax $2.50", "Discount -$5.00").
    /// Empty when constructed from a payload or scan (only aggregates are available then).
    struct LineItem: Identifiable, Codable, Equatable {
        let id: String   // stable UUID string — order is preserved, labels need not be unique
        let label: String
        let cents: Int   // signed: negative = discount

        init(id: String = UUID().uuidString, label: String, cents: Int) {
            self.id = id
            self.label = label
            self.cents = cents
        }
    }

    let id: String
    let title: String
    let createdAt: Date?

    let subtotalCents: Int
    let feesCents: Int
    let discountCents: Int
    let taxCents: Int
    let tipCents: Int
    let totalCents: Int

    let items: [Item]
    let lineItems: [LineItem]  // individual fee/discount rows for ReceiptView

    var shouldShowOnlyTotal: Bool {
        feesCents == 0 && discountCents == 0 && taxCents == 0 && tipCents == 0
    }

    init(id: String, title: String, createdAt: Date?, subtotalCents: Int, feesCents: Int, discountCents: Int = 0,
         taxCents: Int, tipCents: Int, totalCents: Int, items: [Item], lineItems: [LineItem] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.subtotalCents = subtotalCents; self.feesCents = feesCents
        self.discountCents = discountCents
        self.taxCents = taxCents; self.tipCents = tipCents; self.totalCents = totalCents
        self.items = items; self.lineItems = lineItems
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
    case messageViewer
    case newTab
    case tabInviteConfirmation
    case joinTab
    case account
    case paymentMethods
    case updateRequired
}

enum LootVersion {
    /// Reads major version from MARKETING_VERSION (e.g. "1.3" → 1).
    /// Only change the marketing version in the Xcode project to update this.
    static let major: Int = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return Int(version.split(separator: ".").first ?? "1") ?? 1
    }()
    static let urlParamName = "mv"
}

struct PendingPayRequest: Equatable {
    var requestId: String = UUID().uuidString
    var receiptDocId: String?
    var tabId: String?
    var creditorId: String?
    var debtorId: String?
    var creditorName: String
    var debtorName: String
    var amountCents: Int
}

struct RequestCardMetadata {
    var receiptDocId: String?
    var tabId: String?
    var creditorId: String?
    var debtorId: String?
}

/// Payload for the compact-mode Apple Pay reminder. Set by the Pay Now flow
/// after the sender selects Apple Pay; cleared when the sender dismisses the
/// reminder. iOS 26+ wraps this with "tap the Apple Cash drawer below"; older
/// iOS gets the "open a 1:1 chat" copy.
struct PendingApplePayInfo: Equatable {
    var toName: String
    var amountCents: Int
    var tabColorHex: String?
}

/// Identifies the kind of action that triggered a bill bubble update so the
/// iMessage transcript notice ("X <verb>...") can be tailored. iOS prepends
/// the sender's contact name automatically; the summaryText is just the
/// suffix verb phrase.
enum BillUpdateAction {
    case claimed
    case optedOut
    case paidToggled(paid: Bool)
    case edited
    case removedFromTab(tabName: String?)

    var summaryText: String {
        switch self {
        case .claimed: return "joined a bill"
        case .optedOut: return "left a bill"
        case .paidToggled(let paid): return paid ? "marked a payment paid" : "marked a payment unpaid"
        case .edited: return "updated a bill"
        case .removedFromTab(let tabName):
            if let tabName, !tabName.isEmpty {
                return "removed a bill from \(tabName)"
            }
            return "removed a bill from a tab"
        }
    }

    /// True when the bill-update transport must NOT short-circuit on an
    /// unchanged SplitPayload signature. Tab-association changes leave the
    /// split untouched but still need to re-broadcast the bubble (so the
    /// recipient's bubble sheds its tab badge / picks up the new metadata).
    var bypassesSplitSignatureDedup: Bool {
        switch self {
        case .removedFromTab: return true
        default: return false
        }
    }
}

// Phase 3 step 15 (final): `LootUIModel` is gone. Its state has been
// fully decomposed:
//   - In-flight bill state → ReceiptDraftViewModel (step 12)
//   - Opened-bubble state → MessageReceiptViewModel (step 13a)
//   - UIKit-bridge closures → MessageBus protocol (step 13b)
//   - Tab/conversation state → TabContextViewModel (step 14)
//   - currentScreen + isExpanded → AppCoordinator (step 15)
//
// `ReceiptDisplay.swift` now only contains the UI-shaped value types
// (`ReceiptDisplay`, `LineItem`, etc.), `AppScreen`, `LoadingState`,
// `BillUpdateAction`, `PendingPayRequest`, `PendingApplePayInfo`,
// `RequestCardMetadata`, and `LootVersion`. The god `ObservableObject`
// is no more.


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
                priceCents: itemCents(it)
            )
        }
        .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Best-effort breakdown with defaults.
    func breakdownDefaults() -> (fees: Int, discount: Int, tax: Int, tip: Int) {
        (
            fees: fees_cents ?? 0,
            discount: max(0, discount_cents ?? 0),
            tax: max(0, tax_cents ?? 0),
            tip: max(0, tip_cents ?? 0)
        )
    }

    /// Best-effort receipt title for UI.
    func displayTitle(fallback: String = "New Receipt") -> String {
        let t = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    /// Best-effort total for UI (prefers total, else subtotal+tax+fees-discount+tip if present).
    func bestTotalCents() -> Int {
        if let t = total_cents { return max(0, t) }

        // If total missing, try compute from whatever exists (conservative).
        let sub = subtotal_cents
        if sub == nil { return 0 }

        let fees = fees_cents ?? 0
        let discount = discount_cents ?? 0
        let tax = tax_cents ?? 0
        let tip = tip_cents ?? 0
        return max(0, (sub ?? 0) + max(0, tax) + fees - max(0, discount) + max(0, tip))
    }
}
