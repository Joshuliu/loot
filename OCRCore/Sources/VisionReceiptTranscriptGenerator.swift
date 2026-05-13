import Foundation
import CoreGraphics
import CoreImage
@preconcurrency import Vision

public struct VisionReceiptTranscriptGenerator: ReceiptTranscriptGenerating {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public init() {}

    public func generate(from image: ReceiptImage) async throws -> String {
        try await Self.generateTranscript(from: image)
    }

    private static func generateTranscript(from image: ReceiptImage) async throws -> String {
        let textBounds = await detectTextBoundingBox(in: image)
        let tightImage = cropToNormalizedRect(image, rect: textBounds)
        let correctedImage = await straightenImage(in: tightImage)
        let enhancedImage = enhanceForOCR(correctedImage)
        let observations = try await detectTextBlocksDualPass(in: enhancedImage)
        let lines = buildTranscriptLines(from: observations)
        // Pass correctedImage (not enhancedImage) so each chunk is enhanced exactly once
        // inside prepareChunkForOCR. Passing the already-enhanced image causes double
        // enhancement which corrupts Vision bounding boxes and collapses the transcript
        // into 2–3 mega-lines instead of one line per receipt row.
        let chunkTranscripts = await analyzeChunks(in: correctedImage, from: lines)
        return chunkTranscripts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private struct TranscriptLine {
        let text: String
        let highestY: CGFloat
        let lowestY: CGFloat
        let slope: CGFloat
        let intercept: CGFloat
        let maxAboveCenter: CGFloat
        let maxBelowCenter: CGFloat

        func topY(at x: CGFloat) -> CGFloat { slope * x + intercept + maxAboveCenter }
        func bottomY(at x: CGFloat) -> CGFloat { slope * x + intercept - maxBelowCenter }
    }

    private struct ChunkBoundary { let leftY: CGFloat; let rightY: CGFloat }
    private struct ChunkSpec { let top: ChunkBoundary; let bottom: ChunkBoundary }

    private static func detectTextBoundingBox(in image: ReceiptImage) async -> CGRect {
        let fallback = CGRect(x: 0, y: 0, width: 1, height: 1)
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

                let padded = CGRect(
                    x: max(0, minX - 0.02),
                    y: max(0, minY - 0.01),
                    width: min(1, maxX + 0.02) - max(0, minX - 0.02),
                    height: min(1, maxY + 0.01) - max(0, minY - 0.01)
                )
                continuation.resume(returning: padded)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    private static func cropToNormalizedRect(_ image: ReceiptImage, rect: CGRect) -> ReceiptImage {
        let w = CGFloat(image.cgImage.width)
        let h = CGFloat(image.cgImage.height)
        let pixelRect = CGRect(
            x: rect.minX * w,
            y: (1.0 - rect.maxY) * h,
            width: rect.width * w,
            height: rect.height * h
        ).integral
        let imageRect = CGRect(x: 0, y: 0, width: w, height: h)
        let safe = pixelRect.intersection(imageRect)
        guard safe.width > 0, safe.height > 0, let cropped = image.cgImage.cropping(to: safe) else {
            return image
        }
        return ReceiptImage(cgImage: cropped)
    }

    private static func straightenImage(in image: ReceiptImage) async -> ReceiptImage {
        await withCheckedContinuation { continuation in
            let request = VNDetectTextRectanglesRequest { req, error in
                guard error == nil,
                      let results = req.results as? [VNTextObservation],
                      !results.isEmpty else {
                    continuation.resume(returning: image)
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
                    continuation.resume(returning: image)
                    return
                }

                let sorted = angles.sorted()
                let median = sorted[sorted.count / 2]
                guard abs(median) > 0.5 else {
                    continuation.resume(returning: image)
                    return
                }

                continuation.resume(returning: rotate(image: image, radians: CGFloat(median * .pi / 180.0)) ?? image)
            }

            request.reportCharacterBoxes = true
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    private static func rotate(image: ReceiptImage, radians: CGFloat) -> ReceiptImage? {
        let originalSize = image.size
        let rotatedRect = CGRect(origin: .zero, size: originalSize).applying(CGAffineTransform(rotationAngle: radians))
        let newSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))
        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: image.cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: image.cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.cgImage.bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        context.rotate(by: radians)
        context.draw(image.cgImage, in: CGRect(x: -originalSize.width / 2, y: -originalSize.height / 2, width: originalSize.width, height: originalSize.height))
        guard let cgImage = context.makeImage() else { return nil }
        return ReceiptImage(cgImage: cgImage)
    }

    // Keep OCR-specific enhancement as an explicit stage so we can evolve it independently of scaling.
    private static func enhanceForOCR(_ image: ReceiptImage) -> ReceiptImage {
        let normalizedImage = normalizeImageForOCR(image)
        let ciImage = CIImage(cgImage: normalizedImage.cgImage)
        let contrasted = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.12
        ])
        let sharpened = contrasted.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.35
        ])

        guard let outputCG = ciContext.createCGImage(sharpened, from: sharpened.extent) else {
            return normalizedImage
        }
        return ReceiptImage(cgImage: outputCG)
    }

    private static func prepareChunkForOCR(_ image: ReceiptImage) -> ReceiptImage {
        let scale: CGFloat = 1.5
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: image.cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: image.cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.cgImage.bitmapInfo.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image.cgImage, in: CGRect(origin: .zero, size: newSize))
        guard let cgImage = context.makeImage() else { return image }
        return enhanceForOCR(ReceiptImage(cgImage: cgImage))
    }

    // Convert to grayscale and stretch the luminance range so faint receipt text is easier to separate.
    private static func normalizeImageForOCR(_ image: ReceiptImage) -> ReceiptImage {
        let ciImage = CIImage(cgImage: image.cgImage)
        let grayscale = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0
        ])
        let normalized = normalizeLuminance(in: grayscale) ?? grayscale
        guard let outputCG = ciContext.createCGImage(normalized, from: normalized.extent) else {
            return image
        }
        return ReceiptImage(cgImage: outputCG)
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
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let bitmapContext = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(pixel[0]) / 255
    }

    private static func detectTextBlocksDualPass(in image: ReceiptImage) async throws -> [VNRecognizedTextObservation] {
        async let corrected = detectTextBlocks(in: image, usesLanguageCorrection: true)
        async let raw = detectTextBlocks(in: image, usesLanguageCorrection: false)
        let (pass1, pass2) = try await (corrected, raw)
        return mergeObservations(pass1, pass2)
    }

    private static func detectTextBlocks(in image: ReceiptImage, usesLanguageCorrection: Bool) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (request.results as? [VNRecognizedTextObservation]) ?? [])
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = usesLanguageCorrection
            request.recognitionLanguages = ["en-US"]

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func analyzeChunks(in image: ReceiptImage, from lines: [TranscriptLine]) async -> [String] {
        let splitBounds = chunkBounds(from: lines)
        let chunkBoundsToUse = splitBounds.isEmpty ? [ChunkSpec(top: ChunkBoundary(leftY: 1, rightY: 1), bottom: ChunkBoundary(leftY: 0, rightY: 0))] : splitBounds
        let totalChunks = chunkBoundsToUse.count
        let isSingleChunk = splitBounds.isEmpty

        let analyzed = await withTaskGroup(of: (Int, String).self) { group in
            for (index, bounds) in chunkBoundsToUse.enumerated() {
                group.addTask {
                    guard let chunkImage = cropAngledChunk(image: image, spec: bounds) else {
                        return (index, "")
                    }
                    let prepared = prepareChunkForOCR(chunkImage)
                    let observations = (try? await detectTextBlocksDualPass(in: prepared)) ?? []
                    let fullTranscript = buildTranscriptLinesFromObservations(observations).map(\.text).joined(separator: "\n")

                    let trimmed: String
                    if isSingleChunk {
                        trimmed = fullTranscript
                    } else {
                        var transcriptLines = fullTranscript.components(separatedBy: "\n").filter { !$0.isEmpty }
                        if index != totalChunks - 1 {
                            transcriptLines = Array(transcriptLines.dropLast(min(1, transcriptLines.count)))
                        }
                        if index != 0 {
                            transcriptLines = Array(transcriptLines.dropFirst(min(1, transcriptLines.count)))
                        }
                        trimmed = transcriptLines.joined(separator: "\n")
                    }
                    return (index, trimmed)
                }
            }

            var results: [(Int, String)] = []
            for await entry in group { results.append(entry) }
            return results
        }

        return analyzed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func cropAngledChunk(image: ReceiptImage, spec: ChunkSpec) -> ReceiptImage? {
        let width = CGFloat(image.cgImage.width)
        let height = CGFloat(image.cgImage.height)
        let clampedTop = clamp(boundary: spec.top)
        let clampedBottom = clamp(boundary: spec.bottom)
        let minHeight = min(clampedTop.leftY, clampedTop.rightY) - max(clampedBottom.leftY, clampedBottom.rightY)
        guard minHeight > 0.0001 else { return nil }

        let topLeft = CIVector(x: 0, y: clampedTop.leftY * height)
        let topRight = CIVector(x: width, y: clampedTop.rightY * height)
        let bottomLeft = CIVector(x: 0, y: clampedBottom.leftY * height)
        let bottomRight = CIVector(x: width, y: clampedBottom.rightY * height)
        let ciImage = CIImage(cgImage: image.cgImage)
        let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": topLeft,
            "inputTopRight": topRight,
            "inputBottomLeft": bottomLeft,
            "inputBottomRight": bottomRight
        ])
        guard let outputCG = ciContext.createCGImage(corrected, from: corrected.extent) else { return nil }
        return ReceiptImage(cgImage: outputCG)
    }

    private static func estimateGlobalSlope(from observations: [VNRecognizedTextObservation]) -> CGFloat {
        var estimates: [CGFloat] = []
        let n = min(observations.count, 40)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = observations[i]
                let b = observations[j]
                let dx = b.boundingBox.midX - a.boundingBox.midX
                guard abs(dx) > 0.15 else { continue }
                let dy = b.boundingBox.midY - a.boundingBox.midY
                let heightRef = max(a.boundingBox.height, b.boundingBox.height)
                // Only pair observations that are on the same row (vertically close)
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

    /// Represents a text fragment with its bounding box, either from a full observation or
    /// a word-level split of a tall stacked observation (e.g., a price column).
    private struct TextFragment {
        let text: String
        let boundingBox: CGRect
    }

    /// Split observations that look like vertically stacked columns into individual fragments.
    /// An observation is considered "stacked" when its height is much larger than a typical
    /// single-line observation (>3× the median height) and its text contains multiple
    /// whitespace-separated tokens. This breaks price columns like "$16.75 $19.65 $8.60"
    /// into individual price fragments that can be correctly paired with item names.
    private static func splitStackedObservations(_ observations: [VNRecognizedTextObservation]) -> [TextFragment] {
        guard !observations.isEmpty else { return [] }

        // Compute median observation height to detect outliers
        let heights = observations.map(\.boundingBox.height).sorted()
        let medianHeight = heights[heights.count / 2]

        var fragments: [TextFragment] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let heightRatio = medianHeight > 0 ? obs.boundingBox.height / medianHeight : 1
            // Only split if observation is tall (>3× median) — likely a stacked column
            if heightRatio > 2.0 {
                // Try to get word-level bounding boxes
                var ranges: [Range<String.Index>] = []
                text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { _, range, _, _ in
                    ranges.append(range)
                }
                if ranges.count > 1 {
                    var wordFragments: [TextFragment] = []
                    for range in ranges {
                        if let wordBox = try? candidate.boundingBox(for: range) {
                            let wordText = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !wordText.isEmpty {
                                wordFragments.append(TextFragment(text: wordText, boundingBox: wordBox.boundingBox))
                            }
                        }
                    }
                    if !wordFragments.isEmpty {
                        fragments.append(contentsOf: wordFragments)
                        continue
                    }
                }
            }

            // Keep as single fragment
            fragments.append(TextFragment(text: text, boundingBox: obs.boundingBox))
        }
        return fragments
    }

    private static func buildTranscriptLines(from observations: [VNRecognizedTextObservation]) -> [TranscriptLine] {
        return buildTranscriptLinesFromObservations(observations)
    }

    private static func buildTranscriptLinesFromFragments(_ fragments: [TextFragment]) -> [TranscriptLine] {
        let sortedFragments = fragments.sorted { lhs, rhs in
            let lhsY = lhs.boundingBox.midY
            let rhsY = rhs.boundingBox.midY
            if abs(lhsY - rhsY) > 0.001 { return lhsY > rhsY }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        let globalSlope = estimateGlobalSlopeFromFragments(sortedFragments)

        var usedIndices = Set<Int>()
        var lines: [TranscriptLine] = []

        for anchorIndex in sortedFragments.indices {
            guard !usedIndices.contains(anchorIndex) else { continue }
            let anchor = sortedFragments[anchorIndex]
            var lineFragments: [TextFragment] = [anchor]
            usedIndices.insert(anchorIndex)

            let globalFit = (
                slope: globalSlope,
                intercept: anchor.boundingBox.midY - globalSlope * anchor.boundingBox.midX
            )

            var didGrow = true
            while didGrow {
                didGrow = false
                let fit = lineFragments.count >= 2 ? fitLineFromFragments(lineFragments) : globalFit
                let meanHeight = lineFragments.map(\.boundingBox.height).reduce(0, +) / CGFloat(lineFragments.count)

                for candidateIndex in sortedFragments.indices where !usedIndices.contains(candidateIndex) {
                    let candidate = sortedFragments[candidateIndex]
                    if shouldJoinLineFragment(candidate: candidate, anchor: anchor, fit: fit, meanHeight: meanHeight) {
                        lineFragments.append(candidate)
                        usedIndices.insert(candidateIndex)
                        didGrow = true
                    }
                }
            }

            let ordered = lineFragments.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let finalFit = fitLineFromFragments(ordered)
            let texts = ordered.map(\.text).filter { !$0.isEmpty }

            if !texts.isEmpty {
                var maxAboveCenter: CGFloat = 0
                var maxBelowCenter: CGFloat = 0
                for frag in ordered {
                    let centerY = finalFit.slope * frag.boundingBox.midX + finalFit.intercept
                    maxAboveCenter = max(maxAboveCenter, frag.boundingBox.maxY - centerY)
                    maxBelowCenter = max(maxBelowCenter, centerY - frag.boundingBox.minY)
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

    /// Legacy observation-level line builder, used within chunk analysis where
    /// observations are already from a single-line crop.
    private static func buildTranscriptLinesFromObservations(_ observations: [VNRecognizedTextObservation]) -> [TranscriptLine] {
        let sortedObservations = observations.sorted { lhs, rhs in
            let lhsY = lhs.boundingBox.midY
            let rhsY = rhs.boundingBox.midY
            if abs(lhsY - rhsY) > 0.001 { return lhsY > rhsY }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

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

        let bottomBoundary = ChunkBoundary(leftY: 0, rightY: 0)
        let maxTopY = max(chunkTopBoundary.leftY, chunkTopBoundary.rightY)
        if maxTopY > 0.0001 {
            chunkSpecs.append(.init(top: clamp(boundary: chunkTopBoundary), bottom: bottomBoundary))
        }

        return chunkSpecs
    }

    private static func mergeObservations(_ pass1: [VNRecognizedTextObservation], _ pass2: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        var result: [VNRecognizedTextObservation] = []
        var usedInPass2 = Set<Int>()

        for obs1 in pass1 {
            var bestIdx = -1
            var bestIoU: CGFloat = 0
            for (i, obs2) in pass2.enumerated() {
                let iou = boundingBoxIoU(obs1.boundingBox, obs2.boundingBox)
                if iou > bestIoU {
                    bestIoU = iou
                    bestIdx = i
                }
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
            return (0, observations.first?.boundingBox.midY ?? 0)
        }
        let points = observations.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        let meanX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let meanY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let numerator = points.reduce(CGFloat.zero) { $0 + (($1.x - meanX) * ($1.y - meanY)) }
        let denominator = points.reduce(CGFloat.zero) { $0 + pow($1.x - meanX, 2) }
        let slope: CGFloat = denominator > 0.000001 ? (numerator / denominator) : 0
        return (slope, meanY - slope * meanX)
    }

    private static func boundaryFromTop(of line: TranscriptLine) -> ChunkBoundary {
        ChunkBoundary(leftY: line.topY(at: 0), rightY: line.topY(at: 1))
    }

    private static func boundaryFromBottom(of line: TranscriptLine) -> ChunkBoundary {
        ChunkBoundary(leftY: line.bottomY(at: 0), rightY: line.bottomY(at: 1))
    }

    private static func clamp(boundary: ChunkBoundary) -> ChunkBoundary {
        ChunkBoundary(leftY: min(max(boundary.leftY, 0), 1), rightY: min(max(boundary.rightY, 0), 1))
    }

    private static func shouldJoinLine(candidate: VNRecognizedTextObservation, anchor: VNRecognizedTextObservation, fit: (slope: CGFloat, intercept: CGFloat), meanHeight: CGFloat) -> Bool {
        let candidateBox = candidate.boundingBox
        let anchorBox = anchor.boundingBox

        // Use the anchor's original height as the reference — not the growing meanHeight —
        // so that absorbing a taller/shorter observation doesn't snowball the thresholds
        // and start pulling in items from adjacent receipt rows.
        let referenceHeight = min(anchorBox.height, meanHeight)

        // Overlap check: require substantial overlap (≥60%) so that densely-packed receipt
        // lines (where adjacent rows barely touch) don't get merged.
        if verticalOverlapRatio(of: anchorBox, with: candidateBox) >= 0.60 { return true }

        let predictedMidY = fit.slope * candidateBox.midX + fit.intercept
        let baselineDistance = abs(candidateBox.midY - predictedMidY)
        let distanceThreshold = max(referenceHeight, candidateBox.height) * 0.65
        // De-tilt both midY values using the current fit slope before comparing them.
        // Without this, a price observation at the far-right edge of a tilted receipt is
        // displaced from its anchor (item name) by (slope × ΔX), which can exceed
        // verticalWindow even when the two observations are genuinely on the same row.
        let anchorDeTiltedY = anchorBox.midY - fit.slope * anchorBox.midX
        let candidateDeTiltedY = candidateBox.midY - fit.slope * candidateBox.midX
        let anchorDistance = abs(candidateDeTiltedY - anchorDeTiltedY)
        // Reduce the vertical window multiplier from 1.4 → 1.0 so adjacent lines
        // (center-to-center ≈ 1× text height) are no longer absorbed into the same line.
        let verticalWindow = max(max(referenceHeight, candidateBox.height), anchorBox.height) * 1.0
        return baselineDistance <= distanceThreshold && anchorDistance <= verticalWindow
    }

    private static func verticalOverlapRatio(of base: CGRect, with other: CGRect) -> CGFloat {
        guard base.height > 0 else { return 0 }
        let overlap = max(0, min(base.maxY, other.maxY) - max(base.minY, other.minY))
        return overlap / base.height
    }

    // MARK: - Fragment-level helpers (for split stacked observations)

    private static func estimateGlobalSlopeFromFragments(_ fragments: [TextFragment]) -> CGFloat {
        var estimates: [CGFloat] = []
        let n = min(fragments.count, 60)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = fragments[i].boundingBox
                let b = fragments[j].boundingBox
                let dx = b.midX - a.midX
                guard abs(dx) > 0.10 else { continue }
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

    private static func fitLineFromFragments(_ fragments: [TextFragment]) -> (slope: CGFloat, intercept: CGFloat) {
        guard fragments.count >= 2 else {
            return (0, fragments.first?.boundingBox.midY ?? 0)
        }
        let points = fragments.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        let meanX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let meanY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let numerator = points.reduce(CGFloat.zero) { $0 + (($1.x - meanX) * ($1.y - meanY)) }
        let denominator = points.reduce(CGFloat.zero) { $0 + pow($1.x - meanX, 2) }
        let slope: CGFloat = denominator > 0.000001 ? (numerator / denominator) : 0
        return (slope, meanY - slope * meanX)
    }

    private static func shouldJoinLineFragment(candidate: TextFragment, anchor: TextFragment, fit: (slope: CGFloat, intercept: CGFloat), meanHeight: CGFloat) -> Bool {
        let candidateBox = candidate.boundingBox
        let anchorBox = anchor.boundingBox
        let referenceHeight = min(anchorBox.height, meanHeight)

        if verticalOverlapRatio(of: anchorBox, with: candidateBox) >= 0.60 { return true }

        let predictedMidY = fit.slope * candidateBox.midX + fit.intercept
        let baselineDistance = abs(candidateBox.midY - predictedMidY)
        let distanceThreshold = max(referenceHeight, candidateBox.height) * 0.65

        let anchorDeTiltedY = anchorBox.midY - fit.slope * anchorBox.midX
        let candidateDeTiltedY = candidateBox.midY - fit.slope * candidateBox.midX
        let anchorDistance = abs(candidateDeTiltedY - anchorDeTiltedY)
        let verticalWindow = max(max(referenceHeight, candidateBox.height), anchorBox.height) * 1.0

        return baselineDistance <= distanceThreshold && anchorDistance <= verticalWindow
    }
}
