import Foundation
import Combine
import UIKit
import Messages
import FirebaseFirestore

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
        /// Canonical assignment data — PersonID list. By-items consumers
        /// (SplitsSummaryView, ReceiptPayload.from) read this directly.
        let assigneeIDs: [PersonID]

        init(id: String, label: String, priceCents: Int,
             assigneeIDs: [PersonID] = []) {
            self.id = id
            self.label = label
            self.priceCents = priceCents
            self.assigneeIDs = assigneeIDs
        }

        // Custom Codable: assigneeIDs defaults to [] when missing.
        // Pre-Phase-2.7 SessionPersistence data with `responsible` keys is
        // tolerated — that key is silently dropped during decode.
        private enum CodingKeys: String, CodingKey {
            case id, label, priceCents, assigneeIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.label = try c.decode(String.self, forKey: .label)
            self.priceCents = try c.decode(Int.self, forKey: .priceCents)
            self.assigneeIDs = try c.decodeIfPresent([PersonID].self, forKey: .assigneeIDs) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(priceCents, forKey: .priceCents)
            if !assigneeIDs.isEmpty {
                try c.encode(assigneeIDs, forKey: .assigneeIDs)
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

    // Firestore doc ID of the opened message (needed for updates like slot claims)
    @Published var openedMessageDocId: String? = nil

    // Active iMessage session for the currently opened receipt bubble.
    @Published var activeMessageSession: MSSession? = nil

    // Firestore message loading state
    @Published var messageLoadingState: LoadingState<LootMessagePayload> = .idle

    // Two-phase parsing: items loading state (phase 2 runs in background)
    @Published var itemsLoadingState: LoadingState<Phase2Result> = .idle

    /// Optional pre-tip total override chosen in EditReceiptView.
    /// This is kept separate from ReceiptDisplay fields so we can preserve explicit
    /// "Override total" intent across re-opens of Edit Receipt until the user removes it.
    @Published var preTipTotalOverrideCents: Int? = nil

    // Debug: OCR chunk images from last scan (populated when DEBUG_SHOW_CHUNKS = true)
    @Published var debugChunkImages: [UIImage] = []
    var phase2Task: Task<Void, Never>? = nil

    // True while phase 1 LLM is running (shows BillCardLoadingView on confirmation screen)
    @Published var isLoadingReceipt: Bool = false

    // MARK: - Loot Tabs state

    /// Live tab document for the conversation. A Firestore snapshot listener
    /// (managed below) keeps this in sync with remote changes — when another
    /// participant joins, leaves, edits the tab, or adds a receipt, this
    /// updates automatically without requiring a manual refresh.
    @Published var activeTab: LootTab? = nil {
        didSet { syncActiveTabListener(oldId: oldValue?.id, newId: activeTab?.id) }
    }
    /// Tab that belongs to the currently-opened receipt (may differ from activeTab).
    @Published var receiptTab: LootTab? = nil

    private var activeTabListener: ListenerRegistration? = nil
    /// Tracks which tabId the current listener is bound to so listener-fed
    /// updates (which assign back to `activeTab` and re-trigger didSet) don't
    /// tear down and re-attach the listener for the same id.
    private var activeTabListenerId: String? = nil

    private func syncActiveTabListener(oldId: String?, newId: String?) {
        // Same id (or both nil) means the listener-fed update is what
        // triggered didSet — leave the existing subscription alone.
        guard oldId != newId else { return }

        activeTabListener?.remove()
        activeTabListener = nil
        activeTabListenerId = nil

        guard let newId, !newId.isEmpty else { return }

        activeTabListenerId = newId
        activeTabListener = TabService.shared.listenToTab(tabId: newId) { [weak self] updated in
            // Tab might have been swapped/cleared between the snapshot fire
            // and the main-actor hop; only adopt updates for the still-bound
            // tab id.
            guard let self, self.activeTabListenerId == updated.id else { return }
            self.activeTab = updated
            // Mirror to UserDefaults cache so an extension restart picks up
            // the freshest member set immediately rather than briefly showing
            // stale data while the listener round-trips.
            if let convKey = self.conversationKey {
                TabService.shared.cacheTab(updated, for: convKey)
            }
        }
    }
    @Published var tabReceiptsRefreshNonce: Int = 0
    @Published var userTabs: [LootTab] = []
    @Published var localParticipantId: String? = nil
    @Published var conversationKey: String? = nil
    /// Bill-scoped ignored Keychain UUIDs from inline payload envelope (or local session edits).
    @Published var ignoredUUIDsByBill: [String: [String]] = [:]
    /// Tracks whether a bill had an explicit ignoredUUIDs list in the inline payload envelope.
    @Published var hasIgnoredUUIDsListByBill: [String: Bool] = [:]
    @Published var pendingTabInviteId: String? = nil
    /// Bumped every time `applyMessage` re-handles a tab-invite URL. Lets
    /// JoinTabView's `.task(id:)` re-fire when the user re-taps the SAME
    /// invite bubble (which doesn't change `pendingTabInviteId` and so
    /// otherwise wouldn't trigger a fresh fetch).
    @Published var pendingTabInviteRefreshNonce: Int = 0
    @Published var pendingPayRequest: PendingPayRequest? = nil
    /// Member IDs (Keychain UUIDs) of the tab associated with the current conversation.
    /// Used to sort userTabs by relevance — most overlapping members shown first.
    @Published var conversationMemberIds: Set<String> = []

    /// Opens a URL in Safari app (via extensionContext). Set by MessagesViewController.
    var openInSafari: ((URL) -> Void)?

    /// Sends a styled settlement card into the active iMessage conversation.
    /// Args: (fromName, toName, amountCents, methodName, tabColorHex)
    var sendSettlementCard: ((String, String, Int, String, String?) -> Void)?

    /// Inserts a payment-request card into the iMessage draft box (user presses Send).
    /// Args: (creditorName, debtorName, amountCents, tabColorHex, request metadata)
    var sendRequestCard: ((String, String, Int, String?, RequestCardMetadata?) -> Void)?

    /// Sends an updated live receipt card on the current session so Messages replaces the bubble in place.
    /// Args: (payload, Firestore docId, action that triggered the update)
    var sendBillUpdate: ((LootMessagePayload, String, BillUpdateAction) -> Void)?

    func hasIgnoredUUIDsList(for billId: String?) -> Bool {
        guard let billId else { return false }
        return hasIgnoredUUIDsListByBill[billId] == true
    }

    func ignoredUUIDs(for billId: String?) -> [String] {
        guard let billId else { return [] }
        return ignoredUUIDsByBill[billId] ?? []
    }

    func setInlineIgnoredState(ignoredUUIDs: [String], hasList: Bool, for billId: String?) {
        guard let billId else { return }
        if hasList {
            hasIgnoredUUIDsListByBill[billId] = true
            ignoredUUIDsByBill[billId] = Self.normalizedUUIDs(ignoredUUIDs)
        } else {
            hasIgnoredUUIDsListByBill[billId] = false
            ignoredUUIDsByBill.removeValue(forKey: billId)
        }
    }

    func addIgnoredUUID(_ uuid: String, for billId: String?) {
        guard let billId else { return }
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        hasIgnoredUUIDsListByBill[billId] = true
        var current = ignoredUUIDsByBill[billId] ?? []
        if !current.contains(trimmed) {
            current.append(trimmed)
            ignoredUUIDsByBill[billId] = current
        }
    }

    func removeIgnoredUUID(_ uuid: String, for billId: String?) {
        guard let billId else { return }
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard hasIgnoredUUIDsList(for: billId) else { return }
        guard var current = ignoredUUIDsByBill[billId] else { return }
        current.removeAll { $0 == trimmed }
        ignoredUUIDsByBill[billId] = current
    }

    func isIgnoredUUID(_ uuid: String, for billId: String?) -> Bool {
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ignoredUUIDs(for: billId).contains(trimmed)
    }

    private static func normalizedUUIDs(_ uuids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in uuids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    func resetForNewReceipt() {
        // Cancel any running phase 2 task
        phase2Task?.cancel()
        phase2Task = nil

        // Clear any persisted session for this conversation
        if let key = conversationKey {
            SessionPersistence.clear(conversationKey: key)
        }

        parsedReceipt = nil
        currentReceipt = nil
        scanImageOriginal = nil
        scanImageCropped = nil
        currentSplitDraft = nil
        preTipTotalOverrideCents = nil
        openedMessagePayload = nil
        openedMessageDocId = nil
        ignoredUUIDsByBill = [:]
        hasIgnoredUUIDsListByBill = [:]
        activeMessageSession = nil
        receiptTab = nil
        pendingPayRequest = nil
        messageLoadingState = .idle
        itemsLoadingState = .idle
        isLoadingReceipt = false
        debugChunkImages = []
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
