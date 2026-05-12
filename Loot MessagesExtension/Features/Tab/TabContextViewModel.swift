//
//  TabContextViewModel.swift
//  Loot MessagesExtension
//
//  Phase 3 step 14: takes ownership of conversation/tab state off
//  LootUIModel. Holds the active tab, the receipt-attached tab, the user's
//  tab list, conversation identity, pending-invite state, and the live
//  Firestore listener that keeps `activeTab` in sync with remote changes.
//
//  Why a dedicated VM: the tab state was a tightly-coupled cluster of
//  ~9 fields plus a Firestore listener with re-entrancy guards. Bundling
//  it on the god `LootUIModel` meant any view that observed `LootUIModel`
//  re-rendered on every tab change — even views that didn't care.
//  Splitting it lets feature views subscribe selectively.
//
//  The activeTab `didSet` (with the rich-vs-stub revert guard) and the
//  listener swap logic are preserved verbatim from LootUIModel — the
//  rules around stub overwrites and listener identity are load-bearing
//  for tab-membership UX.
//

import Combine
import FirebaseFirestore
import Foundation

@MainActor
final class TabContextViewModel: ObservableObject {

    /// Live tab document for the conversation. A Firestore snapshot listener
    /// (managed below) keeps this in sync with remote changes — when another
    /// participant joins, leaves, edits the tab, or adds a receipt, this
    /// updates automatically without requiring a manual refresh.
    @Published var activeTab: LootTab? = nil {
        willSet {
            // Defensive guard: reject same-tab stub overwrites at the property
            // setter level so every call site (including direct assignments
            // that bypass `setActiveTabIfChanged`) is protected. Only triggers
            // for SAME id with rich -> empty members downgrade. Different id
            // (real tab switch) and full updates pass through unchanged.
            if let current = activeTab,
               let next = newValue,
               current.id == next.id,
               !current.members.isEmpty,
               next.members.isEmpty {
                // Cannot mutate `newValue` from willSet, so we log here and
                // override in didSet by reverting to the previous value.
                print("[ActiveTab] REJECT-STUB: would have overwritten \(current.members.count) members with empty stub for tab \(current.id ?? "nil")")
                Thread.callStackSymbols.prefix(12).forEach { print("[ActiveTab]   \($0)") }
            }
        }
        didSet {
            // Revert if willSet flagged a stub overwrite. didSet already saw
            // the new value land; we restore from oldValue, which itself
            // triggers another didSet (now from empty -> full) that we DON'T
            // want to revert. Use a guard so we only revert once.
            if let old = oldValue,
               let new = activeTab,
               old.id == new.id,
               !old.members.isEmpty,
               new.members.isEmpty,
               !isRevertingActiveTabStub {
                isRevertingActiveTabStub = true
                activeTab = old
                isRevertingActiveTabStub = false
                return
            }

            let oldDesc = oldValue.map { "id=\($0.id ?? "nil") membersCount=\($0.members.count) memberIdsCount=\($0.memberIds.count)" } ?? "nil"
            let newDesc = activeTab.map { "id=\($0.id ?? "nil") membersCount=\($0.members.count) memberIdsCount=\($0.memberIds.count)" } ?? "nil"
            print("[ActiveTab] didSet: \(oldDesc) -> \(newDesc)")
            if let oldTab = oldValue,
               let newTab = activeTab,
               oldTab.id == newTab.id,
               !oldTab.members.isEmpty,
               newTab.members.isEmpty {
                print("[ActiveTab] WARN: members vanished for same tab id — call stack:")
                Thread.callStackSymbols.prefix(12).forEach { print("[ActiveTab]   \($0)") }
            }
            syncActiveTabListener(oldId: oldValue?.id, newId: activeTab?.id)
        }
    }

    /// Re-entrancy guard so the didSet revert doesn't recurse into itself.
    private var isRevertingActiveTabStub: Bool = false

    /// Tab that belongs to the currently-opened receipt (may differ from activeTab).
    @Published var receiptTab: LootTab? = nil

    /// Bumped on tab-doc snapshot changes so LootTabView and TabSettleUpCard
    /// reload their payments/settlements lists without manual invalidation.
    @Published var tabReceiptsRefreshNonce: Int = 0

    /// All tabs the local user is a member of. Refreshed on extension launch
    /// and after join/leave/create operations.
    @Published var userTabs: [LootTab] = []

    /// Local participant UUID (from MSConversation.localParticipantIdentifier).
    /// Cached for sorting userTabs by overlap with the current chat.
    @Published var localParticipantId: String? = nil

    /// SHA256 hash of the sorted participant UUIDs for the current chat.
    /// Used as the key for `conversationTabs/{key}` mapping in Firestore.
    @Published var conversationKey: String? = nil

    /// Tab id from a `?tabInvite=...` URL waiting for `JoinTabView` to consume.
    @Published var pendingTabInviteId: String? = nil

