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
}

struct ReceiptPayload: Codable, Equatable {
    var id: String
    var t: String  // title
    var c: TimeInterval  // createdAtEpoch
    
    var sub: Int  // subtotalCents
    var f: Int    // feesCents
    var tx: Int   // taxCents
    var tip: Int  // tipCents
    var d: Int    // discountCents
    var tot: Int  // totalCents
    
    var i: [ReceiptItemPayload]  // items
}

struct ReceiptItemPayload: Codable, Equatable {
    var id: String
    var l: String     // label
    var p: Int        // priceCents
    var rs: [Int]     // responsibleSlots (only for by-items)
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
        var me: Bool    // isMe
    }
    
    // ✅ REMOVED: Item array (redundant with receipt items)
    // We can reconstruct assignments from receipt.items[].responsibleSlots
    
    var m: Mode  // mode
    var g: [Guest]  // guests
    var pi: Int     // payerIndex
    var o: [Int]    // owedCents
    
    // Breakdown (only if non-zero to save space)
    var f: Int?   // feesCents
    var tx: Int?  // taxCents
    var tip: Int? // tipCents
    var d: Int?   // discountCents
    var tot: Int  // totalCents
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
