import Foundation

public enum GeminiReceiptAnalyzerError: Error {
    case missingAPIKey
    case badResponse(status: Int, body: String?)
    case emptyText
    case decodeFailed
}

public final class GeminiReceiptAnalyzer: ReceiptLLMAnalyzing {
    public struct Configuration {
        public let apiKey: String
        public let model: String
        public let timeout: TimeInterval

        public init(apiKey: String, model: String = "gemini-2.5-flash-lite", timeout: TimeInterval = 120) {
            self.apiKey = apiKey
            self.model = model
            self.timeout = timeout
        }

        public static func fromEnvironment() throws -> Configuration {
            let env = ProcessInfo.processInfo.environment
            if let key = env["GEMINI_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Configuration(apiKey: key)
            }
            if let key = Self.loadKeyFromSecretsXCConfig(named: "GEMINI_API_KEY") {
                return Configuration(apiKey: key)
            }
            throw GeminiReceiptAnalyzerError.missingAPIKey
        }

        private static func loadKeyFromSecretsXCConfig(named name: String) -> String? {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let url = cwd.appendingPathComponent("Secrets.xcconfig")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawLine
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("\(name)"), let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
                let value = trimmed[trimmed.index(after: equalsIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }

            return nil
        }
    }

    private let config: Configuration
    private let maxTokensPrimary: Int = 16000
    private let retryableStatusCodes: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.timeout
        cfg.timeoutIntervalForResource = config.timeout
        return URLSession(configuration: cfg)
    }()

    public init(configuration: Configuration) {
        self.config = configuration
    }

    private struct GenerateContentRequest: Codable {
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

    private struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    private struct Part: Codable {
        let text: String?
    }

    private struct GenerateContentResponse: Codable {
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

    public func analyzePhase1(transcript: String) async throws -> Phase1Result {
        let req = GenerateContentRequest(
            contents: [Content(role: "user", parts: [Part(text: "Extract merchant and total from this receipt transcript:\n\n\(transcript)")])],
            systemInstruction: Content(role: "system", parts: [Part(text: """
            Extract the merchant name and the final total from a receipt transcript.
            Return ONLY minified JSON: {"merchant":string|null,"total_cents":int}
            No extra keys. No markdown. No text.

            Rules for total_cents:
            - Use the final "Total" amount the customer paid, in integer cents (e.g., $48.32 → 4832).
            - If the receipt shows both a Subtotal and a Tax line but no explicit Total, add them: total = subtotal + tax.
            - If no Total line is visible, sum all individual item prices plus any visible tax.
            - Prefer the largest "Total" labeled amount over partial totals like "Subtotal" or "Balance".
            - Ignore card approval codes, reference numbers, POS IDs, and other non-monetary numbers.
            - If multiple total-like amounts appear, prefer the one labeled "Total", "Grand Total", "Amount Due", or "Balance Due".
            - The total should include tax but exclude tip unless tip is explicitly included in a "Total" line.

            Rules for merchant:
            - Extract the store or restaurant name. Use the most prominent business name, not addresses or slogans.
            """)]),
            generationConfig: .init(
                maxOutputTokens: 2048,
                responseMimeType: nil,
                temperature: 0,
                thinkingConfig: .init(thinkingBudget: -1)
            )
        )

        let (text, _, _, _) = try await send(req)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiReceiptAnalyzerError.emptyText
        }
        // Extract JSON object from response — model may include reasoning text around it
        let jsonString = extractJSON(from: text)
        let repaired = repairJSON(jsonString)
        if let data = repaired.data(using: .utf8),
           let result = try? JSONDecoder().decode(Phase1Result.self, from: data) {
            return result
        }
        // Fallback: try to find total_cents and merchant via regex
        return Phase1Result(
            merchant: extractMerchantFallback(from: text),
            total_cents: extractTotalCentsFallback(from: text)
        )
    }

