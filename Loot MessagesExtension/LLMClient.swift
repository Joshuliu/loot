// LLMClient.swift
import Foundation
import UIKit

enum LLMError: Error {
    case badURL
    case badResponse(status: Int, body: String?)
    case emptyText
    case decodeFailed
    case uploadFailed(String)
}

// MARK: - File Upload Response (Gemini File API)

struct FileUploadResponse: Codable {
    let file: FileInfo
    struct FileInfo: Codable {
        let name: String       // e.g., "files/abc123"
        let uri: String        // Full URI for reference
        let mimeType: String
    }
}

// MARK: - Two-Phase Parsing Results

struct Phase1Result: Codable {
    let merchant: String?
    let total_cents: Int?
}

struct Phase2Result: Codable, Equatable {
    struct Item: Codable, Equatable {
        let label: String
        let qty: Int
        let cents: Int?
    }

    let subtotal_cents: Int?
    let tax_cents: Int?
    let tip_cents: Int?
    let fees_cents: Int?
    let discount_cents: Int?
    let items: [Item]
    let issues: [String]
}

final class LLMClient {
    static let shared = LLMClient()

    // Set this in your Info.plist (e.g. via an xcconfig or a Secrets.plist merged into the app target)
    // Key name: GEMINI_API_KEY
    private let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            fatalError("Missing GEMINI_API_KEY")
        }
        return key
    }()
    
    // Gemini REST endpoint: POST /v1beta/models/{model}:generateContent
    // Docs: https://ai.google.dev/api/generate-content
    private let model = "gemini-2.5-flash-lite"
    private var baseURL: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    // Diagnostics / behavior toggles
    private let enableEmptyContentFallbackRetry = true
    private let jpegQuality: CGFloat = 0.6
    private let maxTokensPrimary: Int = 16000
    private let maxTokensFallback: Int = 32000

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // iMessage extensions can be a bit fickle; give the network some breathing room.
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Gemini request/response models

    struct GenerateContentRequest: Codable {
        let contents: [Content]
        let systemInstruction: Content?
        let generationConfig: GenerationConfig?

        struct GenerationConfig: Codable {
            let maxOutputTokens: Int?
            let responseMimeType: String?
            let temperature: Double?
            let thinkingConfig: ThinkingConfig?
            
            enum CodingKeys: String, CodingKey {
                case maxOutputTokens
                case responseMimeType
                case temperature
                case thinkingConfig = "thinking_config"
            }
            
            struct ThinkingConfig: Codable {
                let thinkingBudget: Int
                
                enum CodingKeys: String, CodingKey {
                    case thinkingBudget = "thinking_budget"
                }
            }
        }
    }

    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    struct Part: Codable {
        let text: String?
        let inlineData: InlineData?
        let fileData: FileData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
            case fileData = "file_data"
        }

        struct InlineData: Codable {
            let mimeType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
            }
        }

        struct FileData: Codable {
            let mimeType: String
            let fileUri: String

            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case fileUri = "file_uri"
            }
        }
    }

    struct GenerateContentResponse: Codable {
        let candidates: [Candidate]?

        struct Candidate: Codable {
            let content: Content?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case content
                case finishReason
            }
        }
    }

    // MARK: - Public API

    func analyzeReceipt(
        image: UIImage
    ) async throws -> ParsedReceipt {
        let developerMessage = """
        Extract receipt data into ONE minified JSON object.

        REQUIRED fields: merchant, total_cents, items, issues
        OPTIONAL fields: subtotal_cents, tax_cents, tip_cents, fees_cents, discount_cents
        EXAMPLE: {"merchant":"Store","total_cents":1500,"items":[{"label":"Item","qty":1,"cents":500}],"issues":[]}

        Rules:
        - Include EVERY line item that has a price next to it.
        - Rewrite line items to be concise and readable. Example: 93EJ BCN BGR #29A -> Bacon Burger
        - Money is integer cents, and each item's cents is the final total after quantity.
        - Add "Unknown" if item name is unreadable but price is visible.
        """

        let userMessage = "Parse the receipt image into the specified JSON object."
        
        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else {
            print("[LLM] JPEG encoding failed")
            throw LLMError.badResponse(status: -1, body: "Could not encode image as JPEG")
        }

        let b64 = jpegData.base64EncodedString()

        let systemInstruction = Content(
            role: "system",
            parts: [Part(text: developerMessage, inlineData: nil, fileData: nil)]
        )

        let userContent = Content(
            role: "user",
            parts: [
                Part(text: userMessage, inlineData: nil, fileData: nil),
                Part(
                    text: nil,
                    inlineData: .init(mimeType: "image/jpeg", data: b64),
                    fileData: nil
                )
            ]
        )

        let primaryReq = GenerateContentRequest(
            contents: [userContent],
            systemInstruction: systemInstruction,
            generationConfig: .init(
                maxOutputTokens: maxTokensPrimary,
                responseMimeType: "application/json",
                temperature: 0.1,
                thinkingConfig: .init(thinkingBudget: -1)
            )
        )

        let (text, rawJSON, statusCode, finishReasons) = try await send(primaryReq)
        print("[LLM] finish_reason(s): \(finishReasons.joined(separator: ", "))")

        // Gemini will usually put the JSON in candidates[0].content.parts[].text
        if text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            print("[LLM] Empty response text (status \(statusCode))")
            if !finishReasons.isEmpty {
                print("[LLM] finish_reason(s): \(finishReasons.joined(separator: ", "))")
            }
            print("[LLM] Raw response (primary):\n\(rawJSON ?? "<nil>")")

            if enableEmptyContentFallbackRetry {
                print("[LLM] Retrying with higher maxOutputTokens + plain text…")
                let fallbackReq = GenerateContentRequest(
                    contents: [userContent],
                    systemInstruction: systemInstruction,
                    generationConfig: .init(
                        maxOutputTokens: maxTokensFallback,
                        responseMimeType: nil,
                        temperature: 0.1,
                        thinkingConfig: .init(thinkingBudget: -1)
                    )
                )

                let (fallbackText, fallbackRaw, fallbackStatus, fallbackReasons) = try await send(fallbackReq)
                if fallbackText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                    print("[LLM] Fallback also empty (status \(fallbackStatus))")
                    if !fallbackReasons.isEmpty {
                        print("[LLM] Fallback finish_reason(s): \(fallbackReasons.joined(separator: ", "))")
                    }
                    print("[LLM] Raw response (fallback):\n\(fallbackRaw ?? "<nil>")")
                    throw LLMError.emptyText
                }

                if let parsed = tryDecodeParsedReceipt(from: fallbackText) {
                    return parsed
                }
                if let extracted = extractFirstJSONObject(from: fallbackText),
                   let parsed = tryDecodeParsedReceipt(from: extracted) {
                    return parsed
                }

                print("[LLM] finish_reason(s): \(finishReasons.joined(separator: ", "))")
                print("[LLM] Fallback decode failed. Raw text:\n\(fallbackText)")
                throw LLMError.decodeFailed
            }

            throw LLMError.emptyText
        }

        // Strict decode first
        if let parsed = tryDecodeParsedReceipt(from: text) {
            return parsed
        }

        // Fallback: extract first JSON object and try again
        if let extracted = extractFirstJSONObject(from: text),
           let parsed = tryDecodeParsedReceipt(from: extracted) {
            return parsed
        }

        print("[LLM] Decode failed. Raw text:\n\(text)")
        throw LLMError.decodeFailed
    }

    // MARK: - File Upload (Gemini File API)

    /// Upload image once, get file URI for reuse in multiple requests.
    /// Uses resumable upload protocol per Gemini File API docs.
    func uploadImage(_ image: UIImage) async throws -> String {
        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else {
            throw LLMError.uploadFailed("Could not encode image as JPEG")
        }

        // Step 1: Initialize resumable upload
        let initURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files?key=\(apiKey)")!

        var initRequest = URLRequest(url: initURL)
        initRequest.httpMethod = "POST"
        initRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        initRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        initRequest.setValue("image/jpeg", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        initRequest.setValue("\(jpegData.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Metadata for the file
        let metadata: [String: Any] = ["file": ["display_name": "receipt_\(Date().timeIntervalSince1970)"]]
        initRequest.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, initResp) = try await session.data(for: initRequest)

        guard let httpResp = initResp as? HTTPURLResponse,
              let uploadURL = httpResp.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            throw LLMError.uploadFailed("Failed to get upload URL from response")
        }

        // Step 2: Upload the actual bytes
        var uploadRequest = URLRequest(url: URL(string: uploadURL)!)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = jpegData

        let (uploadData, uploadResp) = try await session.data(for: uploadRequest)

        guard let uploadHttpResp = uploadResp as? HTTPURLResponse,
              (200..<300).contains(uploadHttpResp.statusCode) else {
            let body = String(data: uploadData, encoding: .utf8) ?? "<nil>"
            throw LLMError.uploadFailed("Upload failed: \(body)")
        }

        // Parse response to get file URI
        let decoded = try JSONDecoder().decode(FileUploadResponse.self, from: uploadData)
        print("[LLM] File uploaded: \(decoded.file.uri)")
        return decoded.file.uri
    }

    // MARK: - Phase 1: Quick merchant + total extraction

    func analyzeReceiptPhase1(fileUri: String) async throws -> Phase1Result {
        let developerMessage = """
        Return ONLY minified JSON: {"merchant":string|null,"total_cents":int}
        No extra keys. No markdown. No text.
        """

        let userMessage = "Extract merchant and total from this receipt."

        let systemInstruction = Content(
            role: "system",
            parts: [Part(text: developerMessage, inlineData: nil, fileData: nil)]
        )

        let userContent = Content(
            role: "user",
            parts: [
                Part(text: userMessage, inlineData: nil, fileData: nil),
                Part(
                    text: nil,
                    inlineData: nil,
                    fileData: .init(mimeType: "image/jpeg", fileUri: fileUri)
                )
            ]
        )

        let req = GenerateContentRequest(
            contents: [userContent],
            systemInstruction: systemInstruction,
            generationConfig: .init(
                maxOutputTokens: 128,
                responseMimeType: "application/json",
                temperature: 0.1,
                thinkingConfig: .init(thinkingBudget: 0)
            )
        )

        let (text, _, _, _) = try await send(req)

        guard !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyText
        }

        let repaired = repairJSON(text)
        do {
            return try JSONDecoder().decode(Phase1Result.self, from: Data(repaired.utf8))
        } catch {
            print("[LLM] Phase1 decode error: \(error)")
            print("[LLM] Text: \(repaired)")
            throw LLMError.decodeFailed
        }
    }

    // MARK: - Phase 2: Full items + breakdown extraction

    func analyzeReceiptPhase2(fileUri: String, knownTotalCents: Int) async throws -> Phase2Result {
        let developerMessage = """
        You are parsing for a bill splitting app so users can easily split up receipts by items.
        The total is \(knownTotalCents) cents, and sum of all item cents, taxes, fees, and discounts should sum up exactly to the total.

        Output ONLY using this exact line-based format. No markdown, no code fences, no extra text.

        BEGIN_RECEIPT_V2
        SUBTOTAL_CENTS|<int or empty>
        TAX_CENTS|<int or empty>
        TIP_CENTS|<int or empty>
        FEES_CENTS|<int or empty>
        DISCOUNT_CENTS|<int or empty>

        ITEM|<qty int>|<label string>|<cents int or empty>
        (repeat ITEM lines as needed)

        ISSUE|<string>
        (repeat ISSUE lines as needed; if none, output zero ISSUE lines)

        END_RECEIPT_V2

        Rules:
        - Include ONLY items that are actually charged.
        - Rewrite line items to be concise and readable. Example: 93EJ BCN BGR #29A -> Bacon Burger
        - Calculate sub-items into the parent item's cents; do not include them as a separate item.
        - Each item's cents should be final amount: qty * (price + subitem prices) - item discounts. Example: 2 $10 burgers with $0.50 for pickles would show 2100 cents.
        - CHECK: The sum of all item cents + tax_cents + tip_cents + fees_cents - discount_cents MUST EQUAL \(knownTotalCents).
        - Your response is correct if and only if sum of these charges are strictly equal to \(knownTotalCents) is crucial.
        """

        let userMessage = "Extract all items and breakdown from this receipt that add up to \(knownTotalCents) cents."

        let systemInstruction = Content(
            role: "system",
            parts: [Part(text: developerMessage, inlineData: nil, fileData: nil)]
        )

        let userContent = Content(
            role: "user",
            parts: [
                Part(text: userMessage, inlineData: nil, fileData: nil),
                Part(
                    text: nil,
                    inlineData: nil,
                    fileData: .init(mimeType: "image/jpeg", fileUri: fileUri)
                )
            ]
        )

        let req = GenerateContentRequest(
            contents: [userContent],
            systemInstruction: systemInstruction,
            generationConfig: .init(
                maxOutputTokens: maxTokensPrimary,
                responseMimeType: nil, // <- Phase 2 now uses a strict line protocol
                temperature: 0.15,
                thinkingConfig: .init(thinkingBudget: -1)
            )
        )

        let (text, _, _, _) = try await send(req)

        guard !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyText
        }

        if let parsed = tryDecodePhase2(from: text) {
            return parsed
        }

        print("[LLM] Phase2 decode failed. Raw text:\n\(text)")
        throw LLMError.decodeFailed
    }

    private func tryDecodePhase2(from text: String) -> Phase2Result? {
        // 1) Try to parse the strict line protocol (BEGIN_RECEIPT_V2 ... END_RECEIPT_V2)
        // 2) If it doesn't look like protocol output, fall back to JSON decode (for backwards compatibility)

        let cleaned = text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains("BEGIN_RECEIPT_V2") {
            let lines = cleaned
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var inBlock = false
            var subtotal: Int? = nil
            var tax: Int? = nil
            var tip: Int? = nil
            var fees: Int? = nil
            var discount: Int? = nil
            var items: [Phase2Result.Item] = []
            var issues: [String] = []

            func parseOptionalInt(_ s: String) -> Int? {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return nil }
                return Int(t)
            }

            for line in lines {
                if line == "BEGIN_RECEIPT_V2" {
                    inBlock = true
                    continue
                }
                if line == "END_RECEIPT_V2" {
                    inBlock = false
                    break
                }
                guard inBlock else { continue }

                // Split by | preserving empty fields
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
                guard let tag = parts.first else { continue }

                switch tag {
                case "SUBTOTAL_CENTS":
                    if parts.count >= 2 { subtotal = parseOptionalInt(parts[1]) }
                case "TAX_CENTS":
                    if parts.count >= 2 { tax = parseOptionalInt(parts[1]) }
                case "TIP_CENTS":
                    if parts.count >= 2 { tip = parseOptionalInt(parts[1]) }
                case "FEES_CENTS":
                    if parts.count >= 2 { fees = parseOptionalInt(parts[1]) }
                case "DISCOUNT_CENTS":
                    if parts.count >= 2 { discount = parseOptionalInt(parts[1]) }
                case "ISSUE":
                    if parts.count >= 2 {
                        let msg = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !msg.isEmpty { issues.append(msg) }
                    }
                case "ITEM":
                    // ITEM|<qty int>|<label string>|<cents int or empty>
                    guard parts.count >= 4 else { continue }
                    let qty = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                    let label = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let cents = parseOptionalInt(parts[3])

                    if !label.isEmpty {
                        items.append(.init(label: label, qty: qty, cents: cents))
                    }
                default:
                    continue
                }
            }

            // Basic sanity: we need at least items (can be empty but shouldn't usually be)
            // Still return even if empty so caller can surface issues.
            return Phase2Result(
                subtotal_cents: subtotal,
                tax_cents: tax,
                tip_cents: tip,
                fees_cents: fees,
                discount_cents: discount,
                items: items,
                issues: issues
            )
        }

        // Fallback: JSON decode (older behavior)
        let repaired = repairJSON(text)
        do {
            return try JSONDecoder().decode(Phase2Result.self, from: Data(repaired.utf8))
        } catch {
            print("[LLM] Phase2 decode error: \(error)")
            return nil
        }
    }

    // MARK: - JSON helpers

    private func tryDecodeParsedReceipt(from text: String) -> ParsedReceipt? {
        let repaired = repairJSON(text)
        do {
            return try JSONDecoder().decode(ParsedReceipt.self, from: Data(repaired.utf8))
        } catch {
            print("[LLM] Decode error: \(error)")
            print("[LLM] Text:\n\(repaired)")
            return nil
        }
    }
    
    private func repairJSON(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Remove common trailing quote issues
        if cleaned.hasSuffix("\"}") {
            cleaned = String(cleaned.dropLast(2)) + "}"
        }

        // Remove markdown code fences
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        return cleaned
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        
        // Count braces to find matching close
        var depth = 0
        var endIndex: String.Index? = nil
        
        for index in cleaned.indices[start...] {
            let char = cleaned[index]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = index
                    break
                }
            }
        }
        
        guard let end = endIndex else { return nil }
        return String(cleaned[start...end])
    }

    // MARK: - Internal network helper with diagnostics

    private func send(_ req: GenerateContentRequest) async throws -> (text: String, rawJSON: String?, status: Int, finishReasons: [String]) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(req)

        let (data, resp) = try await session.data(for: request)

        guard let http = resp as? HTTPURLResponse else {
            print("[LLM] No HTTPURLResponse")
            throw LLMError.badResponse(status: -1, body: "No HTTPURLResponse")
        }

        let status = http.statusCode
        let raw = String(data: data, encoding: .utf8)

        if !(200..<300).contains(status) {
            print("[LLM] Non-2xx response, status: \(status)")
            print("[LLM] Body: \(raw ?? "<empty>")")
            throw LLMError.badResponse(status: status, body: raw)
        }

        let decoded: GenerateContentResponse
        do {
            decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            print("[LLM] Decode GenerateContentResponse failed. Raw body:\n\(raw ?? "<nil>")")
            throw LLMError.decodeFailed
        }

        let candidates = decoded.candidates ?? []
        let first = candidates.first

        let parts = first?.content?.parts ?? []
        let text = parts.compactMap { $0.text }.joined()
        let reasons = candidates.compactMap { $0.finishReason }

        return (text, raw, status, reasons)
    }
}
