import Foundation

public protocol ReceiptOCRWorkflowing {
    var variantID: String { get }
    func runPhase1(
        image: ReceiptImage,
        prefetchedTranscriptTask: Task<String, Error>?
    ) async throws -> ReceiptOCRPhase1Output
    func runPhase2(
        transcript: String,
        knownTotalCents: Int,
        priorTimings: ReceiptOCRTimingMarks
    ) async throws -> ReceiptOCRPhase2Output
    func run(
        image: ReceiptImage,
        prefetchedTranscriptTask: Task<String, Error>?
    ) async throws -> ReceiptOCRWorkflowResult
}

public protocol ReceiptTranscriptGenerating {
    func generate(from image: ReceiptImage) async throws -> String
}

public protocol ReceiptLLMAnalyzing {
    func analyzePhase1(transcript: String) async throws -> Phase1Result
    func analyzePhase2(transcript: String, knownTotalCents: Int) async throws -> (phase2: Phase2Result, lineItems: [OCRLineItem], rawResponse: String?)
}

public struct ReceiptOCRWorkflow: ReceiptOCRWorkflowing {
    public let variantID: String
    public let transcriptGenerator: any ReceiptTranscriptGenerating
    public let analyzer: any ReceiptLLMAnalyzing

    public init(
        variantID: String = "current",
        transcriptGenerator: any ReceiptTranscriptGenerating,
        analyzer: any ReceiptLLMAnalyzing
    ) {
        self.variantID = variantID
        self.transcriptGenerator = transcriptGenerator
        self.analyzer = analyzer
    }

    public func runPhase1(
        image: ReceiptImage,
        prefetchedTranscriptTask: Task<String, Error>? = nil
    ) async throws -> ReceiptOCRPhase1Output {
        let workflowStartedAt = Date()
        let transcriptStartedAt = Date()

        let transcript: String
        let usedPrefetchedTranscript = prefetchedTranscriptTask != nil
        if let prefetchedTranscriptTask {
            transcript = try await prefetchedTranscriptTask.value
        } else {
            transcript = try await transcriptGenerator.generate(from: image)
        }

        let transcriptCompletedAt = Date()
        let phase1StartedAt = Date()
        let phase1 = try await analyzer.analyzePhase1(transcript: transcript)
        let phase1CompletedAt = Date()

        let timings = ReceiptOCRTimingMarks(
            workflowStartedAt: workflowStartedAt,
            transcriptStartedAt: transcriptStartedAt,
            transcriptCompletedAt: transcriptCompletedAt,
            phase1StartedAt: phase1StartedAt,
            phase1CompletedAt: phase1CompletedAt,
            phase2StartedAt: nil,
            phase2CompletedAt: nil,
            usedPrefetchedTranscript: usedPrefetchedTranscript
        )

        return ReceiptOCRPhase1Output(transcript: transcript, phase1: phase1, timings: timings)
    }

    public func runPhase2(
        transcript: String,
        knownTotalCents: Int,
        priorTimings: ReceiptOCRTimingMarks
    ) async throws -> ReceiptOCRPhase2Output {
        let phase2StartedAt = Date()
        let response = try await analyzer.analyzePhase2(transcript: transcript, knownTotalCents: knownTotalCents)
        let phase2CompletedAt = Date()

        let timings = ReceiptOCRTimingMarks(
            workflowStartedAt: priorTimings.workflowStartedAt,
            transcriptStartedAt: priorTimings.transcriptStartedAt,
            transcriptCompletedAt: priorTimings.transcriptCompletedAt,
            phase1StartedAt: priorTimings.phase1StartedAt,
            phase1CompletedAt: priorTimings.phase1CompletedAt,
            phase2StartedAt: phase2StartedAt,
            phase2CompletedAt: phase2CompletedAt,
            usedPrefetchedTranscript: priorTimings.usedPrefetchedTranscript
        )

        return ReceiptOCRPhase2Output(
            phase2: response.phase2,
            lineItems: response.lineItems,
            rawResponse: response.rawResponse,
            timings: timings
        )
    }

    public func run(
        image: ReceiptImage,
        prefetchedTranscriptTask: Task<String, Error>? = nil
    ) async throws -> ReceiptOCRWorkflowResult {
        let phase1Output = try await runPhase1(image: image, prefetchedTranscriptTask: prefetchedTranscriptTask)
        let knownTotalCents = max(0, phase1Output.phase1.total_cents ?? 0)
        let phase2Output = try await runPhase2(
            transcript: phase1Output.transcript,
            knownTotalCents: knownTotalCents,
            priorTimings: phase1Output.timings
        )
        return ReceiptOCRWorkflowResult(phase1: phase1Output, phase2: phase2Output)
    }
}
