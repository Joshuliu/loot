import Foundation
import OCRCore

@main
struct OCRBenchCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                printUsage()
                return
            }

            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let paths = ReceiptOCRBenchmarkPaths(
                receiptsFolder: URL(fileURLWithPath: "/Users/joshuliu/Documents/Receipts", isDirectory: true),
                fixturesRoot: repoRoot.appendingPathComponent("OCRBenchmarks/Fixtures", isDirectory: true),
                runsRoot: repoRoot.appendingPathComponent("OCRBenchmarks/Runs", isDirectory: true)
            )

            let analyzer = try GeminiReceiptAnalyzer(configuration: .fromEnvironment())
            let workflow = ReceiptOCRWorkflow(
                variantID: "current",
                transcriptGenerator: VisionReceiptTranscriptGenerator(),
                analyzer: analyzer
            )
            let runner = ReceiptOCRBenchmarkRunner()

            switch command {
            case "list":
                let cases = try runner.discoverCases(paths: paths)
                for benchmarkCase in cases {
                    print("\(benchmarkCase.id)\t\(benchmarkCase.imageURL.lastPathComponent)")
                }
            case "bootstrap":
                let overwrite = arguments.contains("--overwrite-expected")
                let written = try await runner.bootstrapExpectedFixtures(using: workflow, paths: paths, overwriteExpected: overwrite)
                print("Wrote \(written.count) expected fixture(s)")
            case "run":
                let runID = value(after: "--run-id", in: arguments) ?? "latest"
                let noResume = arguments.contains("--no-resume")
                let stopOnError = arguments.contains("--stop-on-error")
                let summaries = try await runner.runSuite(
                    workflows: [workflow],
                    paths: paths,
                    options: .init(
                        runID: runID,
                        resumeExistingResults: !noResume,
                        continueOnCaseError: !stopOnError
                    )
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(summaries)
                if let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
            default:
                printUsage()
            }
        } catch {
            fputs("ocrbench error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        let text = """
        Usage:
          swift run ocrbench list
          swift run ocrbench bootstrap [--overwrite-expected]
          swift run ocrbench run [--run-id ID] [--no-resume] [--stop-on-error]

        Required environment:
          GEMINI_API_KEY
        """
        print(text)
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
