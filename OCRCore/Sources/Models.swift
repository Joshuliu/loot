import Foundation
import CoreGraphics

public struct Phase1Result: Codable, Sendable {
    public let merchant: String?
    public let total_cents: Int?

    public init(merchant: String?, total_cents: Int?) {
        self.merchant = merchant
        self.total_cents = total_cents
    }
}

public struct Phase2Result: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case subtotal_cents
        case tax_cents
        case tip_cents
        case fees_cents
        case discount_cents
        case items
        case issues
    }

    public struct Item: Codable, Sendable {
        public let label: String
        public let qty: Int
        public let cents: Int?

        public init(label: String, qty: Int, cents: Int?) {
            self.label = label
            self.qty = qty
            self.cents = cents
        }
    }

    public let subtotal_cents: Int?
    public let tax_cents: Int?
    public let tip_cents: Int?
    public let fees_cents: Int?
    public let discount_cents: Int?
    public let items: [Item]
    public let issues: [String]

    public init(
        subtotal_cents: Int?,
        tax_cents: Int?,
        tip_cents: Int?,
        fees_cents: Int?,
        discount_cents: Int?,
        items: [Item],
        issues: [String]
    ) {
        self.subtotal_cents = subtotal_cents
        self.tax_cents = tax_cents
        self.tip_cents = tip_cents
        self.fees_cents = fees_cents
        self.discount_cents = discount_cents
        self.items = items
        self.issues = issues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtotal_cents = try container.decodeIfPresent(Int.self, forKey: .subtotal_cents)
        tax_cents = try container.decodeIfPresent(Int.self, forKey: .tax_cents)
        tip_cents = try container.decodeIfPresent(Int.self, forKey: .tip_cents)
        fees_cents = try container.decodeIfPresent(Int.self, forKey: .fees_cents)
        discount_cents = try container.decodeIfPresent(Int.self, forKey: .discount_cents)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        issues = try container.decodeIfPresent([String].self, forKey: .issues) ?? []
    }
}

public struct OCRLineItem: Codable, Sendable {
    public let label: String
    public let cents: Int

    public init(label: String, cents: Int) {
        self.label = label
        self.cents = cents
    }
}

public struct ReceiptOCRTimingMarks: Codable, Sendable {
    public let workflowStartedAt: Date
    public let transcriptStartedAt: Date
    public let transcriptCompletedAt: Date
    public let phase1StartedAt: Date
    public let phase1CompletedAt: Date
    public let phase2StartedAt: Date?
    public let phase2CompletedAt: Date?
    public let usedPrefetchedTranscript: Bool

    public var transcriptDuration: TimeInterval {
        transcriptCompletedAt.timeIntervalSince(transcriptStartedAt)
    }

    public var transcriptToPhase1Duration: TimeInterval {
        phase1CompletedAt.timeIntervalSince(transcriptCompletedAt)
    }

    public var phase1Duration: TimeInterval {
        phase1CompletedAt.timeIntervalSince(phase1StartedAt)
    }

    public var phase2Duration: TimeInterval? {
        guard let phase2StartedAt, let phase2CompletedAt else { return nil }
        return phase2CompletedAt.timeIntervalSince(phase2StartedAt)
    }

    public var transcriptToPhase2Duration: TimeInterval? {
        guard let phase2CompletedAt else { return nil }
        return phase2CompletedAt.timeIntervalSince(transcriptCompletedAt)
    }

    public var totalWorkflowDuration: TimeInterval? {
        if let phase2CompletedAt {
            return phase2CompletedAt.timeIntervalSince(workflowStartedAt)
        }
        return phase1CompletedAt.timeIntervalSince(workflowStartedAt)
    }
}

public struct ReceiptOCRPhase1Output: Sendable {
    public let transcript: String
    public let phase1: Phase1Result
    public let timings: ReceiptOCRTimingMarks

    public init(transcript: String, phase1: Phase1Result, timings: ReceiptOCRTimingMarks) {
        self.transcript = transcript
        self.phase1 = phase1
        self.timings = timings
    }
}

public struct ReceiptOCRPhase2Output: Sendable {
    public let phase2: Phase2Result
    public let lineItems: [OCRLineItem]
    public let rawResponse: String?
    public let timings: ReceiptOCRTimingMarks

    public init(phase2: Phase2Result, lineItems: [OCRLineItem], rawResponse: String?, timings: ReceiptOCRTimingMarks) {
        self.phase2 = phase2
        self.lineItems = lineItems
        self.rawResponse = rawResponse
        self.timings = timings
    }
}

public struct ReceiptOCRWorkflowResult: Sendable {
    public let phase1: ReceiptOCRPhase1Output
    public let phase2: ReceiptOCRPhase2Output

    public init(phase1: ReceiptOCRPhase1Output, phase2: ReceiptOCRPhase2Output) {
        self.phase1 = phase1
        self.phase2 = phase2
    }
}

public struct ReceiptOCRTimingSummary: Codable, Sendable {
    public let transcriptSeconds: Double
    public let phase1Seconds: Double
    public let transcriptToPhase1Seconds: Double
    public let phase2Seconds: Double?
    public let transcriptToPhase2Seconds: Double?
    public let totalWorkflowSeconds: Double?
    public let usedPrefetchedTranscript: Bool

