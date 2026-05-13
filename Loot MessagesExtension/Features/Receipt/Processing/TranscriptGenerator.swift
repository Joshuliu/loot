//
//  TranscriptGenerator.swift
//  VisionTest
//
//  Created by Kendrick Ng on 3/2/26.
//

import Foundation
import UIKit
import CoreImage
@preconcurrency import Vision

/// A standalone, memory-lean tool that accepts a UIImage and returns
/// the OCR transcript. The pipeline mirrors AnalyzeDocument's downstream
/// flow (correct → detect → group lines → chunk → OCR → join) but omits
/// ImageAnalyzer, document detection, and other heavy features that are
/// unnecessary for transcript-only output.
enum TranscriptGenerator {

    // Debug: chunk images from the most recent generate() call (native resolution, pre-upscale).
    // Populated always; only transferred to uiModel when DEBUG_SHOW_CHUNKS is true.
    static var lastDebugChunks: [UIImage] = []

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
        let startTime = Date()

        // Step 1: Quick text-block detection to find the tight bounding box of
        // all text. Crop to it before straightening so we rotate a smaller image
        // and each subsequent chunk contains less non-text margin.
        let textBounds = await detectTextBoundingBox(in: image)
        let tightImage = cropToNormalizedRect(image, rect: textBounds)

        // Step 2: Straighten text skew on the already-cropped image.
        let correctedImage = await straightenImage(in: tightImage)

        // Step 3: Detect all recognized text observations on the
        // full corrected image (dual-pass for best coverage).
        let observations = try await detectTextBlocksDualPass(in: correctedImage)

        // Step 4: Group observations into lines ordered top-to-bottom.
        // Each line records its vertical extent for chunk splitting.
        let lines = buildTranscriptLines(from: observations)

        // Step 5–7: Split, crop, OCR chunks, then merge.
        let chunkTranscripts = await analyzeChunks(in: correctedImage, from: lines)
        let joined = chunkTranscripts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let elapsed = Date().timeIntervalSince(startTime)
        let confidences = observations.compactMap { $0.topCandidates(1).first?.confidence }
        let avgConfidence = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Float(confidences.count)
        print(String(format: "[TranscriptGenerator] Done: %d chars, %.1fs, avg confidence %.0f%%",
                     joined.count, elapsed, avgConfidence * 100))

