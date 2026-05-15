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

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

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

        // Step 2: Straighten text skew on the already-cropped image. Tries
        // rectangle-edge detection (more stable) first, falling back to text-angle.
        let correctedImage = await straightenImage(in: tightImage)

        // Step 3a: Apply OCR enhancement (grayscale luminance normalization +
        // contrast + sharpening) for the full-image detection pass.
        let enhancedImage = enhanceForOCR(correctedImage)

        // Step 3b: Detect all recognized text observations on the
        // enhanced image (dual-pass for best coverage).
        let observations = try await detectTextBlocksDualPass(in: enhancedImage)

        // Step 4: Group observations into lines ordered top-to-bottom.
        // Each line records its vertical extent for chunk splitting.
        let lines = buildTranscriptLines(from: observations)

        // Step 5–7: Split, crop, OCR chunks, then merge. Pass `correctedImage`
        // (NOT `enhancedImage`) so each chunk is enhanced exactly once inside
        // prepareChunkForOCR. Double-enhancement corrupts Vision bounding boxes
        // and collapses the transcript into 2–3 mega-lines instead of one line
        // per receipt row.
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

    /// Detects receipt tilt and rotates to compensate. Tries rectangle-edge
    /// detection first (more stable, uses receipt borders) and falls back to
    /// text-character-angle detection if no rectangle is found. Caps correction
    /// at 15° since anything beyond that is probably not a tilt issue.
    private static func straightenImage(in image: UIImage) async -> UIImage {
        let rectAngle = await detectReceiptAngle(in: image)
        let textAngle = await detectTextAngle(in: image)

        let angle: Double
        if let rectAngle, abs(rectAngle) > 0.1 {
            angle = rectAngle
        } else if let textAngle, abs(textAngle) > 0.15 {
            angle = textAngle
        } else {
            return image
        }

        guard abs(angle) < 15 else { return image }
        return rotate(image: image, radians: CGFloat(angle * .pi / 180.0)) ?? image
    }

    /// Detects tilt angle from receipt edges using `VNDetectRectanglesRequest`.
    /// Returns the average of left and right edge angles (from vertical), or
    /// nil if the two edges disagree (unreliable detection).
    private static func detectReceiptAngle(in image: UIImage) async -> Double? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNRectangleObservation],
                      let rect = results.first else {
                    continuation.resume(returning: nil)
                    return
                }

                // Measure tilt from vertical using each side edge.
                // In Vision coordinates (Y=0 at bottom), a perfectly vertical
                // left edge has topLeft.x == bottomLeft.x.
                let leftDx = Double(rect.topLeft.x - rect.bottomLeft.x)
                let leftDy = Double(rect.topLeft.y - rect.bottomLeft.y)
                let leftAngle = atan2(leftDx, leftDy) * 180.0 / .pi

                let rightDx = Double(rect.topRight.x - rect.bottomRight.x)
                let rightDy = Double(rect.topRight.y - rect.bottomRight.y)
                let rightAngle = atan2(rightDx, rightDy) * 180.0 / .pi

                // Edges that disagree by >3° mean the detected rectangle isn't
                // a clean perspective view — reject and let text-angle take over.
                guard abs(leftAngle - rightAngle) < 3 else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: (leftAngle + rightAngle) / 2.0)
            }

            request.minimumAspectRatio = 0.2
            request.maximumAspectRatio = 0.9
            request.minimumSize = 0.3
            request.maximumObservations = 1
            request.minimumConfidence = 0.5

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

    /// Detects tilt angle from text character bounding boxes. Used as a fallback
    /// when rectangle detection fails (e.g., the receipt is photographed without
    /// clear edges in frame).
    private static func detectTextAngle(in image: UIImage) async -> Double? {
        guard let cgImage = image.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNDetectTextRectanglesRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNTextObservation],
                      !results.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

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
                    continuation.resume(returning: nil)
                    return
                }

                let sorted = angles.sorted()
                continuation.resume(returning: sorted[sorted.count / 2])
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

    /// Rotates a UIImage by the given radians using a direct CGContext draw.
    /// Returns nil only if the bitmap context can't be created.
    private static func rotate(image: UIImage, radians: CGFloat) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
        let rotatedRect = CGRect(origin: .zero, size: originalSize)
            .applying(CGAffineTransform(rotationAngle: radians))
        let newSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))

        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        context.rotate(by: radians)
        context.draw(cgImage, in: CGRect(
            x: -originalSize.width / 2,
            y: -originalSize.height / 2,
            width: originalSize.width,
            height: originalSize.height
        ))
        guard let rotatedCG = context.makeImage() else { return nil }
        return UIImage(cgImage: rotatedCG, scale: image.scale, orientation: .up)
    }

    // MARK: - OCR enhancement

    /// Normalizes luminance + applies contrast and sharpening to make faint
    /// receipt text easier for Vision to separate.
    private static func enhanceForOCR(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let normalized = normalizeImageForOCR(cgImage) ?? cgImage
        let ciImage = CIImage(cgImage: normalized)
        let contrasted = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.12
        ])
        let sharpened = contrasted.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.35
        ])

        guard let outputCG = ciContext.createCGImage(sharpened, from: sharpened.extent) else {
            return UIImage(cgImage: normalized, scale: image.scale, orientation: .up)
        }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
    }

    /// Converts the image to grayscale and stretches the luminance range so
    /// faint print is easier to separate from background. Returns the rendered
    /// CGImage so callers can chain additional CI filters efficiently.
    private static func normalizeImageForOCR(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let grayscale = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0
        ])
        let normalized = normalizeLuminance(in: grayscale) ?? grayscale
        return ciContext.createCGImage(normalized, from: normalized.extent)
    }

    private static func normalizeLuminance(in image: CIImage) -> CIImage? {
        let extent = image.extent.integral
        guard !extent.isEmpty else { return nil }

        let extentVector = CIVector(cgRect: extent)
        let minimumImage = image.applyingFilter("CIAreaMinimum", parameters: [
            kCIInputExtentKey: extentVector
        ])
        let maximumImage = image.applyingFilter("CIAreaMaximum", parameters: [
            kCIInputExtentKey: extentVector
        ])

        guard let minimumLuminance = sampleLuminance(from: minimumImage),
              let maximumLuminance = sampleLuminance(from: maximumImage) else {
            return nil
        }

        let clampedMinimum = max(0, min(minimumLuminance, 1))
        let clampedMaximum = max(clampedMinimum + 0.01, min(maximumLuminance, 1))
        let dynamicRange = max(0.25, clampedMaximum - clampedMinimum)
        let scale = 1 / dynamicRange
        let bias = -clampedMinimum * scale

        return image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
    }

    private static func sampleLuminance(from image: CIImage) -> CGFloat? {
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let bitmapContext = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(pixel[0]) / 255
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

        // Seed the per-line fit with a global slope estimate so a freshly-seeded
        // anchor doesn't behave as if the receipt is perfectly horizontal — that
        // produces spurious merges on tilted receipts where the price column is
        // displaced from the item column by (slope × ΔX).
        let globalSlope = estimateGlobalSlope(from: sortedObservations)

        var usedIndices = Set<Int>()
        var lines: [TranscriptLine] = []

        for anchorIndex in sortedObservations.indices {
            guard !usedIndices.contains(anchorIndex) else { continue }

            let anchor = sortedObservations[anchorIndex]
            var lineObservations: [VNRecognizedTextObservation] = [anchor]
            usedIndices.insert(anchorIndex)

            let globalFit = (
                slope: globalSlope,
                intercept: anchor.boundingBox.midY - globalSlope * anchor.boundingBox.midX
            )

            var didGrow = true
            while didGrow {
                didGrow = false
                let fit = lineObservations.count >= 2 ? fitLine(to: lineObservations) : globalFit
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

    /// Upscales 1.5× and applies the OCR enhancement pipeline. The caller must
    /// pass the corrected (un-enhanced) image — passing an already-enhanced
    /// image causes double-enhancement which corrupts Vision bounding boxes
    /// and collapses the transcript into 2–3 mega-lines.
    private static func prepareChunkForOCR(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let scale: CGFloat = 1.5
        let newSize = CGSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)

        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
        guard let upscaledCG = context.makeImage() else { return image }
        let upscaled = UIImage(cgImage: upscaledCG, scale: 1.0, orientation: .up)
        return enhanceForOCR(upscaled)
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

        // Use the anchor's original height as the reference — not the growing
        // meanHeight — so absorbing a taller/shorter observation doesn't
        // snowball the thresholds and start pulling in items from adjacent rows.
        let referenceHeight = min(anchorBox.height, meanHeight)

        // Overlap check: require substantial overlap (≥60%) so densely-packed
        // receipt lines (where adjacent rows barely touch) don't get merged.
        if verticalOverlapRatio(of: anchorBox, with: candidateBox) >= 0.60 {
            return true
        }

        let predictedMidY = fit.slope * candidateBox.midX + fit.intercept
        let baselineDistance = abs(candidateBox.midY - predictedMidY)
        let distanceThreshold = max(referenceHeight, candidateBox.height) * 0.65

        // De-tilt both midY values using the current fit slope before comparing.
        // Without this, a price observation at the far-right edge of a tilted
        // receipt is displaced from its anchor (item name) by (slope × ΔX),
        // which can exceed verticalWindow even when the two observations are
        // genuinely on the same row.
        let anchorDeTiltedY = anchorBox.midY - fit.slope * anchorBox.midX
        let candidateDeTiltedY = candidateBox.midY - fit.slope * candidateBox.midX
        let anchorDistance = abs(candidateDeTiltedY - anchorDeTiltedY)
        // Tighten the vertical window multiplier from 1.4 → 1.0 so adjacent
        // lines (center-to-center ≈ 1× text height) are no longer absorbed
        // into the same line.
        let verticalWindow = max(max(referenceHeight, candidateBox.height), anchorBox.height) * 1.0

        return baselineDistance <= distanceThreshold && anchorDistance <= verticalWindow
    }

    /// Estimates the median per-row slope by sampling pairs of observations that
    /// are vertically close enough to plausibly belong to the same receipt row.
    /// Used as the initial fit for newly-seeded lines (before they have a
    /// second observation to fit against). Capped at 0.2 to reject pathological
    /// tilts that would be rejected by the 15° straighten cap anyway.
    private static func estimateGlobalSlope(from observations: [VNRecognizedTextObservation]) -> CGFloat {
        var estimates: [CGFloat] = []
        let n = min(observations.count, 40)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = observations[i].boundingBox
                let b = observations[j].boundingBox
                let dx = b.midX - a.midX
                guard abs(dx) > 0.15 else { continue }
                let dy = b.midY - a.midY
                let heightRef = max(a.height, b.height)
                guard abs(dy) < heightRef * 0.6 else { continue }
                let slope = dy / dx
                guard abs(slope) < 0.2 else { continue }
                estimates.append(slope)
            }
        }
        guard !estimates.isEmpty else { return 0 }
        let sorted = estimates.sorted()
        return sorted[sorted.count / 2]
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
