//
//  TranscriptGenerator.swift
//  VisionTest
//
//  Created by Kendrick Ng on 3/2/26.
//

import Foundation
import UIKit
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
    /// 4. Compute chunk boundaries at every 10th line with overlap.
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

    /// Computes normalized crop rects that split the image at every 10th
    /// line with one-line overlap on each side.
    ///
    /// - Current chunk extends down to line 11's lower Y bound.
    /// - Next chunk starts at line 10's upper Y bound.
    /// - Transcript trimming later removes the duplicated boundary lines.
    private static func chunkBounds(from lines: [TranscriptLine], margin: CGFloat = 0.000) -> [CGRect] {
        guard !lines.isEmpty else { return [] }

        let splitLineIndices = stride(from: 9, to: lines.count, by: 10)
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

        // Concurrent OCR — crop+upscale happens inside each task so each chunk's
        // prepared image is scoped to its task and released as soon as OCR finishes.
        // Each task also returns the native-resolution chunk image for debug display.
        let analyzed = await withTaskGroup(of: (Int, String, UIImage?).self) { group in
            for (index, bounds) in chunkBoundsToUse.enumerated() {
                group.addTask {
                    guard let chunkImage = cropHorizontalChunk(image: image, bounds: bounds) else {
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
                        var lines = fullTranscript.components(separatedBy: "\n")
                        let isFirst = index == 0
                        let isLast = index == totalChunks - 1
                        if !isFirst && !lines.isEmpty { lines.removeFirst() }
                        if !isLast && !lines.isEmpty { lines.removeLast() }
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

    /// Crops a full-width horizontal band from the image using normalized
    /// Vision coordinates. The image is rasterized upright first so crop
    /// math ignores UIImage orientation metadata.
    private static func cropHorizontalChunk(image: UIImage, bounds: CGRect) -> UIImage? {
        let clamped = bounds.clamped01()
        guard clamped.height > 0 else { return nil }

        guard let cgImage = image.cgImage else { return nil }

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

        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    // MARK: - Chunk preparation

    /// Upscales a chunk 2x and applies strong sharpening before OCR.
    /// Larger pixels give VisionKit more signal per character; sharpening
    /// enhances edges without the destructive side-effects of binarization.
    private static func prepareChunkForOCR(_ image: UIImage) -> UIImage {
        let scale: CGFloat = 2.0
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let upscaled = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()

        guard let ci = CIImage(image: upscaled) else { return upscaled }

        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = ci
        unsharp.radius = 3.0
        unsharp.intensity = 1.5

        guard let output = unsharp.outputImage else { return upscaled }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(output, from: output.extent) else { return upscaled }
        return UIImage(cgImage: cg, scale: 1.0, orientation: .up)
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