    /// Bumped every time `applyMessage` re-handles a tab-invite URL. Lets
    /// JoinTabView's `.task(id:)` re-fire when the user re-taps the SAME
    /// invite bubble (which doesn't change `pendingTabInviteId` and so
    /// otherwise wouldn't trigger a fresh fetch).
    @Published var pendingTabInviteRefreshNonce: Int = 0

    /// Member IDs (Keychain UUIDs) of the tab associated with the current conversation.
    /// Used to sort userTabs by relevance — most overlapping members shown first.
    @Published var conversationMemberIds: Set<String> = []

    // MARK: - Live tab listener

    private var activeTabListener: ListenerRegistration? = nil

    /// Tracks which tabId the current listener is bound to so listener-fed
    /// updates (which assign back to `activeTab` and re-trigger didSet) don't
    /// tear down and re-attach the listener for the same id.
    private var activeTabListenerId: String? = nil

    // MARK: - Reset

    /// Clears the receipt-tab association and the persisted session for the
    /// current conversation. Called from the same sites that invoke
    /// `ReceiptDraftViewModel.reset()` and `MessageReceiptViewModel.reset()`
    /// when starting a fresh receipt flow. `activeTab`, `userTabs`, and the
    /// other top-level fields are NOT cleared — they reflect chat-level
    /// state that survives across receipts.
    func resetForNewReceipt() {
        if let key = conversationKey {
            SessionPersistence.clear(conversationKey: key)
        }
        receiptTab = nil
    }

    // MARK: - Local Cache (Phase 5 step 20)

    /// Returns the cached LootTab for a conversation key from local storage
    /// (instant, no network). Used by `MessagesViewController` on extension
    /// launch to seed `activeTab` before the Firestore listener has had time
    /// to fire.
    func cachedTab(for conversationKey: String) -> LootTab? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.cacheKey(for: conversationKey)),
              let name = dict["name"] as? String,
              let createdBy = dict["createdBy"] as? String,
              let statusRaw = dict["status"] as? String,
              let status = TabStatus(rawValue: statusRaw),
              let memberIds = dict["memberIds"] as? [String],
              let receiptCount = dict["receiptCount"] as? Int,
              let membersArray = dict["members"] as? [[String: Any]]
        else { return nil }

        let members = membersArray.compactMap { m -> TabMember? in
            guard let memberId = m["memberId"] as? String,
                  let displayName = m["displayName"] as? String,
                  let balanceCents = m["balanceCents"] as? Int,
                  let isActive = m["isActive"] as? Bool
            else { return nil }
            return TabMember(
                memberId: memberId,
                userId: m["userId"] as? String,
                displayName: displayName,
                balanceCents: balanceCents,
                isActive: isActive
            )
        }

        var tab = LootTab(
            name: name,
            colorHex: dict["colorHex"] as? String,
            createdBy: createdBy,
            status: status,
            members: members,
            memberIds: memberIds,
            receiptCount: receiptCount
        )
        tab.id = dict["id"] as? String
        return tab
    }

    /// Persists the active tab for a conversation key to local storage. Pass
    /// nil to clear. Mirrored from the Firestore listener so an extension
    /// restart picks up the freshest member set immediately rather than
    /// briefly showing stale data while the listener round-trips.
    func cacheTab(_ tab: LootTab?, for conversationKey: String) {
        let key = Self.cacheKey(for: conversationKey)
        guard let tab else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let dict: [String: Any] = [
            "id": tab.id ?? "",
            "name": tab.name,
            "colorHex": tab.colorHex ?? "",
            "createdBy": tab.createdBy,
            "status": tab.status.rawValue,
            "memberIds": tab.memberIds,
            "receiptCount": tab.receiptCount,
            "members": tab.members.map { m -> [String: Any] in
                [
                    "memberId": m.memberId,
                    "userId": m.userId ?? "",
                    "displayName": m.displayName,
                    "balanceCents": m.balanceCents,
                    "isActive": m.isActive
                ]
            }
        ]
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func cacheKey(for conversationKey: String) -> String {
        "\(DefaultsKeys.conversationTabMap)_\(conversationKey)"
    }

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
            // The tab doc is rewritten on every receipt-add, receipt-edit, and
            // settlement (see syncTabDerivedState + recordSettlement). Bumping
            // the nonce here makes LootTabView and TabSettleUpCard reload their
            // payments/settlements lists when a remote participant adds one,
            // matching how the members list already updates from `activeTab`.
            self.tabReceiptsRefreshNonce &+= 1
            // Mirror to UserDefaults cache so an extension restart picks up
            // the freshest member set immediately rather than briefly showing
            // stale data while the listener round-trips.
            if let convKey = self.conversationKey {
                self.cacheTab(updated, for: convKey)
            }
        }
    }
}
