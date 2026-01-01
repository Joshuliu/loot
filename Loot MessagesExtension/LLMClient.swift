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

    // TODO: set your endpoint + key here or via secrets
    private let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            fatalError("Missing OPENAI_API_KEY")
        }
        return key
    }()
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let model = "gpt-5-mini"

    // Diagnostics / behavior toggles
    private let enableEmptyContentFallbackRetry = true   // retry once without response_format if empty content
    private let jpegQuality: CGFloat = 0.9               // adjust if payload size seems to cause issues
    private let maxTokensPrimary: Int = 2500
    private let maxTokensFallback: Int = 5000

    private init() {}

    struct ChatMessage: Codable {
        let role: String
        let content: [ContentBlock]
    }

    struct ContentBlock: Codable {
        let type: String
        let text: String?
        let image_url: ImageURLPayload?

        struct ImageURLPayload: Codable {
            let url: String
        }
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let max_completion_tokens: Int
        let response_format: ResponseFormat?

        struct ResponseFormat: Codable {
            let type: String
        }
    }

    struct ChatResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let role: String
                let content: String
                // Some providers may return tool_calls or other fields; we ignore them here.
            }
            let index: Int
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    func analyzeReceipt(
        image: UIImage,
        developerMessage: String,
        userMessage: String
    ) async throws -> ParsedReceipt {
        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else {
            print("[LLM] JPEG encoding failed")
            throw LLMError.badResponse(status: -1, body: "Could not encode image as JPEG")
        }

        let b64 = jpegData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(b64)"

        let systemMsg = ChatMessage(
            role: "system",
            content: [
                ContentBlock(type: "text", text: developerMessage, image_url: nil)
            ]
        )

        let userMsg = ChatMessage(
            role: "user",
            content: [
                ContentBlock(type: "text", text: userMessage, image_url: nil),
                ContentBlock(type: "image_url", text: nil, image_url: .init(url: dataURL))
            ]
        )

        // Primary request (with response_format)
        let primaryReq = ChatRequest(
            model: model,
            messages: [systemMsg, userMsg],
            max_completion_tokens: maxTokensPrimary,
            response_format: .init(type: "json_object")
        )

        do {
            let (text, rawJSON, statusCode, finishReasons) = try await send(primaryReq)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[LLM] Empty content in choices[0].message.content (status \(statusCode))")
                if !finishReasons.isEmpty {
                    print("[LLM] finish_reason(s): \(finishReasons.joined(separator: ", "))")
                }
                print("[LLM] Raw response (primary):\n\(rawJSON ?? "<nil>")")

                if enableEmptyContentFallbackRetry {
                    print("[LLM] Retrying without response_format…")
                    let fallbackReq = ChatRequest(
                        model: model,
                        messages: [systemMsg, userMsg],
                        max_completion_tokens: maxTokensFallback,
                        response_format: nil // remove JSON object constraint to probe behavior
                    )
                    let (fallbackText, fallbackRaw, fallbackStatus, fallbackReasons) = try await send(fallbackReq)

                    if fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        print("[LLM] Fallback also empty (status \(fallbackStatus))")
                        if !fallbackReasons.isEmpty {
                            print("[LLM] Fallback finish_reason(s): \(fallbackReasons.joined(separator: ", "))")
                        }
                        print("[LLM] Raw response (fallback):\n\(fallbackRaw ?? "<nil>")")
                        throw LLMError.emptyText
                    } else {
                        // Try to decode ParsedReceipt from fallback text (should be JSON or at least parseable)
                        do {
                            let jsonData = Data(fallbackText.utf8)
                            let parsed = try JSONDecoder().decode(ParsedReceipt.self, from: jsonData)
                            return parsed
                        } catch {
                            print("[LLM] Fallback decode failed. Raw text:\n\(fallbackText)")
                            throw LLMError.decodeFailed
                        }
                    }
                } else {
                    throw LLMError.emptyText
                }
            }

            // Primary path had non-empty content; decode it
            do {
                let jsonData = Data(text.utf8)
                return try JSONDecoder().decode(ParsedReceipt.self, from: jsonData)
            } catch {
                print("[LLM] Failed to decode ParsedReceipt from model output text")
                print("[LLM] Raw text:\n\(text)")
                throw LLMError.decodeFailed
            }
        } catch let err as LLMError {
            throw err
        } catch {
            print("[LLM] Transport error: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Internal network helper with diagnostics

    private func send(_ req: ChatRequest) async throws -> (text: String, rawJSON: String?, status: Int, finishReasons: [String]) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(req)

        let (data, resp) = try await URLSession.shared.data(for: request)

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

        // Decode to extract content and finish_reason
        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            print("[LLM] Decode ChatResponse failed. Raw body:\n\(raw ?? "<nil>")")
            throw LLMError.decodeFailed
        }

        let content = decoded.choices.first?.message.content ?? ""
        let reasons = decoded.choices.compactMap { $0.finish_reason }

        // When everything looks fine but content is empty, return diagnostics
        return (content, raw, status, reasons)
    }
}
