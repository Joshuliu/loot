//
//  SettlementOutbox.swift
//  Loot
//
//  Durable queue for settlement writes. iMessage extensions are torn
//  down aggressively and Firestore writes can fail transiently — both
//  failure modes previously dropped the settlement silently AFTER the
//  user had already been handed off to Venmo/PayPal/etc., leaving the
//  tab ledger missing a payment that really happened.
//
//  Usage: call `submit(...)` instead of TabService.recordSettlement
//  directly. The entry is persisted to UserDefaults BEFORE the write
//  is attempted and removed only after Firestore confirms. `flush()`
//  runs on extension launch (didBecomeActive) and retries anything
//  left behind by a kill or a failed write.
//
//  Duplicate-protection: each entry carries a UUID; flush() re-checks
//  the queue before each write and removes the entry first on success.
//  A crash BETWEEN Firestore-confirm and remove() can, at worst,
//  replay one settlement on next launch — acceptable versus silently
//  losing one (and visible/undoable in tab history, vs. invisible).
//

import Foundation

enum SettlementOutbox {
    private static let key = "loot.settlementOutbox.v1"

    struct Entry: Codable, Identifiable, Equatable {
        let id: String          // UUID — outbox identity, not Firestore docId
        let tabId: String
        let createdBy: String
        let fromMemberId: String
        let toMemberId: String
        let amountCents: Int
        let note: String?
    }

    /// Enqueues, attempts the Firestore write, and dequeues on success.
    /// On failure the entry stays queued for the next `flush()`.
    /// Returns true when the write confirmed in this call.
    @discardableResult
    static func submit(
        tabId: String,
        createdBy: String,
        fromMemberId: String,
        toMemberId: String,
        amountCents: Int,
        note: String?
    ) async -> Bool {
        let entry = Entry(
            id: UUID().uuidString,
            tabId: tabId,
            createdBy: createdBy,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            amountCents: amountCents,
            note: note
        )
        append(entry)
        return await attempt(entry)
    }

    /// Retries every queued entry. Call on extension launch — safe to
    /// call repeatedly; entries are removed as they confirm.
    static func flush() async {
        let pending = all()
        guard !pending.isEmpty else { return }
        print("[SettlementOutbox] flushing \(pending.count) pending settlement(s)")
        for entry in pending {
            _ = await attempt(entry)
        }
    }

    // MARK: - Internals

    private static func attempt(_ entry: Entry) async -> Bool {
        // Entry may have been confirmed by a concurrent flush — skip.
        guard all().contains(entry) else { return true }
        let settlement = Settlement(
            createdBy: entry.createdBy,
            fromMemberId: entry.fromMemberId,
            toMemberId: entry.toMemberId,
            amountCents: entry.amountCents,
            note: entry.note
        )
        do {
            try await TabService.shared.recordSettlement(settlement, forTab: entry.tabId)
            remove(entry.id)
            return true
        } catch {
            print("[SettlementOutbox] write failed (kept queued): \(error)")
            return false
        }
    }

    private static func all() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func append(_ entry: Entry) {
        var entries = all()
        entries.append(entry)
        save(entries)
    }

    private static func remove(_ id: String) {
        var entries = all()
        entries.removeAll { $0.id == id }
        save(entries)
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