    public init(from timings: ReceiptOCRTimingMarks) {
        transcriptSeconds = timings.transcriptDuration
        phase1Seconds = timings.phase1Duration
        transcriptToPhase1Seconds = timings.transcriptToPhase1Duration
        phase2Seconds = timings.phase2Duration
        transcriptToPhase2Seconds = timings.transcriptToPhase2Duration
        totalWorkflowSeconds = timings.totalWorkflowDuration
        usedPrefetchedTranscript = timings.usedPrefetchedTranscript
    }

    public init(
        transcriptSeconds: Double,
        phase1Seconds: Double,
        transcriptToPhase1Seconds: Double,
        phase2Seconds: Double?,
        transcriptToPhase2Seconds: Double?,
        totalWorkflowSeconds: Double?,
        usedPrefetchedTranscript: Bool
    ) {
        self.transcriptSeconds = transcriptSeconds
        self.phase1Seconds = phase1Seconds
        self.transcriptToPhase1Seconds = transcriptToPhase1Seconds
        self.phase2Seconds = phase2Seconds
        self.transcriptToPhase2Seconds = transcriptToPhase2Seconds
        self.totalWorkflowSeconds = totalWorkflowSeconds
        self.usedPrefetchedTranscript = usedPrefetchedTranscript
    }

    public static let empty = ReceiptOCRTimingSummary(
        transcriptSeconds: 0,
        phase1Seconds: 0,
        transcriptToPhase1Seconds: 0,
        phase2Seconds: nil,
        transcriptToPhase2Seconds: nil,
        totalWorkflowSeconds: nil,
        usedPrefetchedTranscript: false
    )
}

public struct ReceiptOCRBenchmarkSnapshot: Codable, Sendable {
    public let transcript: String
    public let phase1: Phase1Result
    public let phase2: Phase2Result
    public let lineItems: [OCRLineItem]
    public let rawPhase2Response: String?
    public let timings: ReceiptOCRTimingSummary

    public init(from result: ReceiptOCRWorkflowResult) {
        transcript = result.phase1.transcript
        phase1 = result.phase1.phase1
        phase2 = result.phase2.phase2
        lineItems = result.phase2.lineItems
        rawPhase2Response = result.phase2.rawResponse
        timings = ReceiptOCRTimingSummary(from: result.phase2.timings)
    }

    public init(
        transcript: String,
        phase1: Phase1Result,
        phase2: Phase2Result,
        lineItems: [OCRLineItem],
        rawPhase2Response: String?,
        timings: ReceiptOCRTimingSummary
    ) {
        self.transcript = transcript
        self.phase1 = phase1
        self.phase2 = phase2
        self.lineItems = lineItems
        self.rawPhase2Response = rawPhase2Response
        self.timings = timings
    }

    public static let empty = ReceiptOCRBenchmarkSnapshot(
        transcript: "",
        phase1: Phase1Result(merchant: nil, total_cents: nil),
        phase2: Phase2Result(
            subtotal_cents: nil,
            tax_cents: nil,
            tip_cents: nil,
            fees_cents: nil,
            discount_cents: nil,
            items: [],
            issues: []
        ),
        lineItems: [],
        rawPhase2Response: nil,
        timings: .empty
    )
}

public struct ReceiptOCRFixtureRecord: Codable, Sendable {
    public enum ReviewStatus: String, Codable, Sendable {
        case needsReview
        case reviewed
    }

    public let caseID: String
    public let sourceFilename: String
    public let variantID: String
    public let capturedAt: Date
    public var reviewStatus: ReviewStatus
    public var notes: String
    public let snapshot: ReceiptOCRBenchmarkSnapshot
}

public struct ReceiptOCRBenchmarkScore: Codable, Sendable {
    public let passesTotalReconciliation: Bool
    public let expectedTotalCents: Int?
    public let actualComputedTotalCents: Int
    public let reconciliationDifferenceCents: Int?
    public let reconciliation: Double
    public let overall: Double
    public let merchant: Double
    public let total: Double
    public let breakdown: Double
    public let itemValues: Double
    public let lineItemValues: Double
}

public struct ReceiptOCRBenchmarkCaseResult: Codable, Sendable {
    public let caseID: String
    public let sourceFilename: String
    public let variantID: String
    public let capturedAt: Date
    public let score: ReceiptOCRBenchmarkScore?
    public let snapshot: ReceiptOCRBenchmarkSnapshot
    public let expectedReviewStatus: ReceiptOCRFixtureRecord.ReviewStatus?
    public let errorDescription: String?
}

public struct ReceiptOCRBenchmarkRunSummary: Codable, Sendable {
    public let variantID: String
    public let caseCount: Int
    public let scoredCaseCount: Int
    public let passCount: Int
    public let failedCaseCount: Int
    public let averageOverallScore: Double?
    public let averageReconciliationScore: Double?
    public let averageTranscriptSeconds: Double
    public let averagePhase1Seconds: Double
    public let averagePhase2Seconds: Double?
    public let averageTotalWorkflowSeconds: Double?
}
