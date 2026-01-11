//
//  LootMessagePayload.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import Foundation

// MARK: - Payload carried inside MSMessage.url

struct LootMessagePayload: Codable, Equatable {
    var v: Int = 1
    var receipt: ReceiptPayload
    var split: SplitPayload
}

struct ReceiptPayload: Codable, Equatable {
    var id: String
    var title: String
    var createdAtEpoch: TimeInterval

    var subtotalCents: Int
    var feesCents: Int
    var taxCents: Int
    var tipCents: Int
    var discountCents: Int
    var totalCents: Int

    var items: [ReceiptItemPayload]
}

struct ReceiptItemPayload: Codable, Equatable {
    var id: String
    var label: String
    var priceCents: Int
    /// Slot indices (0..guests.count-1) responsible for this item (only meaningful for by-items)
    var responsibleSlots: [Int]
}

struct SplitPayload: Codable, Equatable {
    enum Mode: String, Codable { case equally, custom, byItems }

    struct Guest: Codable, Equatable {
        var name: String
        var included: Bool
        var isMe: Bool
    }

    struct Item: Codable, Equatable {
        var label: String
        var priceCents: Int
        /// Slot indices of guests assigned to this item (can be empty)
        var assignedSlots: [Int]
    }

    var mode: Mode

    var guests: [Guest]
    var payerIndex: Int

    /// Total owed per guest slot (same length as guests; excluded guests typically 0)
    var owedCents: [Int]

    /// Only needed for by-items “what items did they get?”
    var items: [Item]

    var feesCents: Int
    var taxCents: Int
    var tipCents: Int
    var discountCents: Int
    var totalCents: Int
}

// MARK: - Base64URL + Codec

enum LootMessageCodec {
    private static let payloadKey = "payload"

    static func encodeToQueryValue(_ payload: LootMessagePayload) -> String? {
        do {
            let data = try JSONEncoder().encode(payload)
            return data.base64URLEncodedString()
        } catch {
            print("[LootMessageCodec] encode failed: \(error)")
            return nil
        }
    }

    static func decodeFromQueryValue(_ s: String) -> LootMessagePayload? {
        guard let data = Data(base64URLEncoded: s) else { return nil }
        do {
            return try JSONDecoder().decode(LootMessagePayload.self, from: data)
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
