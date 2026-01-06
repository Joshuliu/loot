// LLMClient.swift
import Foundation
import UIKit

enum LLMError: Error {
    case badURL
    case badResponse(status: Int, body: String?)
    case emptyText
    case decodeFailed
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
    private let model = "gemini-3-flash-preview"
    private var baseURL: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    // Diagnostics / behavior toggles
    private let enableEmptyContentFallbackRetry = true
    private let jpegQuality: CGFloat = 0.9
    private let maxTokensPrimary: Int = 8000
    private let maxTokensFallback: Int = 16000

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
        }
    }

    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    struct Part: Codable {
        let text: String?
        let inlineData: InlineData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }

        struct InlineData: Codable {
            let mimeType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
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
        Extract receipt data into ONE minified JSON object (single line). Output ONLY JSON and NO extra keys.

        Keys: required merchant,total_cents,items,issues. Optional (include ONLY if visible on receipt, even if 0): subtotal_cents,tax_cents,tip_cents,fees_cents,discount_cents.
        Types: merchant string|null; *_cents int>=0|null; items=[{label:string,qty:int>=1,cents:int>=0|null}]; issues=[string].

        Rules:
        - Prefer exact visible values; never change a readable number to force math.
        - If something needed is unreadable/missing, make a best guess and add issues including: estimated plus a reason (unreadable/blurred/cut_off/missing_line_total).
        - Money is integer cents.
        - Checks (if data present): if all item cents present, subtotal == sum(items.cents) else add partial_items; total == subtotal+tax+tip+fees-discount else add math_mismatch.
        - Add issues whenever uncertain or any check fails.
        """

        let userMessage = "Parse the receipt image into the specified JSON object."

//        let developerMessage = """
//You extract receipt data into JSON. OUTPUT ONLY valid JSON that matches the provided schema exactly. No markdown, no commentary, no extra keys. Rules: - Use ONLY what is visible in the image. - All money values must be integer cents. - Ensure the math works
//"""
//        
//        let userMessage = """
//Parse the attached receipt image into the JSON schema below. JSON Schema: { "type": "object", "additionalProperties": false, "required": ["merchant", "total_cents", "items", "issues"], "properties": { "merchant": { "type": ["string", "null"] }, "total_cents": { "type": ["integer", "null"], "minimum": 0 }, "subtotal_cents": { "type": ["integer", "null"], "minimum": 0 }, "tax_cents": { "type": ["integer", "null"], "minimum": 0 }, "tip_cents": { "type": ["integer", "null"], "minimum": 0 }, "fees_cents": { "type": ["integer", "null"], "minimum": 0 }, "discount_cents": { "type": ["integer", "null"], "minimum": 0 }, "items": { "type": "array", "items": { "type": "object", "additionalProperties": false, "required": ["label", "qty", "cents"], "properties": { "label": { "type": "string" }, "qty": { "type": "integer", "minimum": 1 }, "cents": { "type": ["integer", "null"], "minimum": 0 } } } }, "issues": { "type": "array", "items": { "type": "string" } } } }
//"""
        
        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else {
            print("[LLM] JPEG encoding failed")
            throw LLMError.badResponse(status: -1, body: "Could not encode image as JPEG")
        }

        let b64 = jpegData.base64EncodedString()

        let systemInstruction = Content(
            role: "system",
            parts: [Part(text: developerMessage, inlineData: nil)]
        )

        let userContent = Content(
            role: "user",
            parts: [
                Part(text: userMessage, inlineData: nil),
                Part(
                    text: nil,
                    inlineData: .init(mimeType: "image/jpeg", data: b64)
                )
            ]
        )

        let primaryReq = GenerateContentRequest(
            contents: [userContent],
            systemInstruction: systemInstruction,
            generationConfig: .init(
                maxOutputTokens: maxTokensPrimary,
                responseMimeType: "application/json",
                temperature: 0.1
            )
        )

        let (text, rawJSON, statusCode, finishReasons) = try await send(primaryReq)
        print("[LLM] finish_reason(s): \(finishReasons.joined(separator: ", "))")

        // Gemini will usually put the JSON in candidates[0].content.parts[].text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        temperature: 0.1
                    )
                )

                let (fallbackText, fallbackRaw, fallbackStatus, fallbackReasons) = try await send(fallbackReq)
                if fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    // MARK: - JSON helpers

    private func tryDecodeParsedReceipt(from text: String) -> ParsedReceipt? {
        do {
            return try JSONDecoder().decode(ParsedReceipt.self, from: Data(text.utf8))
        } catch {
            print("[LLM] Decode error: \(error)")
            print("[LLM] Text:\n\(text)")
            return nil
        }
    }


    private func extractFirstJSONObject(from text: String) -> String? {
        // Strip common code-fence wrappers if the model ignores JSON mode.
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end else {
            return nil
        }
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