    public func analyzePhase2(transcript: String, knownTotalCents: Int) async throws -> (phase2: Phase2Result, lineItems: [OCRLineItem], rawResponse: String?) {
        let primaryText = try await sendPhase2Request(
            transcript: transcript,
            knownTotalCents: knownTotalCents,
            rescueReason: nil
        )

        let resolvedPrimary = decodeAndResolvePhase2(
            from: primaryText,
            knownTotalCents: knownTotalCents
        )

        if let resolvedPrimary, !shouldRescuePhase2(resolvedPrimary, knownTotalCents: knownTotalCents) {
            return (resolvedPrimary.phase2, resolvedPrimary.lineItems, primaryText)
        }

        let rescueReason = phase2RescueReason(
            primaryResponse: primaryText,
            knownTotalCents: knownTotalCents
        )
        let rescueText = try await sendPhase2Request(
            transcript: transcript,
            knownTotalCents: knownTotalCents,
            rescueReason: rescueReason
        )

        let resolvedRescue = decodeAndResolvePhase2(
            from: rescueText,
            knownTotalCents: knownTotalCents
        )

        // Pick the better result: whichever reconciles closer to knownTotal
        if let resolvedRescue, let resolvedPrimary {
            let primaryGap = abs(knownTotalCents - computedAccountedTotal(for: resolvedPrimary))
            let rescueGap = abs(knownTotalCents - computedAccountedTotal(for: resolvedRescue))
            if primaryGap <= rescueGap {
                return (resolvedPrimary.phase2, resolvedPrimary.lineItems, primaryText)
            }
            return (resolvedRescue.phase2, resolvedRescue.lineItems, rescueText)
        } else if let resolvedRescue {
            return (resolvedRescue.phase2, resolvedRescue.lineItems, rescueText)
        } else if let resolvedPrimary {
            return (resolvedPrimary.phase2, resolvedPrimary.lineItems, primaryText)
        }

        throw GeminiReceiptAnalyzerError.decodeFailed
    }

    private func sendPhase2Request(
        transcript: String,
        knownTotalCents: Int,
        rescueReason: String?
    ) async throws -> String {
        let rescueInstructions: String
        if let rescueReason {
            rescueInstructions = """
            Additional rescue instructions:
            - The previous attempt was not usable: \(rescueReason)
            - Be exhaustive. Missing rows are worse than slightly noisy labels.
            - Include every purchasable item row with a visible or inferable local amount.
            - Do not stop after the footer; include the body line items first, then footer rows.
            - The known receipt total is \(knownTotalCents) cents. Do not output that total as an ITEM unless it is literally a purchasable line item.
            - If output would otherwise be empty, output UNKNOWN rows for the visible priced rows instead of returning nothing.
            """
        } else {
            rescueInstructions = ""
        }

        let req = GenerateContentRequest(
            contents: [Content(role: "user", parts: [Part(text: "Extract the ordered receipt rows from this receipt transcript:\n\n\(transcript)")])],
            systemInstruction: Content(role: "system", parts: [Part(text: """
            You are extracting ordered receipt rows for a bill-splitting app.
            Output ONLY this exact format. No markdown, no code fences, no extra text.

            BEGIN_ROWS
            ITEM|<label>|<cents or empty>
            DISCOUNT|<label>|<cents>
            TAX|<label>|<cents>
            TIP|<label>|<cents>
            FEE|<label>|<cents>
            UNKNOWN|<label>|<cents or empty>
            END_ROWS

            Rules:
            - Output one row for each priced or important receipt row, preserving receipt order.
            - Use ITEM for purchasable line items.
            - Use DISCOUNT for any printed discount / promo / coupon / reward / comp row.
            - If the printed amount has a leading or trailing minus sign, classify the row as DISCOUNT, not ITEM.
            - Use TAX, TIP, and FEE for printed footer rows of those types.
            - Use UNKNOWN when the row matters but the type is unclear.
            - Rewrite labels to be concise and readable. Example: 93EJ BCN BGR #29A -> Bacon Burger.
            - cents must be the most likely locally-correct amount for that row, in integer cents.
            - Only fix obvious OCR noise locally, such as misplaced spaces or characters in the amount. Do not use receipt-wide math.
            - If a row has no readable amount, leave cents empty.
            - Decimal plausibility: if an item price appears unreasonably large for a single dish or product (e.g., $500+ at a restaurant, $50+ at a grocery or convenience store), it likely has a misplaced decimal point or the receipt total was merged onto the item line by OCR. Output the most plausible corrected value (e.g., OCR "5176" for a $51.76 duck dish → output 5176, not 517600).
            - Exhaustiveness: include every row that represents a distinct purchasable product or charge, even when the item name is garbled, missing, or unreadable. Use "Unknown Item" as the label rather than omitting the row. Only skip a small amount if it is explicitly labeled as a per-item surcharge (e.g., "CRV", "Bottle Dep") — otherwise include it as a separate ITEM or FEE row.
            - Suggested tips: do NOT output a TIP row for printed suggested/calculated tip amounts (e.g., "Suggested 18%: $23.75", "20%: (Tip $26.39)", "Tip percentages are based on..."). Only output TIP if the receipt shows a specific gratuity the customer actually paid — typically a single line labeled "Tip", "Gratuity", or "Service Charge" with an amount.
            - You Pay vs. regular price: some grocery receipts show both a regular "Price" column and a lower "You Pay" / sale price column. Always use the "You Pay" / final discounted price, not the higher regular price. When using the "You Pay" price, do NOT also output a separate DISCOUNT row for the savings — the discount is already reflected in the "You Pay" price.
            - Never output Subtotal, Sub Total, or Grand Total as an ITEM row. Never output the receipt's overall Total as an ITEM row unless a subtotal clearly shows the items don't add up to it (i.e., it represents something purchasable). If a price amount matches or nearly matches the receipt's known total or subtotal, it is almost certainly not an individual item price.
            - Split-line prices: some receipts show an item with $0.00 and its real price on the next line (or vice versa). Assign the non-zero price to the item rather than outputting $0.00. Similarly, if a standalone price line follows an item with no price, it belongs to that item.
            - Footer exclusion: Do NOT output rows for Total, Cash, Change, Balance Due, Amount Tendered, or Payment lines. These are transaction summary lines, not purchasable items or charges.
            \(rescueInstructions)
            """)]),
            generationConfig: .init(
                maxOutputTokens: maxTokensPrimary,
                responseMimeType: nil,
                temperature: 0,
                thinkingConfig: .init(thinkingBudget: -1)
            )
        )

        let (text, _, _, _) = try await send(req)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiReceiptAnalyzerError.emptyText
        }
        return text
    }

