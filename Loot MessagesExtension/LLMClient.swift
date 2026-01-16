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
    private let model = "gemini-2.5-flash-lite"
    private var baseURL: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    // Diagnostics / behavior toggles
    private let enableEmptyContentFallbackRetry = true
    private let jpegQuality: CGFloat = 0.6
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
        Extract receipt data into ONE minified JSON object.

        REQUIRED fields: merchant, total_cents, items, issues
        OPTIONAL fields: subtotal_cents, tax_cents, tip_cents, fees_cents, discount_cents
        EXAMPLE: {"merchant":"Store","total_cents":1500,"items":[{"label":"Item","qty":1,"cents":500}],"issues":[]}

        Rules:
        - Include EVERY line item that has a price next to it.
        - Rewrite line items to be concise and readable. Example: 93EJ BCN BGR #29A -> Bacon Burger
        - Money is integer cents, and each item's cents is total after quantity.
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
                temperature: 0.1,
                thinkingConfig: .init(thinkingBudget: -1)
                
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
                        temperature: 0.1,
                        thinkingConfig: .init(thinkingBudget: -1)
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
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common trailing quote issues
        if cleaned.hasSuffix("\"}") {
            cleaned = String(cleaned.dropLast(2)) + "}"
        }
        
        // Remove markdown code fences
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
