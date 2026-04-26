//
//  LootMessagePayload.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import Foundation

private let payloadDisplayNameDefaultsKey = "my_display_name"
private let payloadUserIdDefaultsKey = "local_participant_id"

private func payloadDisplayNameFromDefaults() -> String {
    (UserDefaults.standard.string(forKey: payloadDisplayNameDefaultsKey) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func payloadCurrentUserId() -> String {
    let defaults = UserDefaults.standard
    let existing = (defaults.string(forKey: payloadUserIdDefaultsKey) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !existing.isEmpty { return existing }

    let generated = UUID().uuidString
    defaults.set(generated, forKey: payloadUserIdDefaultsKey)
    return generated
}

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
    var f: Int    // feesCents
    var d: Int    // discountCents
    var tx: Int   // taxCents
    var tip: Int  // tipCents
    var tot: Int  // totalCents

    var i: [ReceiptItemPayload]               // items
    var li: [ReceiptLineItemPayload]?         // individual fee/discount/tax rows (nil = use aggregates)

    enum CodingKeys: String, CodingKey {
        case id, t, c, sub, f, tx, tip, tot, i, li, d
    }

    init(id: String, t: String, c: TimeInterval, sub: Int, f: Int, d: Int = 0, tx: Int, tip: Int, tot: Int,
         i: [ReceiptItemPayload], li: [ReceiptLineItemPayload]? = nil) {
        self.id = id; self.t = t; self.c = c; self.sub = sub
        self.f = f; self.d = d; self.tx = tx; self.tip = tip; self.tot = tot; self.i = i; self.li = li
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
        let rawFees = try container.decodeIfPresent(Int.self, forKey: .f) ?? 0
        let decodedDiscount = try container.decodeIfPresent(Int.self, forKey: .d)
            ?? (rawFees < 0 ? abs(rawFees) : 0)
        f = max(0, rawFees)
        d = max(0, decodedDiscount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id,  forKey: .id)
        try container.encode(t,   forKey: .t)
        try container.encode(c,   forKey: .c)
        try container.encode(sub, forKey: .sub)
        try container.encode(f,   forKey: .f)
        if d != 0 { try container.encode(d, forKey: .d) }
        try container.encode(tx,  forKey: .tx)
        try container.encode(tip, forKey: .tip)
        try container.encode(tot, forKey: .tot)
        try container.encode(i,   forKey: .i)
        if let li { try container.encode(li, forKey: .li) }
        // Never write legacy folded discount state
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
    var f: Int?   // feesCents
    var tx: Int?  // taxCents
    var tip: Int? // tipCents
    var d: Int?   // discountCents
    var tot: Int  // totalCents

    init(m: Mode, g: [Guest], pi: Int, o: [Int], pd: [Bool]? = nil, f: Int? = nil, tx: Int? = nil, tip: Int? = nil, d: Int? = nil, tot: Int) {
        self.m = m
        self.g = g
        self.pi = pi
        self.o = o
        self.pd = pd
        self.f = f
        self.tx = tx
        self.tip = tip
        self.d = d
        self.tot = tot
    }

    enum CodingKeys: String, CodingKey {
        case m, g, pi, o, pd, f, tx, tip, d, tot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        m = try container.decode(Mode.self, forKey: .m)
        g = try container.decode([Guest].self, forKey: .g)
        pi = try container.decode(Int.self, forKey: .pi)
        o = try container.decode([Int].self, forKey: .o)
        pd = try container.decodeIfPresent([Bool].self, forKey: .pd)
        let rawFees = try container.decodeIfPresent(Int.self, forKey: .f)
        f = max(0, rawFees ?? 0)
        d = try container.decodeIfPresent(Int.self, forKey: .d) ?? ((rawFees ?? 0) < 0 ? abs(rawFees ?? 0) : nil)
        tx = try container.decodeIfPresent(Int.self, forKey: .tx)
        tip = try container.decodeIfPresent(Int.self, forKey: .tip)
        tot = try container.decode(Int.self, forKey: .tot)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(m, forKey: .m)
        try container.encode(g, forKey: .g)
        try container.encode(pi, forKey: .pi)
        try container.encode(o, forKey: .o)
        try container.encodeIfPresent(pd, forKey: .pd)
        try container.encodeIfPresent(f, forKey: .f)
        try container.encodeIfPresent(tx, forKey: .tx)
        try container.encodeIfPresent(tip, forKey: .tip)
        try container.encodeIfPresent(d, forKey: .d)
        try container.encode(tot, forKey: .tot)
    }
}

// MARK: - SplitPayload → SplitDraft conversion

extension SplitPayload {
    /// Converts a sent SplitPayload back to a SplitDraft for editing.
    /// Returns the draft and the UUID-per-slot mapping (for converting back).
    func toSplitDraft(receiptItems: [ReceiptItemPayload], totalCents: Int) -> (draft: SplitDraft, slotUUIDs: [UUID]) {
        let myUid = payloadCurrentUserId()
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

        let draft = SplitDraft(
            guests: guests,
            payerGuestId: slotUUIDs.indices.contains(pi) ? slotUUIDs[pi] : (slotUUIDs.first ?? UUID()),
            mode: mode,
            totalCents: totalCents,
            perGuestCents: activePerGuestCents,
            items: items,
            feesCents: f ?? 0,
            discountCents: d ?? 0,
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

struct InlineMessageEnvelope: Codable, Equatable {
    var payload: LootMessagePayload
    var ignoredUUIDs: [String]?
}

enum LootMessageCodec {
    struct DecodedInlinePayload: Equatable {
        var payload: LootMessagePayload
        var ignoredUUIDs: [String]
        var hasIgnoredUUIDsList: Bool
    }

    private static let payloadKey = "p"  // shortened from "payload"

    private static func normalizedIgnoredUUIDs(_ uuids: [String]) -> [String] {
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

    static func encodeToQueryValue(_ envelope: InlineMessageEnvelope) -> String? {
        do {
            let encoder = JSONEncoder()
            // ✅ Don't include nil values to save space
            encoder.outputFormatting = []
            let normalized = InlineMessageEnvelope(
                payload: envelope.payload,
                ignoredUUIDs: envelope.ignoredUUIDs.map(normalizedIgnoredUUIDs)
            )
            let data = try encoder.encode(normalized)
            
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

    static func decodeFromQueryValue(_ s: String) -> DecodedInlinePayload? {
        guard let data = Data(base64URLEncoded: s) else { return nil }
        
        // ✅ Try decompression first
        let decompressed = (try? (data as NSData).decompressed(using: .lzfse) as Data) ?? data
        
        do {
            let envelope = try JSONDecoder().decode(InlineMessageEnvelope.self, from: decompressed)
            let list = normalizedIgnoredUUIDs(envelope.ignoredUUIDs ?? [])
            return DecodedInlinePayload(
                payload: envelope.payload,
                ignoredUUIDs: list,
                hasIgnoredUUIDsList: envelope.ignoredUUIDs != nil
            )
        } catch {
            do {
                let legacyPayload = try JSONDecoder().decode(LootMessagePayload.self, from: decompressed)
                return DecodedInlinePayload(
                    payload: legacyPayload,
                    ignoredUUIDs: [],
                    hasIgnoredUUIDsList: false
                )
            } catch {
                print("[LootMessageCodec] decode failed: \(error)")
                return nil
            }
        }
    }

    static func decodedInlinePayload(from url: URL) -> DecodedInlinePayload? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = comps.queryItems?.first(where: { $0.name == payloadKey }),
              let value = item.value,
              !value.isEmpty
        else { return nil }
        
        return decodeFromQueryValue(value)
    }

    static func payload(from url: URL) -> LootMessagePayload? {
        decodedInlinePayload(from: url)?.payload
    }

    static func writePayload(
        into components: inout URLComponents,
        payload: LootMessagePayload,
        ignoredUUIDs: [String]? = nil
    ) {
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name == payloadKey })

        let envelope = InlineMessageEnvelope(payload: payload, ignoredUUIDs: ignoredUUIDs)
        if let encoded = encodeToQueryValue(envelope) {
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

// MARK: - Payload → ReceiptDisplay

extension LootMessagePayload {
    func toReceiptDisplay() -> ReceiptDisplay {
        let receiptData = r
        let splitData = s

        let items: [ReceiptDisplay.Item] = receiptData.i.map { it in
            let responsible: [ReceiptDisplay.Responsible] = it.rs.map { slot in
                let nm: String = {
                    guard splitData.g.indices.contains(slot) else { return "Guest \(slot + 1)" }
                    let g = splitData.g[slot]
                    let t = g.n.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                    return g.uid == payloadCurrentUserId() ? "Me" : "Guest \(slot + 1)"
                }()
                return ReceiptDisplay.Responsible(slotIndex: slot, displayName: nm)
            }
            .sorted(by: { $0.slotIndex < $1.slotIndex })

            // Phase 2.7b: also populate canonical PersonID list. Use the guest's
            // Keychain uid when available; fall back to a synthesized "slot-N"
            // raw value so the index can still round-trip back to a slot for
            // wire-format encoding.
            let assigneeIDs: [PersonID] = it.rs.map { slot in
                if splitData.g.indices.contains(slot),
                   let uid = splitData.g[slot].uid, !uid.isEmpty {
                    return PersonID(rawValue: uid)
                }
                return PersonID(rawValue: "slot-\(slot)")
            }

            return ReceiptDisplay.Item(
                id: it.id,
                label: it.l,
                priceCents: it.p,
                responsible: responsible,
                assigneeIDs: assigneeIDs
            )
        }

        let lineItems: [ReceiptDisplay.LineItem] = (receiptData.li ?? []).map {
            ReceiptDisplay.LineItem(id: $0.id, label: $0.l, cents: $0.c)
        }

        return ReceiptDisplay(
            id: receiptData.id,
            title: receiptData.t,
            createdAt: Date(timeIntervalSince1970: receiptData.c),
            subtotalCents: receiptData.sub,
            feesCents: receiptData.f,
            discountCents: receiptData.d,
            taxCents: receiptData.tx,
            tipCents: receiptData.tip,
            totalCents: receiptData.tot,
            items: items,
            lineItems: lineItems
        )
    }
}

// MARK: - Build SplitPayload from SplitDraft

extension SplitPayload {
    static func from(draft: SplitDraft?, participantCount: Int, totalCents: Int) -> SplitPayload {
        let guests: [Guest] = {
            if let d = draft, !d.guests.isEmpty {
                return d.guests.map { Guest(n: $0.name, inc: $0.isIncluded, uid: $0.uid) }
            }
            var out: [Guest] = [Guest(n: payloadDisplayNameFromDefaults(), inc: true, uid: payloadCurrentUserId())]
            if participantCount > 1 {
                for _ in 1..<participantCount {
                    out.append(Guest(n: "", inc: true, uid: nil))
                }
            }
            return out
        }()

        let payerIndex: Int = {
            guard let d = draft else { return 0 }
            return d.guests.firstIndex(where: { $0.id == d.payerGuestId }) ?? 0
        }()

        let mode: Mode = {
            guard let d = draft else { return .equally }
            switch d.mode {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        let fees = draft?.feesCents ?? 0
        let discount = draft?.discountCents ?? 0
        let tax = draft?.taxCents ?? 0
        let tip = draft?.tipCents ?? 0

        let itemsForMath: [(label: String, priceCents: Int, assignedSlots: [Int])] = {
            guard let d = draft, d.mode == .byItems else { return [] }
            let slotIndexByUUID: [UUID: Int] = Dictionary(uniqueKeysWithValues:
                d.guests.enumerated().map { ($0.element.id, $0.offset) })
            return d.items.map { it in
                let slots = it.assignedGuestIds.compactMap { slotIndexByUUID[$0] }.sorted()
                return (label: it.label, priceCents: it.priceCents, assignedSlots: slots)
            }
        }()

        let owed = SplitMath.computeOwedCents(
            mode: mode,
            guests: guests,
            payerIndex: payerIndex,
            totalCents: totalCents,
            perGuestActive: draft?.perGuestCents,
            items: itemsForMath,
            feesCents: fees,
            discountCents: discount,
            taxCents: tax,
            tipCents: tip
        )

        return SplitPayload(
            m: mode,
            g: guests,
            pi: payerIndex,
            o: owed,
            f: fees == 0 ? nil : fees,
            tx: tax == 0 ? nil : tax,
            tip: tip == 0 ? nil : tip,
            d: discount == 0 ? nil : discount,
            tot: totalCents
        )
    }
}

// MARK: - Build ReceiptPayload from ReceiptDisplay

extension ReceiptPayload {
    static func from(receipt: ReceiptDisplay, split: SplitPayload) -> ReceiptPayload {
        let isByItems = (split.m == .byItems)

        let items: [ReceiptItemPayload] = {
            return receipt.items.map { it in
                let slots = isByItems ? it.responsible.map { $0.slotIndex }.sorted() : []
                return ReceiptItemPayload(
                    id: it.id,
                    l: it.label,
                    p: it.priceCents,
                    rs: slots
                )
            }
        }()

        let lineItems: [ReceiptLineItemPayload]? = receipt.lineItems.isEmpty ? nil :
            receipt.lineItems.map { ReceiptLineItemPayload(id: $0.id, l: $0.label, c: $0.cents) }

        return ReceiptPayload(
            id: receipt.id,
            t: receipt.title,
            c: receipt.createdAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            sub: receipt.subtotalCents,
            f: receipt.feesCents,
            d: receipt.discountCents,
            tx: receipt.taxCents,
            tip: receipt.tipCents,
            tot: receipt.totalCents,
            i: items,
            li: lineItems
        )
    }
}