    private func decodeAndResolvePhase2(from text: String, knownTotalCents: Int) -> ResolvedPhase2? {
        guard let rows = tryDecodePhase2Rows(from: text) else { return nil }
        return resolveExtractedRows(rows, knownTotalCents: knownTotalCents)
    }

    private func phase2RescueReason(primaryResponse: String, knownTotalCents: Int) -> String {
        guard let resolved = decodeAndResolvePhase2(from: primaryResponse, knownTotalCents: knownTotalCents) else {
            return "the response did not follow the required BEGIN_ROWS/END_ROWS protocol"
        }

        let itemCount = resolved.phase2.items.count
        let lineItemCount = resolved.lineItems.count
        let pricedRowCount = resolved.phase2.items.filter { $0.cents != nil }.count + lineItemCount
        let accountedTotal = computedAccountedTotal(for: resolved)
        let missingBy = max(0, knownTotalCents - accountedTotal)
        let excessBy = max(0, accountedTotal - knownTotalCents)

        if pricedRowCount == 0 {
            return "the response contained no usable priced rows"
        }
        if itemCount == 0 && lineItemCount <= 2 && knownTotalCents >= 1000 {
            return "the response found footer rows but missed the purchasable body items"
        }
        // Over-accounting by 1.9× or more usually means a decimal-point OCR error or the receipt total was merged onto an item line.
        if knownTotalCents >= 500 && Double(accountedTotal) > Double(knownTotalCents) * 1.9 {
            return "the response heavily over-accounted the receipt (computed \(accountedTotal) cents vs known \(knownTotalCents) cents) — one or more item prices likely has a misplaced decimal point (e.g., OCR read $5176.00 but the correct price is $51.76), or the receipt subtotal/total was mistakenly merged onto the last item's price by OCR"
        }
        if missingBy > max(1500, Int(Double(knownTotalCents) * 0.4)) {
            return "the response under-accounted the receipt by \(missingBy) cents and likely missed several rows"
        }
        // Large gap in either direction without a clear cause
        if knownTotalCents >= 1000 && excessBy > Int(Double(knownTotalCents) * 0.4) {
            return "the response over-accounted the receipt by \(excessBy) cents — check for duplicate rows or decimal errors in item prices"
        }
        let unpricedCount = resolved.phase2.items.filter { $0.cents == nil }.count
        if unpricedCount >= 3 {
            return "the response left \(unpricedCount) items without prices — look more carefully at the transcript for dollar amounts near those item names, even if the amounts appear on adjacent lines or in a separate column"
        }
        return "the response was too sparse and likely omitted visible priced rows"
    }

