import Foundation
import CoreGraphics
import CoreImage
@preconcurrency import Vision

public struct VisionReceiptTranscriptGenerator: ReceiptTranscriptGenerating {
    public init() {}

    public func generate(from image: ReceiptImage) async throws -> String {
        try await Self.generateTranscript(from: image)
    }

    private static func generateTranscript(from image: ReceiptImage) async throws -> String {
        let textBounds = await detectTextBoundingBox(in: image)
        let tightImage = cropToNormalizedRect(image, rect: textBounds)
        let correctedImage = await straightenImage(in: tightImage)
        let observations = try await detectTextBlocksDualPass(in: correctedImage)
        let lines = buildTranscriptLines(from: observations)
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
        return ReceiptImage(cgImage: cgImage)
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
                    let fullTranscript = buildTranscriptLines(from: observations).map(\.text).joined(separator: "\n")

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
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCG = ctx.createCGImage(corrected, from: corrected.extent) else { return nil }
        return ReceiptImage(cgImage: outputCG)
    }

    private static func buildTranscriptLines(from observations: [VNRecognizedTextObservation]) -> [TranscriptLine] {
        let sortedObservations = observations.sorted { lhs, rhs in
            let lhsY = lhs.boundingBox.midY
            let rhsY = rhs.boundingBox.midY
            if abs(lhsY - rhsY) > 0.001 { return lhsY > rhsY }
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
        if verticalOverlapRatio(of: anchorBox, with: candidateBox) >= 0.45 { return true }
        let predictedMidY = fit.slope * candidateBox.midX + fit.intercept
        let baselineDistance = abs(candidateBox.midY - predictedMidY)
        let distanceThreshold = max(meanHeight, candidateBox.height) * 0.65
        let anchorDistance = abs(candidateBox.midY - anchorBox.midY)
        let verticalWindow = max(max(meanHeight, candidateBox.height), anchorBox.height) * 1.4
        return baselineDistance <= distanceThreshold && anchorDistance <= verticalWindow
    }

    private static func verticalOverlapRatio(of base: CGRect, with other: CGRect) -> CGFloat {
        guard base.height > 0 else { return 0 }
        let overlap = max(0, min(base.maxY, other.maxY) - max(base.minY, other.minY))
        return overlap / base.height
    }
}
