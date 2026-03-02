//
//  TranscriptGenerator.swift
//  VisionTest
//
//  Created by Kendrick Ng on 3/2/26.
//

import Foundation
import UIKit
import Vision

/// A standalone, memory-lean tool that accepts a UIImage and returns
/// the OCR transcript. The pipeline mirrors AnalyzeDocument's downstream
/// flow (correct → detect → group lines → chunk → OCR → join) but omits
/// ImageAnalyzer, document detection, and other heavy features that are
/// unnecessary for transcript-only output.
enum TranscriptGenerator {

    // MARK: - Public driver

    /// Accepts a UIImage and returns the joined transcript string.
    ///
    /// Pipeline:
    /// 1. Correct text skew via single-pass rotation.
    /// 2. Run OCR on the corrected image to obtain text observations.
    /// 3. Group observations into lines with Y-bound metadata.
    /// 4. Compute chunk boundaries at every 20th line with overlap.
    /// 5. Crop horizontal chunks and OCR each concurrently.
    /// 6. Trim overlap lines and join chunk transcripts.
    static func generate(from image: UIImage) async throws -> String {
        // Step 1: Straighten text so downstream OCR operates on a
        // horizontally aligned image.
        let correctedImage = DocumentRealignment.correctTextAngle(in: image)

        // Step 2: Detect all recognized text observations on the
        // full corrected image.
        let observations = try await detectTextBlocks(in: correctedImage)

        // Step 3: Group observations into lines ordered top-to-bottom.
        // Each line records its vertical extent for chunk splitting.
        let lines = buildTranscriptLines(from: observations)

        // Step 4–6: Split, crop, OCR chunks, then merge.
        let chunkTranscripts = await analyzeChunks(in: correctedImage, from: lines)
        let joined = chunkTranscripts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return joined
    }

    // MARK: - Line metadata

    /// Holds a single line's text and the vertical bounds of its
    /// constituent observations in Vision's normalized coordinate space.
    private struct TranscriptLine {
        let text: String
        let highestY: CGFloat   // max boundingBox.maxY across all observations in line
        let lowestY: CGFloat    // min boundingBox.minY across all observations in line
    }

