//
//  LootMessagePayload.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import Foundation

// MARK: - Payload carried inside MSMessage.url
// ✅ OPTIMIZED: Shorter field names to reduce URL size

struct LootMessagePayload: Codable, Equatable {
    var v: Int = 1
    var r: ReceiptPayload  // shortened from "receipt"
    var s: SplitPayload    // shortened from "split"
    var tid: String?       // tabId (links message to a tab)
    var trid: String?      // tabReceiptId (links to receipt within tab)
    var tab: TabPayload?   // inline tab info for offline/fast restoration
    var su: String?        // senderUid — Keychain UUID of the person who sent this receipt
}

struct TabPayload: Codable, Equatable {
    var id: String
    var n: String   // name
    var c: String?  // colorHex
}

struct ReceiptPayload: Codable, Equatable {
    var id: String
    var t: String  // title
    var c: TimeInterval  // createdAtEpoch

    var sub: Int  // subtotalCents
    var f: Int    // feesCents (signed: negative = discount)
    var tx: Int   // taxCents
    var tip: Int  // tipCents
    var tot: Int  // totalCents

    var i: [ReceiptItemPayload]               // items
    var li: [ReceiptLineItemPayload]?         // individual fee/discount/tax rows (nil = use aggregates)

    enum CodingKeys: String, CodingKey {
        case id, t, c, sub, f, tx, tip, tot, i, li
        case legacyD = "d"  // legacy discountCents field
    }

    init(id: String, t: String, c: TimeInterval, sub: Int, f: Int, tx: Int, tip: Int, tot: Int,
         i: [ReceiptItemPayload], li: [ReceiptLineItemPayload]? = nil) {
        self.id = id; self.t = t; self.c = c; self.sub = sub
        self.f = f; self.tx = tx; self.tip = tip; self.tot = tot; self.i = i; self.li = li
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id  = try container.decode(String.self,                forKey: .id)
        t   = try container.decode(String.self,                forKey: .t)
        c   = try container.decode(TimeInterval.self,          forKey: .c)
        sub = try container.decode(Int.self,                   forKey: .sub)
        tx  = try container.decode(Int.self,                   forKey: .tx)
        tip = try container.decode(Int.self,                   forKey: .tip)
        tot = try container.decode(Int.self,                   forKey: .tot)
        i   = try container.decode([ReceiptItemPayload].self,  forKey: .i)
        li  = try container.decodeIfPresent([ReceiptLineItemPayload].self, forKey: .li)
        // Fold legacy discountCents into feesCents as a negative value
        let fees     = try container.decodeIfPresent(Int.self, forKey: .f) ?? 0
        let discount = try container.decodeIfPresent(Int.self, forKey: .legacyD) ?? 0
        f = fees - discount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id,  forKey: .id)
        try container.encode(t,   forKey: .t)
        try container.encode(c,   forKey: .c)
        try container.encode(sub, forKey: .sub)
        try container.encode(f,   forKey: .f)
        try container.encode(tx,  forKey: .tx)
        try container.encode(tip, forKey: .tip)
        try container.encode(tot, forKey: .tot)
        try container.encode(i,   forKey: .i)
        if let li { try container.encode(li, forKey: .li) }
        // Never write legacyD
    }
}

struct ReceiptItemPayload: Codable, Equatable {
    var id: String
    var l: String     // label
    var p: Int        // priceCents
    var rs: [Int]     // responsibleSlots (only for by-items)
}

/// Individual fee/discount/tax line item stored in the payload to preserve order and identity.
struct ReceiptLineItemPayload: Codable, Equatable {
    var id: String  // stable UUID string
    var l: String   // label
    var c: Int      // cents (signed: negative = discount)
}

struct SplitPayload: Codable, Equatable {
    enum Mode: String, Codable {
        case equally = "eq"
        case custom = "cu"
        case byItems = "it"
    }
    
    struct Guest: Codable, Equatable {
        var n: String   // name
        var inc: Bool   // included
        var uid: String? // Keychain UUID of this guest (nil for unknown/other guests)
    }
    
    // ✅ REMOVED: Item array (redundant with receipt items)
    // We can reconstruct assignments from receipt.items[].responsibleSlots
    
    var m: Mode  // mode
    var g: [Guest]  // guests
    var pi: Int     // payerIndex
    var o: [Int]    // owedCents
    var pd: [Bool]? // paidStatus per guest slot (nil = all unpaid)

    // Breakdown (only if non-zero to save space)
    var f: Int?   // feesCents (signed: negative = discount)
    var tx: Int?  // taxCents
    var tip: Int? // tipCents
    var d: Int?   // legacy discountCents — decode only, never written in new payloads
    var tot: Int  // totalCents
}

// MARK: - SplitPayload → SplitDraft conversion