    private func shouldRescuePhase2(_ resolved: ResolvedPhase2, knownTotalCents: Int) -> Bool {
        let itemCount = resolved.phase2.items.count
        let lineItemCount = resolved.lineItems.count
        let pricedRowCount = resolved.phase2.items.filter { $0.cents != nil }.count + lineItemCount
        let accountedTotal = computedAccountedTotal(for: resolved)
        let totalGap = abs(knownTotalCents - accountedTotal)

        if pricedRowCount == 0 {
            return true
        }
        if knownTotalCents >= 1000 && pricedRowCount <= 1 {
            return true
        }
        if knownTotalCents >= 1000 && itemCount == 0 && lineItemCount <= 2 {
            return true
        }
        if totalGap > max(1500, Int(Double(knownTotalCents) * 0.4)) && pricedRowCount <= 4 {
            return true
        }
        // Over-accounting by 1.9× or more almost always means a decimal-point error or total merged onto item — rescue
        if knownTotalCents >= 500 && Double(accountedTotal) > Double(knownTotalCents) * 1.9 {
            return true
        }
        // Large gap (>50%) regardless of row count — the rows we have are likely wrong
        if knownTotalCents >= 1000 && Double(totalGap) / Double(knownTotalCents) > 0.5 && pricedRowCount <= 8 {
            return true
        }
        // Many unpriced items with a meaningful gap — the LLM missed prices it should have found
        let unpricedCount = resolved.phase2.items.filter { $0.cents == nil }.count
        if unpricedCount >= 3 && totalGap > max(500, Int(Double(knownTotalCents) * 0.05)) {
            return true
        }
        return false
    }

    private func computedAccountedTotal(for resolved: ResolvedPhase2) -> Int {
        let itemTotal = resolved.phase2.items.reduce(0) { partial, item in
            partial + max(0, item.cents ?? 0)
        }
        let lineItemTotal = resolved.lineItems.reduce(0) { $0 + $1.cents }
        return itemTotal + lineItemTotal
    }

    private struct ExtractedRow {
        enum Kind: String {
            case item = "ITEM"
            case discount = "DISCOUNT"
            case tax = "TAX"
            case tip = "TIP"
            case fee = "FEE"
            case unknown = "UNKNOWN"

            init?(tag: String) {
                self.init(rawValue: tag.uppercased())
            }
        }

        let kind: Kind
        let label: String
        let cents: Int?
        let index: Int
    }

    private enum DiscountResolutionMode: Equatable {
        case billWide
        case attachToPreviousItem(itemIndex: Int)
        case ignore
    }

    private struct ResolvedPhase2 {
        let phase2: Phase2Result
        let lineItems: [OCRLineItem]
    }

    private func tryDecodePhase2Rows(from text: String) -> [ExtractedRow]? {
        let cleaned = text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.contains("BEGIN_ROWS") else { return nil }

        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func parseOptionalInt(_ raw: String) -> Int? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return Int(trimmed)
        }

        var rows: [ExtractedRow] = []
        var inBlock = false