    /// Groups recognized text observations into reading-order lines.
    ///
    /// Algorithm:
    /// 1. Sort observations top-to-bottom (descending midY), left-to-right.
    /// 2. For each unvisited observation ("anchor"), collect all unvisited
    ///    observations whose vertical overlap with the anchor is ≥ 60% of
    ///    the anchor's height — these belong to the same line.
    /// 3. Sort line members left-to-right and join their top candidates
    ///    with spaces.
    /// 4. Record each line's highest and lowest Y for chunk split decisions.
    private static func buildTranscriptLines(from observations: [VNRecognizedTextObservation]) -> [TranscriptLine] {
        let sortedObservations = observations.sorted { lhs, rhs in
            let lhsY = lhs.boundingBox.midY
            let rhsY = rhs.boundingBox.midY
            if abs(lhsY - rhsY) > 0.001 {
                return lhsY > rhsY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var usedIndices = Set<Int>()
        var lines: [TranscriptLine] = []

        for anchorIndex in sortedObservations.indices {
            guard !usedIndices.contains(anchorIndex) else { continue }

            let anchor = sortedObservations[anchorIndex]
            var lineObservations: [VNRecognizedTextObservation] = [anchor]
            usedIndices.insert(anchorIndex)

            // Merge observations on the same visual line.
            for candidateIndex in sortedObservations.indices
                where candidateIndex > anchorIndex && !usedIndices.contains(candidateIndex) {
                let candidate = sortedObservations[candidateIndex]
                if verticalOverlapRatio(of: anchor.boundingBox, with: candidate.boundingBox) >= 0.6 {
                    lineObservations.append(candidate)
                    usedIndices.insert(candidateIndex)
                }
            }

            // Left-to-right reading order within the line.
            let ordered = lineObservations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let texts = ordered
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !texts.isEmpty {
                lines.append(TranscriptLine(
                    text: texts.joined(separator: " "),
                    highestY: ordered.map(\.boundingBox.maxY).max() ?? 0,
                    lowestY: ordered.map(\.boundingBox.minY).min() ?? 0
                ))
            }
        }

        return lines
    }

    // MARK: - Chunking

    /// Computes normalized crop rects that split the image at every 20th
    /// line with one-line overlap on each side.
    ///
    /// - Current chunk extends down to line 21's lower Y bound.
    /// - Next chunk starts at line 20's upper Y bound.
    /// - Transcript trimming later removes the duplicated boundary lines.
    private static func chunkBounds(from lines: [TranscriptLine], margin: CGFloat = 0.000) -> [CGRect] {
        guard !lines.isEmpty else { return [] }

        let splitLineIndices = stride(from: 19, to: lines.count, by: 20)
        var chunkRects: [CGRect] = []
        var chunkTopY: CGFloat = 1.0

        for splitIndex in splitLineIndices {
            let extendedIndex = min(splitIndex + 1, lines.count - 1)
            let chunkBottomY = max(0, min(1, lines[extendedIndex].lowestY - margin))
            let clampedTopY = max(0, min(1, chunkTopY))

            if clampedTopY > chunkBottomY {
                let rect = CGRect(x: 0, y: chunkBottomY, width: 1, height: clampedTopY - chunkBottomY)
                if rect.height > 0.0001 {
                    chunkRects.append(rect)
                }
            }

            chunkTopY = max(0, min(1, lines[splitIndex].highestY + margin))
        }

        // Final chunk from last split to the bottom of the image.
        if chunkTopY > 0 {
            let finalRect = CGRect(x: 0, y: 0, width: 1, height: chunkTopY)
            if finalRect.height > 0.0001 {
                chunkRects.append(finalRect)
            }
        }

        return chunkRects
    }

    /// Crops, OCRs, and transcribes each chunk concurrently, then trims
    /// overlap lines so the joined result has no duplicates.
    ///
    /// Returns an ordered array of per-chunk transcript strings (text only,
    /// no images — keeping memory footprint low).
    private static func analyzeChunks(in image: UIImage, from lines: [TranscriptLine]) async -> [String] {
        let fullImageBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let splitBounds = chunkBounds(from: lines)
        let chunkBoundsToUse = splitBounds.isEmpty ? [fullImageBounds] : splitBounds
        let totalChunks = chunkBoundsToUse.count
        let isSingleChunk = splitBounds.isEmpty

        // Pre-crop chunk images as horizontal bands.
        let chunkEntries = chunkBoundsToUse.enumerated().compactMap { index, bounds -> (Int, UIImage)? in
            guard let chunkImage = cropHorizontalChunk(image: image, bounds: bounds) else { return nil }
            return (index, chunkImage)
        }
        let entriesToAnalyze = chunkEntries.isEmpty ? [(0, image)] : chunkEntries

        // Concurrent OCR per chunk.
        let analyzed = await withTaskGroup(of: (Int, String).self) { group in
            for (index, chunkImage) in entriesToAnalyze {
                group.addTask {
                    let observations: [VNRecognizedTextObservation]
                    do {
                        observations = try await detectTextBlocks(in: chunkImage)
                    } catch {
                        print("TranscriptGenerator: chunk \(index + 1) OCR failed: \(error)")
                        observations = []
                    }

                    // Build a plain transcript from this chunk's observations.
                    let fullTranscript = buildTranscriptLines(from: observations)
                        .map(\.text)
                        .joined(separator: "\n")

                    // Trim overlap lines to avoid duplicates when joining:
                    // - First chunk: drop last line
                    // - Last chunk: drop first line
                    // - Middle chunks: drop both
                    // - Single chunk: keep all
                    let trimmed: String
                    if isSingleChunk {
                        trimmed = fullTranscript
                    } else {
                        var transcriptLines = fullTranscript.components(separatedBy: "\n")
                        let isFirst = index == 0
                        let isLast = index == totalChunks - 1
                        if !isFirst && !transcriptLines.isEmpty { transcriptLines.removeFirst() }
                        if !isLast && !transcriptLines.isEmpty { transcriptLines.removeLast() }
                        trimmed = transcriptLines.joined(separator: "\n")
                    }

                    return (index, trimmed)
                }
            }

            var results: [(Int, String)] = []
            for await entry in group { results.append(entry) }
            return results
        }

        // Restore top-to-bottom order after concurrent execution.
        return analyzed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Image cropping

    /// Crops a full-width horizontal band from the image using normalized
    /// Vision coordinates. The image is rasterized upright first so crop
    /// math ignores UIImage orientation metadata.
    private static func cropHorizontalChunk(image: UIImage, bounds: CGRect) -> UIImage? {
        let clamped = bounds.clamped01()
        guard clamped.height > 0 else { return nil }

        let upright = image.rasterizedUpright()
        guard let cgImage = upright.cgImage else { return nil }

        // Vision y=0 is bottom, UIKit y=0 is top → flip.
        let pixelRect = CGRect(
            x: 0,
            y: (1.0 - clamped.maxY) * CGFloat(cgImage.height),
            width: CGFloat(cgImage.width),
            height: clamped.height * CGFloat(cgImage.height)
        ).integral

        let imageRect = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let safe = pixelRect.intersection(imageRect)
        guard safe.width > 0, safe.height > 0,
              let cropped = cgImage.cropping(to: safe) else { return nil }

        return UIImage(cgImage: cropped, scale: upright.scale, orientation: .up)
    }

    // MARK: - OCR

    /// Runs Vision text recognition on the provided image.
    private static func detectTextBlocks(in image: UIImage) async throws -> [VNRecognizedTextObservation] {
        guard let cgImage = image.cgImage else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(
                        cgImage: cgImage,
                        orientation: image.imageOrientation.cgImagePropertyOrientation,
                        options: [:]
                    )
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Fraction of `base`'s height that overlaps with `other`.
    private static func verticalOverlapRatio(of base: CGRect, with other: CGRect) -> CGFloat {
        guard base.height > 0 else { return 0 }
        let overlap = max(0, min(base.maxY, other.maxY) - max(base.minY, other.minY))
        return overlap / base.height
    }
}

// MARK: - Private extensions (scoped to this file)

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

private extension UIImage {
    func rasterizedUpright() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension CGRect {
    func clamped01() -> CGRect {
        let x1 = min(max(minX, 0), 1)
        let y1 = min(max(minY, 0), 1)
        let x2 = min(max(maxX, 0), 1)
        let y2 = min(max(maxY, 0), 1)
        return CGRect(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1))
    }
}