extension SplitPayload {
    /// Converts a sent SplitPayload back to a SplitDraft for editing.
    /// Returns the draft and the UUID-per-slot mapping (for converting back).
    func toSplitDraft(receiptItems: [ReceiptItemPayload], totalCents: Int) -> (draft: SplitDraft, slotUUIDs: [UUID]) {
        let myUid = KeychainHelper.getOrCreateUserId()
        let slotUUIDs = g.map { _ in UUID() }

        let guests = g.enumerated().map { i, guest in
            SplitGuest(
                id: slotUUIDs[i],
                name: guest.n,
                isIncluded: guest.inc,
                isMe: guest.uid == myUid,
                uid: guest.uid
            )
        }

        let mode: SplitDraft.Mode = {
            switch m {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        let items = receiptItems.map { item in
            SplitDraft.Item(
                id: UUID(),
                label: item.l,
                priceCents: item.p,
                assignedGuestIds: item.rs.compactMap { slotUUIDs.indices.contains($0) ? slotUUIDs[$0] : nil }
            )
        }

        // Map owed cents to active guests (preserving original slot indices)
        let activePerGuestCents: [Int] = {
            var result: [Int] = []
            for guest in guests where guest.isIncluded {
                if let origIdx = guests.firstIndex(where: { $0.id == guest.id }),
                   o.indices.contains(origIdx) {
                    result.append(o[origIdx])
                } else {
                    result.append(0)
                }
            }
            return result
        }()

        // Fold legacy discountCents into feesCents as a negative value
        let effectiveFees = (f ?? 0) - (d ?? 0)
        let draft = SplitDraft(
            guests: guests,
            payerGuestId: slotUUIDs.indices.contains(pi) ? slotUUIDs[pi] : (slotUUIDs.first ?? UUID()),
            mode: mode,
            totalCents: totalCents,
            perGuestCents: activePerGuestCents,
            items: items,
            feesCents: effectiveFees,
            taxCents: tx ?? 0,
            tipCents: tip ?? 0
        )
        return (draft, slotUUIDs)
    }
}

// MARK: - Identifiable (for .sheet(item:))

extension LootMessagePayload: Identifiable {
    var id: String { r.id }
}

// MARK: - Edit Permission

extension LootMessagePayload {
    /// Returns true if the given user can edit this receipt.
    /// Editing is allowed if:
    /// 1. The user is the sender (matched by `su` field), OR
    /// 2. The receipt belongs to a tab and the user is a member of that tab.
    /// For backward compat (old payloads without `su`), falls back to checking
    /// if the user's uid appears in any guest slot.
    func canEdit(myUid: String, userTabs: [LootTab]) -> Bool {
        // Check sender identity
        if let senderUid = su {
            if senderUid == myUid { return true }
        } else {
            // Fallback for old payloads: check if user is any guest
            if s.g.contains(where: { $0.uid == myUid }) { return true }
        }

        // Check tab membership
        if let tabId = tid, !tabId.isEmpty {
            if userTabs.contains(where: { $0.id == tabId && $0.memberIds.contains(myUid) }) {
                return true
            }
        }

        return false
    }
}

// MARK: - Base64URL + Codec

enum LootMessageCodec {
    private static let payloadKey = "p"  // shortened from "payload"
    
    static func encodeToQueryValue(_ payload: LootMessagePayload) -> String? {
        do {
            let encoder = JSONEncoder()
            // ✅ Don't include nil values to save space
            encoder.outputFormatting = []
            let data = try encoder.encode(payload)
            
            // ✅ Add compression for large payloads
            let compressed = try? (data as NSData).compressed(using: .lzfse) as Data
            let toEncode = compressed ?? data
            
            let encoded = toEncode.base64URLEncodedString()
            print("[Codec] Payload size: \(data.count) bytes, compressed: \(toEncode.count) bytes, encoded: \(encoded.count) chars")
            
            return encoded
        } catch {
            print("[LootMessageCodec] encode failed: \(error)")
            return nil
        }
    }
    
    static func decodeFromQueryValue(_ s: String) -> LootMessagePayload? {
        guard let data = Data(base64URLEncoded: s) else { return nil }
        
        // ✅ Try decompression first
        let decompressed = (try? (data as NSData).decompressed(using: .lzfse) as Data) ?? data
        
        do {
            return try JSONDecoder().decode(LootMessagePayload.self, from: decompressed)
        } catch {
            print("[LootMessageCodec] decode failed: \(error)")
            return nil
        }
    }
    
    static func payload(from url: URL) -> LootMessagePayload? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = comps.queryItems?.first(where: { $0.name == payloadKey }),
              let value = item.value,
              !value.isEmpty
        else { return nil }
        
        return decodeFromQueryValue(value)
    }
    
    static func writePayload(into components: inout URLComponents, payload: LootMessagePayload) {
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name == payloadKey })
        
        if let encoded = encodeToQueryValue(payload) {
            items.append(URLQueryItem(name: payloadKey, value: encoded))
        }
        components.queryItems = items
    }
}

// MARK: - Base64URL helpers

private extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    init?(base64URLEncoded s: String) {
        var base = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let pad = 4 - (base.count % 4)
        if pad < 4 { base += String(repeating: "=", count: pad) }
        
        self.init(base64Encoded: base)
    }
}