        for line in lines {
            if line == "BEGIN_ROWS" {
                inBlock = true
                continue
            }
            if line == "END_ROWS" {
                break
            }
            guard inBlock else { continue }

            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let kind = ExtractedRow.Kind(tag: parts[0]) else { continue }

            var label = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let cents = parseOptionalInt(parts[2])
            if label.isEmpty {
                // Only keep empty-label rows for discounts and items — these are worth
                // preserving even without a name. Tax/tip/fee with no label are likely
                // misclassified rows (e.g., a grocery item tagged as TAX).
                if kind == .discount || kind == .item {
                    label = kind.rawValue.capitalized
                } else {
                    continue
                }
            }

            rows.append(.init(kind: kind, label: label, cents: cents, index: rows.count))
        }

        return rows.isEmpty ? nil : rows
    }

    private func resolveExtractedRows(_ rows: [ExtractedRow], knownTotalCents: Int) -> ResolvedPhase2 {
        struct DiscountCandidate {
            let row: ExtractedRow
            let previousItemIndex: Int?
        }

        struct ResolutionState {
            let items: [Phase2Result.Item]
            let taxCents: Int
            let tipCents: Int
            let feesCents: Int
            let discountCents: Int
            let issues: [String]
            let discountModes: [Int: DiscountResolutionMode]
            let score: Int
        }

        let cleanedRows = rows.map { row -> ExtractedRow in
            if row.kind == .discount, let cents = row.cents, cents > 0 {
                return .init(kind: row.kind, label: row.label, cents: -cents, index: row.index)
            }
            return row
        }

        var baseItems: [Phase2Result.Item] = []
        var taxCents = 0
        var tipCents = 0
        var feesCents = 0
        let discountCents = 0
        var issues: [String] = []
        var discountCandidates: [DiscountCandidate] = []
        var lastItemIndex: Int? = nil

        for row in cleanedRows {
            switch row.kind {
            case .item:
                baseItems.append(.init(label: row.label, qty: 1, cents: row.cents))
                lastItemIndex = baseItems.count - 1
            case .tax:
                if let cents = row.cents {
                    taxCents += cents
                } else {
                    issues.append("Missing amount for tax row: \(row.label)")
                }
            case .tip:
                if let cents = row.cents {
                    tipCents += cents
                } else {
                    issues.append("Missing amount for tip row: \(row.label)")
                }
            case .fee:
                if let cents = row.cents {
                    feesCents += cents
                } else {
                    issues.append("Missing amount for fee row: \(row.label)")
                }
            case .discount:
                discountCandidates.append(.init(row: row, previousItemIndex: lastItemIndex))
            case .unknown:
                break
            }
        }

        func apply(_ candidate: DiscountCandidate, mode: DiscountResolutionMode, to state: ResolutionState) -> ResolutionState {
            var nextItems = state.items
            var nextDiscount = state.discountCents
            var nextIssues = state.issues
            var nextModes = state.discountModes
            var nextScore = state.score

            switch mode {
            case .billWide:
                if let cents = candidate.row.cents {
                    nextDiscount += abs(cents)
                    nextModes[candidate.row.index] = mode
                } else {
                    nextIssues.append("Missing amount for discount row: \(candidate.row.label)")
                    nextScore += 200
                }
                nextScore += 2
            case .attachToPreviousItem(let itemIndex):
                guard itemIndex >= 0, itemIndex < nextItems.count else {
                    nextIssues.append("Discount could not attach to previous item: \(candidate.row.label)")
                    nextScore += 500
                    return ResolutionState(items: nextItems, taxCents: state.taxCents, tipCents: state.tipCents, feesCents: state.feesCents, discountCents: nextDiscount, issues: nextIssues, discountModes: nextModes, score: nextScore)
                }
                guard let cents = candidate.row.cents else {
                    nextIssues.append("Missing amount for discount row: \(candidate.row.label)")
                    nextScore += 200
                    return ResolutionState(items: nextItems, taxCents: state.taxCents, tipCents: state.tipCents, feesCents: state.feesCents, discountCents: nextDiscount, issues: nextIssues, discountModes: nextModes, score: nextScore)
                }

                let current = nextItems[itemIndex]
                let updatedCents = (current.cents ?? 0) + cents
                nextItems[itemIndex] = .init(label: current.label, qty: current.qty, cents: updatedCents)
                nextModes[candidate.row.index] = mode
                if updatedCents < 0 {
                    nextScore += 1000 + abs(updatedCents)
                    nextIssues.append("Discount drove item below zero: \(candidate.row.label)")
                }
            case .ignore:
                nextIssues.append("Ignored discount row: \(candidate.row.label)")
                nextModes[candidate.row.index] = mode
                nextScore += candidate.previousItemIndex == nil ? 30 : 20
            }

            return ResolutionState(items: nextItems, taxCents: state.taxCents, tipCents: state.tipCents, feesCents: state.feesCents, discountCents: nextDiscount, issues: nextIssues, discountModes: nextModes, score: nextScore)
        }

        func resolveDiscounts(_ index: Int, state: ResolutionState) -> ResolutionState {
            guard index < discountCandidates.count else { return state }
            let candidate = discountCandidates[index]
            var modes: [DiscountResolutionMode] = [.billWide, .ignore]
            if let previousItemIndex = candidate.previousItemIndex {
                modes.insert(.attachToPreviousItem(itemIndex: previousItemIndex), at: 0)
            }

            var bestState: ResolutionState?
            var bestDiff: Int?

            for mode in modes {
                let next = apply(candidate, mode: mode, to: state)
                let resolved = resolveDiscounts(index + 1, state: next)
                let itemsTotal = resolved.items.reduce(0) { $0 + max(0, $1.cents ?? 0) }
                let diff = abs(knownTotalCents - (itemsTotal + resolved.taxCents + resolved.tipCents + resolved.feesCents - resolved.discountCents))

                if let currentBestDiff = bestDiff, let currentBest = bestState {
                    if diff < currentBestDiff || (diff == currentBestDiff && resolved.score < currentBest.score) {
                        bestDiff = diff
                        bestState = resolved
                    }
                } else {
                    bestDiff = diff
                    bestState = resolved
                }
            }

            return bestState ?? state
        }

        let initial = ResolutionState(
            items: baseItems,
            taxCents: taxCents,
            tipCents: tipCents,
            feesCents: feesCents,
            discountCents: discountCents,
            issues: issues,
            discountModes: [:],
            score: 0
        )

        let resolved = resolveDiscounts(0, state: initial)

        // Post-resolution fix: if one item's price is suspiciously close to knownTotal or the
        // items-only subtotal (suggesting OCR merged the receipt total onto that item line),
        // remove that item's price so it doesn't blow up the total.
        var correctedItems = resolved.items
        if knownTotalCents > 0 {
            let itemsTotal = correctedItems.reduce(0) { $0 + max(0, $1.cents ?? 0) }
            let overhead = resolved.taxCents + resolved.tipCents + resolved.feesCents - resolved.discountCents
            let expectedItemsTotal = knownTotalCents - overhead
            if itemsTotal > 0 && expectedItemsTotal > 0 {
                let currentGap = abs(itemsTotal - expectedItemsTotal)
                if currentGap > 1000 {
                    for i in correctedItems.indices {
                        guard let cents = correctedItems[i].cents, cents > 0 else { continue }
                        let otherItemsTotal = itemsTotal - cents
                        let gapWithout = abs(otherItemsTotal - expectedItemsTotal)
                        if Double(cents) >= Double(knownTotalCents) * 0.8
                            && gapWithout < currentGap {
                            correctedItems[i] = .init(label: correctedItems[i].label, qty: correctedItems[i].qty, cents: nil)
                            break
                        }
                    }
                }
            }
        }

        // Post-resolution fix: if items overshoot the expected total and there are items with
        // duplicate prices, OCR likely read the same price column twice. Greedily remove
        // duplicate-priced items while it improves reconciliation.
        if knownTotalCents > 0 {
            let overhead = resolved.taxCents + resolved.tipCents + resolved.feesCents - resolved.discountCents
            let expectedItemsTotal = knownTotalCents - overhead
            var itemsTotal = correctedItems.reduce(0) { $0 + max(0, $1.cents ?? 0) }
            if itemsTotal > expectedItemsTotal && expectedItemsTotal > 0 {
                var seenPrices: [Int: Int] = [:]  // price -> first index
                for i in correctedItems.indices {
                    guard let cents = correctedItems[i].cents, cents > 0 else { continue }
                    if let _ = seenPrices[cents] {
                        // Duplicate price — check if removing it helps
                        let newTotal = itemsTotal - cents
                        if abs(newTotal - expectedItemsTotal) < abs(itemsTotal - expectedItemsTotal) {
                            correctedItems[i] = .init(label: correctedItems[i].label, qty: correctedItems[i].qty, cents: nil)
                            itemsTotal = newTotal
                        }
                    } else {
                        seenPrices[cents] = i
                    }
                }
            }
        }

        let filteredItems = correctedItems.filter { item in
            guard let cents = item.cents else { return true }
            return cents != 0
        }

        // If items (+ fees) already sum exactly to knownTotal, the remaining tax/tip/discount
        // rows are likely misclassified footer lines (total, cash, change) — zero them out.
        let itemsSumAfterCorrection = filteredItems.reduce(0) { $0 + max(0, $1.cents ?? 0) }
        let overhead = resolved.taxCents + resolved.tipCents + resolved.feesCents - resolved.discountCents
        var finalTaxCents = resolved.taxCents
        var finalTipCents = resolved.tipCents
        var finalFeesCents = resolved.feesCents
        var finalDiscountCents = resolved.discountCents
        if overhead != 0 && itemsSumAfterCorrection == knownTotalCents {
            // Items alone match total — tax/tip/fees/discount are all noise
            finalTaxCents = 0
            finalTipCents = 0
            finalFeesCents = 0
            finalDiscountCents = 0
        } else if (itemsSumAfterCorrection + finalFeesCents) == knownTotalCents && (resolved.taxCents != 0 || resolved.tipCents != 0 || resolved.discountCents != 0) {
            // Items + fees match total — tax/tip/discount are noise
            finalTaxCents = 0
            finalTipCents = 0
            finalDiscountCents = 0
        }

        // Tip flexibility: delivery apps show Total pre-tip, restaurants post-tip.
        // Test both and pick the one that reconciles better with knownTotal.
        if finalTipCents > 0 {
            let totalWithTip = itemsSumAfterCorrection + finalTaxCents + finalTipCents + finalFeesCents - finalDiscountCents
            let totalWithoutTip = itemsSumAfterCorrection + finalTaxCents + finalFeesCents - finalDiscountCents
            if abs(totalWithoutTip - knownTotalCents) < abs(totalWithTip - knownTotalCents) {
                finalTipCents = 0
            }
        }

        let derivedSubtotal = knownTotalCents - finalTaxCents - finalTipCents - finalFeesCents + finalDiscountCents
        let subtotal = max(0, derivedSubtotal)

        var finalIssues = resolved.issues
        if derivedSubtotal < 0 {
            finalIssues.append("Derived subtotal was negative; clamped to zero")
        }

        let resolvedTotal = filteredItems.reduce(0) { $0 + max(0, $1.cents ?? 0) } + finalTaxCents + finalTipCents + finalFeesCents - finalDiscountCents
        if resolvedTotal != knownTotalCents {
            finalIssues.append("Resolved rows differ from known total by \(abs(knownTotalCents - resolvedTotal)) cents")
        }

        let finalLineItems: [OCRLineItem] = cleanedRows.compactMap { row -> OCRLineItem? in
            switch row.kind {
            case .tax:
                guard finalTaxCents > 0, let cents = row.cents else { return nil }
                return .init(label: row.label, cents: cents)
            case .tip:
                guard finalTipCents > 0, let cents = row.cents else { return nil }
                return .init(label: row.label, cents: cents)
            case .fee:
                guard finalFeesCents > 0, let cents = row.cents else { return nil }
                return .init(label: row.label, cents: cents)
            case .discount:
                guard finalDiscountCents > 0, case .billWide? = resolved.discountModes[row.index], let cents = row.cents else { return nil }
                return .init(label: row.label, cents: cents)
            case .item, .unknown:
                return nil
            }
        }

        return ResolvedPhase2(
            phase2: Phase2Result(
                subtotal_cents: subtotal,
                tax_cents: finalTaxCents == 0 ? nil : finalTaxCents,
                tip_cents: finalTipCents == 0 ? nil : finalTipCents,
                fees_cents: finalFeesCents == 0 ? nil : finalFeesCents,
                discount_cents: finalDiscountCents == 0 ? nil : finalDiscountCents,
                items: filteredItems,
                issues: finalIssues
            ),
            lineItems: finalLineItems
        )
    }

    private func extractTotalCentsFallback(from text: String) -> Int? {
        // Look for total_cents or total in the text
        let patterns = [
            try? NSRegularExpression(pattern: "\"total_cents\"\\s*:\\s*(\\d+)"),
            try? NSRegularExpression(pattern: "\\$(\\d+\\.\\d{2})")
        ]
        for pattern in patterns.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = pattern.firstMatch(in: text, range: range),
               let group = Range(match.range(at: 1), in: text) {
                let value = String(text[group])
                if value.contains(".") {
                    if let dollars = Double(value) { return Int(dollars * 100) }
                } else {
                    return Int(value)
                }
            }
        }
        return nil
    }

    private func extractMerchantFallback(from text: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: "\"merchant\"\\s*:\\s*\"([^\"]+)\"")
        let range = NSRange(text.startIndex..., in: text)
        if let pattern, let match = pattern.firstMatch(in: text, range: range),
           let group = Range(match.range(at: 1), in: text) {
            return String(text[group])
        }
        return nil
    }

    private func extractJSON(from text: String) -> String {
        // Find the first { ... } block in the text
        guard let openBrace = text.firstIndex(of: "{"),
              let closeBrace = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[openBrace...closeBrace])
    }

    private func repairJSON(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"}", with: "}")
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ req: GenerateContentRequest) async throws -> (text: String, rawJSON: String?, status: Int, finishReasons: [String]) {
        let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")!
        var attempt = 0

        while true {
            attempt += 1

            do {
                var request = URLRequest(url: baseURL)
                request.httpMethod = "POST"
                request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(req)

                let (data, resp) = try await session.data(for: request)
                guard let http = resp as? HTTPURLResponse else {
                    throw GeminiReceiptAnalyzerError.badResponse(status: -1, body: "No HTTPURLResponse")
                }
                let status = http.statusCode
                let raw = String(data: data, encoding: .utf8)

                if !(200..<300).contains(status) {
                    let error = GeminiReceiptAnalyzerError.badResponse(status: status, body: raw)
                    guard shouldRetry(status: status) else {
                        throw error
                    }

                    let delay = retryDelaySeconds(forAttempt: attempt)
                    fputs("[ocrbench] Gemini transient HTTP \(status). Retrying in \(String(format: "%.1f", delay))s (attempt \(attempt)).\n", stderr)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }

                let decoded: GenerateContentResponse
                do {
                    decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
                } catch {
                    throw GeminiReceiptAnalyzerError.decodeFailed
                }
                let candidates = decoded.candidates ?? []
                let parts = candidates.first?.content?.parts ?? []
                let text = parts.compactMap { $0.text }.joined()
                let reasons = candidates.compactMap { $0.finishReason }
                return (text, raw, status, reasons)
            } catch let error as GeminiReceiptAnalyzerError {
                if case let .badResponse(status, _) = error, shouldRetry(status: status) {
                    let delay = retryDelaySeconds(forAttempt: attempt)
                    fputs("[ocrbench] Gemini transient failure. Retrying in \(String(format: "%.1f", delay))s (attempt \(attempt)).\n", stderr)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            } catch {
                let delay = retryDelaySeconds(forAttempt: attempt)
                fputs("[ocrbench] Gemini transport failure: \(error). Retrying in \(String(format: "%.1f", delay))s (attempt \(attempt)).\n", stderr)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
        }
    }

    private func shouldRetry(status: Int) -> Bool {
        retryableStatusCodes.contains(status)
    }

    private func retryDelaySeconds(forAttempt attempt: Int) -> Double {
        let cappedAttempt = min(attempt, 8)
        let base = pow(2.0, Double(cappedAttempt - 1))
        let jitter = Double.random(in: 0...0.75)
        return min(base + jitter, 60.0)
    }
}