        return joined
    }

    // MARK: - Global text crop

    /// Uses VNDetectTextRectanglesRequest (fast, no text reading) to find the
    /// union bounding box of all text blocks in the image. Returns a normalized
    /// CGRect in Vision coordinates (origin bottom-left).
    private static func detectTextBoundingBox(in image: UIImage) async -> CGRect {
        let fallback = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let cgImage = image.cgImage else { return fallback }

        return await withCheckedContinuation { continuation in
            let request = VNDetectTextRectanglesRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNTextObservation],
                      !results.isEmpty else {
                    continuation.resume(returning: fallback)
                    return
                }

                var minX: CGFloat = 1, minY: CGFloat = 1
                var maxX: CGFloat = 0, maxY: CGFloat = 0
                for obs in results {
                    minX = min(minX, obs.boundingBox.minX)
                    minY = min(minY, obs.boundingBox.minY)
                    maxX = max(maxX, obs.boundingBox.maxX)
                    maxY = max(maxY, obs.boundingBox.maxY)
                }

                // Add a small margin so tight bounding boxes don't clip edge characters.
                let hMargin: CGFloat = 0.02
                let vMargin: CGFloat = 0.01
                let paddedMinX = max(0, minX - hMargin)
                let paddedMinY = max(0, minY - vMargin)
                let paddedMaxX = min(1, maxX + hMargin)
                let paddedMaxY = min(1, maxY + vMargin)

                continuation.resume(returning: CGRect(x: paddedMinX, y: paddedMinY,
                                                      width: paddedMaxX - paddedMinX,
                                                      height: paddedMaxY - paddedMinY))
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    /// Crops a UIImage to a normalized rect in Vision coordinates (Y=0 at bottom).
    private static func cropToNormalizedRect(_ image: UIImage, rect: CGRect) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        // Vision Y=0 is bottom; UIKit Y=0 is top — flip Y axis.
        let pixelRect = CGRect(
            x: rect.minX * w,
            y: (1.0 - rect.maxY) * h,
            width: rect.width * w,
            height: rect.height * h
        ).integral

        let imageRect = CGRect(x: 0, y: 0, width: w, height: h)
        let safe = pixelRect.intersection(imageRect)
        guard safe.width > 0, safe.height > 0,
              let cropped = cgImage.cropping(to: safe) else { return image }

        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    // MARK: - Image straightening

    /// Detects text skew via `VNDetectTextRectanglesRequest` (which returns corner
    /// points) and rotates the image to compensate. Returns the original image if
    /// no significant tilt is found.
    private static func straightenImage(in image: UIImage) async -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        return await withCheckedContinuation { continuation in
            let request = VNDetectTextRectanglesRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNTextObservation],
                      !results.isEmpty else {
                    continuation.resume(returning: image)
                    return
                }

                // Collect per-character angles from corner points.
                // Vision uses bottom-left origin so dy > 0 means the baseline
                // rises to the right (counter-clockwise tilt).
                var angles: [Double] = []
                for obs in results {
                    guard let boxes = obs.characterBoxes else { continue }
                    for box in boxes {
                        let dx = Double(box.topRight.x - box.topLeft.x)
                        let dy = Double(box.topRight.y - box.topLeft.y)
                        let angle = atan2(dy, dx) * 180.0 / .pi
                        if abs(angle) < 45 { angles.append(angle) }
                    }
                }

                guard !angles.isEmpty else {
                    continuation.resume(returning: image)
                    return
                }

                let sorted = angles.sorted()
                let median = sorted[sorted.count / 2]

                guard abs(median) > 0.5 else {
                    continuation.resume(returning: image)
                    return
                }

                let radians = CGFloat(median * .pi / 180.0)
                let originalSize = image.size
                let rotatedRect = CGRect(origin: .zero, size: originalSize)
                    .applying(CGAffineTransform(rotationAngle: radians))
                let newSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))

                let renderer = UIGraphicsImageRenderer(size: newSize)
                let rotated = renderer.image { ctx in
                    let cg = ctx.cgContext
                    cg.translateBy(x: newSize.width / 2, y: newSize.height / 2)
                    cg.rotate(by: radians)
                    cg.translateBy(x: -originalSize.width / 2, y: -originalSize.height / 2)
                    image.draw(at: .zero)
                }

                continuation.resume(returning: rotated)
            }
            request.reportCharacterBoxes = true

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: image.imageOrientation.cgImagePropertyOrientation,
                    options: [:]
                )
                try? handler.perform([request])
            }
        }
    }

    // MARK: - Line metadata

    /// Holds a single line's text and the vertical bounds of its
    /// constituent observations in Vision's normalized coordinate space.
    private struct TranscriptLine {
        let text: String
        let highestY: CGFloat   // max boundingBox.maxY across all observations in line
        let lowestY: CGFloat    // min boundingBox.minY across all observations in line
        let slope: CGFloat
        let intercept: CGFloat
        let maxAboveCenter: CGFloat
        let maxBelowCenter: CGFloat

        func topY(at x: CGFloat) -> CGFloat {
            slope * x + intercept + maxAboveCenter
        }

        func bottomY(at x: CGFloat) -> CGFloat {
            slope * x + intercept - maxBelowCenter
        }
    }

    private struct ChunkBoundary {
        let leftY: CGFloat
        let rightY: CGFloat
    }

    private struct ChunkSpec {
        let top: ChunkBoundary
        let bottom: ChunkBoundary
    }

    /// Groups recognized text observations into reading-order lines.
    ///
    /// Algorithm:
    /// 1. Sort observations top-to-bottom (descending midY), left-to-right.
    /// 2. For each unvisited observation ("anchor"), collect unvisited
    ///    observations that either vertically overlap or lie close to the
    ///    fitted baseline of the current line. This tolerates slight residual
    ///    tilt better than purely horizontal grouping.
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

            var didGrow = true
            while didGrow {
                didGrow = false
                let fit = fitLine(to: lineObservations)
                let meanHeight = lineObservations.map(\.boundingBox.height).reduce(0, +) / CGFloat(lineObservations.count)

                for candidateIndex in sortedObservations.indices where !usedIndices.contains(candidateIndex) {
                    let candidate = sortedObservations[candidateIndex]
                    if shouldJoinLine(candidate: candidate, anchor: anchor, fit: fit, meanHeight: meanHeight) {
                        lineObservations.append(candidate)
                        usedIndices.insert(candidateIndex)
                        didGrow = true
                    }
                }
            }

            // Left-to-right reading order within the line.
            let ordered = lineObservations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let finalFit = fitLine(to: ordered)
            let texts = ordered
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !texts.isEmpty {
                var maxAboveCenter: CGFloat = 0
                var maxBelowCenter: CGFloat = 0
                for observation in ordered {
                    let centerY = finalFit.slope * observation.boundingBox.midX + finalFit.intercept
                    maxAboveCenter = max(maxAboveCenter, observation.boundingBox.maxY - centerY)
                    maxBelowCenter = max(maxBelowCenter, centerY - observation.boundingBox.minY)
                }

                lines.append(TranscriptLine(
                    text: texts.joined(separator: " "),
                    highestY: ordered.map(\.boundingBox.maxY).max() ?? 0,
                    lowestY: ordered.map(\.boundingBox.minY).min() ?? 0,
                    slope: finalFit.slope,
                    intercept: finalFit.intercept,
                    maxAboveCenter: maxAboveCenter,
                    maxBelowCenter: maxBelowCenter
                ))
            }
        }

        return lines
    }

    // MARK: - Chunking

    /// Computes normalized crop rects that split the image around every ~20th
    /// line, preferring larger vertical gaps near the target index and keeping
    /// exactly two shared boundary lines between neighboring chunks.
    private static func chunkBounds(from lines: [TranscriptLine]) -> [ChunkSpec] {
        guard !lines.isEmpty else { return [] }

        var chunkSpecs: [ChunkSpec] = []
        var chunkTopBoundary = ChunkBoundary(leftY: 1.0, rightY: 1.0)
        var previousSplitIndex = -1
        var targetIndex = 19

        while targetIndex < lines.count - 1 {
            let searchStart = max(previousSplitIndex + 1, targetIndex - 3)
            let searchEnd = min(lines.count - 2, targetIndex + 3)

            var bestSplitIndex = targetIndex
            var bestGap: CGFloat = -.greatestFiniteMagnitude
            for candidateIndex in searchStart...searchEnd {
                let gap = lines[candidateIndex].lowestY - lines[candidateIndex + 1].highestY
                if gap > bestGap {
                    bestGap = gap
                    bestSplitIndex = candidateIndex
                }
            }

            // Chunk N should include the same last two lines as chunk N+1's first
            // two lines. That means the current chunk extends through the lower
            // boundary of the second shared line, while the next chunk starts at
            // the upper boundary of the first shared line.
            let bottomBoundary = boundaryFromBottom(of: lines[bestSplitIndex + 1])
            let maxTopY = max(chunkTopBoundary.leftY, chunkTopBoundary.rightY)
            let minBottomY = min(bottomBoundary.leftY, bottomBoundary.rightY)

            if maxTopY > minBottomY {
                chunkSpecs.append(.init(top: clamp(boundary: chunkTopBoundary), bottom: clamp(boundary: bottomBoundary)))
            }

            chunkTopBoundary = boundaryFromTop(of: lines[bestSplitIndex])
            previousSplitIndex = bestSplitIndex
            targetIndex = bestSplitIndex + 20
        }

        // Final chunk from last split to the bottom of the image.
        let bottomBoundary = ChunkBoundary(leftY: 0, rightY: 0)
        let maxTopY = max(chunkTopBoundary.leftY, chunkTopBoundary.rightY)
        if maxTopY > 0.0001 {
            chunkSpecs.append(.init(top: clamp(boundary: chunkTopBoundary), bottom: bottomBoundary))
        }

        return chunkSpecs
    }

    /// Crops, OCRs, and transcribes each chunk concurrently, then trims the
    /// shared two-line overlap asymmetrically:
    /// - earlier chunk drops the lower shared line
    /// - later chunk drops the higher shared line
    /// This preserves both shared rows exactly once in the final transcript.
    ///
    /// Returns an ordered array of per-chunk transcript strings (text only,
    /// no images — keeping memory footprint low).
    private static func analyzeChunks(in image: UIImage, from lines: [TranscriptLine]) async -> [String] {
        let splitBounds = chunkBounds(from: lines)
        let chunkBoundsToUse = splitBounds.isEmpty ? [ChunkSpec(top: ChunkBoundary(leftY: 1, rightY: 1), bottom: ChunkBoundary(leftY: 0, rightY: 0))] : splitBounds
        let totalChunks = chunkBoundsToUse.count
        let isSingleChunk = splitBounds.isEmpty

        // Concurrent OCR — crop+upscale happens inside each task so each chunk's
        // prepared image is scoped to its task and released as soon as OCR finishes.
        // Each task also returns the native-resolution chunk image for debug display.
        let analyzed = await withTaskGroup(of: (Int, String, UIImage?).self) { group in
            for (index, bounds) in chunkBoundsToUse.enumerated() {
                group.addTask {
                    guard let chunkImage = cropAngledChunk(image: image, spec: bounds) else {
                        return (index, "", nil)
                    }
                    let prepared = prepareChunkForOCR(chunkImage)

                    let observations: [VNRecognizedTextObservation]
                    do {
                        observations = try await detectTextBlocksDualPass(in: prepared)
                    } catch {
                        print("TranscriptGenerator: chunk \(index + 1) OCR failed: \(error)")
                        observations = []
                    }

                    let fullTranscript = buildTranscriptLines(from: observations)
                        .map(\.text)
                        .joined(separator: "\n")

                    let trimmed: String
                    if isSingleChunk {
                        trimmed = fullTranscript
                    } else {
                        var lines = fullTranscript.components(separatedBy: "\n").filter { !$0.isEmpty }
                        let isFirst = index == 0
                        let isLast = index == totalChunks - 1
                        if !isLast {
                            lines = Array(lines.dropLast(min(1, lines.count)))
                        }
                        if !isFirst {
                            lines = Array(lines.dropFirst(min(1, lines.count)))
                        }
                        trimmed = lines.joined(separator: "\n")
                    }

                    return (index, trimmed, chunkImage)
                }
            }

            var results: [(Int, String, UIImage?)] = []
            for await entry in group { results.append(entry) }
            return results
        }

        let sorted = analyzed.sorted { $0.0 < $1.0 }
        lastDebugChunks = sorted.compactMap(\.2)
        return sorted.map(\.1)
    }

    // MARK: - Image cropping

    /// Crops a quadrilateral chunk from the image using slanted top and bottom
    /// boundaries in normalized Vision coordinates, then rectifies it into an
    /// upright rectangle for OCR.
    private static func cropAngledChunk(image: UIImage, spec: ChunkSpec) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let clampedTop = clamp(boundary: spec.top)
        let clampedBottom = clamp(boundary: spec.bottom)
        let minHeight = min(clampedTop.leftY, clampedTop.rightY) - max(clampedBottom.leftY, clampedBottom.rightY)
        guard minHeight > 0.0001 else { return nil }

        let topLeft = CIVector(x: 0, y: clampedTop.leftY * height)
        let topRight = CIVector(x: width, y: clampedTop.rightY * height)
        let bottomLeft = CIVector(x: 0, y: clampedBottom.leftY * height)
        let bottomRight = CIVector(x: width, y: clampedBottom.rightY * height)

        let ciImage = CIImage(cgImage: cgImage)
        let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": topLeft,
            "inputTopRight": topRight,
            "inputBottomLeft": bottomLeft,
            "inputBottomRight": bottomRight
        ])

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCG = ctx.createCGImage(corrected, from: corrected.extent) else { return nil }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
    }

    // MARK: - Chunk preparation

    /// Upscales a chunk before OCR. The rectified chunk crop is already
    /// geometrically normalized, so we avoid additional sharpening here to
    /// reduce OCR regressions on otherwise clear text.
    private static func prepareChunkForOCR(_ image: UIImage) -> UIImage {
        let scale: CGFloat = 1.5
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let upscaled = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return upscaled
    }

    // MARK: - OCR

    /// Runs two OCR passes concurrently (with and without language correction) and
    /// merges results by confidence. Language correction helps item names but can
    /// corrupt prices, codes, and short abbreviations — the dual pass gets both.
    private static func detectTextBlocksDualPass(in image: UIImage) async throws -> [VNRecognizedTextObservation] {
        async let corrected = detectTextBlocks(in: image, usesLanguageCorrection: true)
        async let raw = detectTextBlocks(in: image, usesLanguageCorrection: false)
        let (pass1, pass2) = try await (corrected, raw)
        return mergeObservations(pass1, pass2)
    }

    /// Runs Vision text recognition on the provided image.
    private static func detectTextBlocks(in image: UIImage, usesLanguageCorrection: Bool = true) async throws -> [VNRecognizedTextObservation] {
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
            request.usesLanguageCorrection = usesLanguageCorrection
            request.recognitionLanguages = ["en-US"]

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

    /// Merges two observation arrays by bounding box overlap, keeping the
    /// higher-confidence candidate for each matched region. Unmatched observations
    /// from either pass are included as-is.
    private static func mergeObservations(
        _ pass1: [VNRecognizedTextObservation],
        _ pass2: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        var result: [VNRecognizedTextObservation] = []
        var usedInPass2 = Set<Int>()

        for obs1 in pass1 {
            var bestIdx = -1
            var bestIoU: CGFloat = 0
            for (i, obs2) in pass2.enumerated() {
                let iou = boundingBoxIoU(obs1.boundingBox, obs2.boundingBox)
                if iou > bestIoU { bestIoU = iou; bestIdx = i }
            }

            if bestIoU > 0.5, bestIdx >= 0 {
                let obs2 = pass2[bestIdx]
                let conf1 = obs1.topCandidates(1).first?.confidence ?? 0
                let conf2 = obs2.topCandidates(1).first?.confidence ?? 0
                result.append(conf1 >= conf2 ? obs1 : obs2)
                usedInPass2.insert(bestIdx)
            } else {
                result.append(obs1)
            }
        }

        // Include any observations from pass2 that had no match in pass1
        for (i, obs2) in pass2.enumerated() where !usedInPass2.contains(i) {
            result.append(obs2)
        }

        return result
    }

    private static func boundingBoxIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private static func fitLine(to observations: [VNRecognizedTextObservation]) -> (slope: CGFloat, intercept: CGFloat) {
        guard observations.count >= 2 else {
            let midY = observations.first?.boundingBox.midY ?? 0
            return (0, midY)
        }

        let points = observations.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        let meanX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let meanY = points.map(\.y).reduce(0, +) / CGFloat(points.count)

        let numerator = points.reduce(CGFloat.zero) { partial, point in
            partial + ((point.x - meanX) * (point.y - meanY))
        }
        let denominator = points.reduce(CGFloat.zero) { partial, point in
            partial + pow(point.x - meanX, 2)
        }

        let slope: CGFloat = denominator > 0.000001 ? (numerator / denominator) : 0
        let intercept = meanY - slope * meanX
        return (slope, intercept)
    }

    private static func boundaryFromTop(of line: TranscriptLine) -> ChunkBoundary {
        ChunkBoundary(leftY: line.topY(at: 0), rightY: line.topY(at: 1))
    }

    private static func boundaryFromBottom(of line: TranscriptLine) -> ChunkBoundary {
        ChunkBoundary(leftY: line.bottomY(at: 0), rightY: line.bottomY(at: 1))
    }

    private static func clamp(boundary: ChunkBoundary) -> ChunkBoundary {
        ChunkBoundary(
            leftY: min(max(boundary.leftY, 0), 1),
            rightY: min(max(boundary.rightY, 0), 1)
        )
    }

    private static func shouldJoinLine(
        candidate: VNRecognizedTextObservation,
        anchor: VNRecognizedTextObservation,
        fit: (slope: CGFloat, intercept: CGFloat),
        meanHeight: CGFloat
    ) -> Bool {
        let candidateBox = candidate.boundingBox
        let anchorBox = anchor.boundingBox

        if verticalOverlapRatio(of: anchorBox, with: candidateBox) >= 0.45 {
            return true
        }

        let predictedMidY = fit.slope * candidateBox.midX + fit.intercept
        let baselineDistance = abs(candidateBox.midY - predictedMidY)
        let distanceThreshold = max(meanHeight, candidateBox.height) * 0.65

        let anchorDistance = abs(candidateBox.midY - anchorBox.midY)
        let verticalWindow = max(max(meanHeight, candidateBox.height), anchorBox.height) * 1.4

        return baselineDistance <= distanceThreshold && anchorDistance <= verticalWindow
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

private extension CGRect {
    func clamped01() -> CGRect {
        let x1 = min(max(minX, 0), 1)
        let y1 = min(max(minY, 0), 1)
        let x2 = min(max(maxX, 0), 1)
        let y2 = min(max(maxY, 0), 1)
        return CGRect(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1))
    }
}
