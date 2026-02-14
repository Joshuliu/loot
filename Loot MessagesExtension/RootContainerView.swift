//
//  RootContainerView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//

import SwiftUI
import Vision

struct RootContainerView: View {
    @AppStorage(DefaultsKeys.myDisplayName) private var myName: String = ""
    @ObservedObject var uiModel: LootUIModel

    @State private var showSplitViewSheet: Bool = false
    @State private var confirmationCameFromManual: Bool = false
    @State private var paymentMethodsIsPostSend: Bool = false

    @State private var receiptName: String = ""
    @State private var splitDraft: SplitDraft? = nil
    @State private var amountString: String = "0"
    @State private var tipAmount: String = ""
    @State private var returnScreen: AppScreen = .tabview
    @Namespace private var titleNamespace
    
    // Computed total: subtotal + tax + fees - discounts + tip
    private var totalAmount: String {
        // If we have a receipt with breakdown, use its total (includes tax, fees, discounts, tip)
        if let receipt = uiModel.currentReceipt {
            return String(format: "%.2f", Double(receipt.totalCents) / 100.0)
        }
        
        // Otherwise, calculate from manual entry (subtotal + tip only, no tax/fees/discounts in manual flow)
        guard !tipAmount.isEmpty, tipAmount != "$0", tipAmount != "$0.00" else {
            return amountString
        }
        let subtotal = amountToCents(amountString)
        let tip = amountToCents(tipAmount)
        let total = subtotal + tip
        return String(format: "%.2f", Double(total) / 100.0)
    }
    
    let participantCount: Int
    let onScan: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onSendBill: (String, String) -> Void
    let onSendTabInvite: ((String, String, String) -> Void)?  // (tabName, tabColorHex, tabId)

    // Tab creation state
    @State private var pendingTabName: String = ""
    @State private var pendingTabColor: String = TabColorOptions.defaultHex
    @State private var pendingTabId: String = ""
    @State private var tabInviteCameFromTabView: Bool = false

    // DEBUG: Set to true to only run VisionKit OCR and print JSON (no Gemini)
    private let DEBUG_OCR_ONLY = false
    @State private var debugOCRResult: OCRResult? = nil
    @State private var debugOriginalImage: UIImage? = nil

    // Camera sheet state
    @State private var showCamera: Bool = false
    @State private var capturedImage: UIImage? = nil
    
    // Photo library state
    @State private var showPhotoLibrary: Bool = false
    @State private var photoLibraryImage: UIImage? = nil
    
    @State private var isAnalyzing: Bool = false
    @State private var analyzeError: String?

    // Backend user restore state
    @State private var isCheckingBackendUser: Bool = true

    init(uiModel: LootUIModel) {
        self.uiModel = uiModel
        self.participantCount = 1
        self.onScan = {}
        self.onExpand = {}
        self.onCollapse = {}
        self.onSendBill = { _, _ in }
        self.onSendTabInvite = nil
    }

    init(
        uiModel: LootUIModel,
        participantCount: Int,
        onScan: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onSendBill: @escaping (String, String) -> Void,
        onSendTabInvite: ((String, String, String) -> Void)? = nil
    ) {
        self.uiModel = uiModel
        self.participantCount = participantCount
        self.onScan = onScan
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onSendBill = onSendBill
        self.onSendTabInvite = onSendTabInvite
    }

    // MARK: - Helpers

    private func amountToCents(_ str: String) -> Int {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return 0 }

        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsPart = parts.count > 1 ? String(parts[1]) : ""
            let cents2: Int
            if centsPart.isEmpty {
                cents2 = 0
            } else if centsPart.count == 1 {
                cents2 = Int(centsPart + "0") ?? 0
            } else {
                cents2 = Int(String(centsPart.prefix(2))) ?? 0
            }
            return dollars * 100 + cents2
        } else {
            let dollars = Int(trimmed) ?? 0
            return dollars * 100
        }
    }

    private func makePreviewReceipt() -> ReceiptDisplay {
        let hasTip = !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
        
        let subtotalCents = amountToCents(amountString)
        let tipCents = hasTip ? amountToCents(tipAmount) : 0
        let totalCents = subtotalCents + tipCents
        
        return ReceiptDisplay(
            id: "preview",
            title: receiptName.isEmpty ? "New Receipt" : receiptName,
            createdAt: Date(),
            subtotalCents: subtotalCents,
            feesCents: 0,
            taxCents: 0,
            tipCents: tipCents,
            discountCents: 0,
            totalCents: totalCents,
            items: []
        )
    }

    private func startScanFlow() {
        onScan()
        analyzeError = nil
        capturedImage = nil
        showCamera = true
    }

    private func startPhotoLibraryFlow() {
        analyzeError = nil
        photoLibraryImage = nil
        showPhotoLibrary = true
    }

    private func analyzeCaptured(image: UIImage) {
        if DEBUG_OCR_ONLY {
            debugOCROnly(image: image)
            return
        }
        analyzeCapturedTwoPhase(image: image)
    }

    /// DEBUG: Run VisionKit OCR only and output structured JSON
    private func debugOCROnly(image: UIImage) {
        isAnalyzing = true
        analyzeError = nil

        Task {
            do {
                // STEP 0: Straighten image based on text angles
                print("[Debug] Original image size: \(image.size)")
                let (straightenedImage, straightenAngle) = try await straightenImage(image)
                print("[Debug] Straightened image size: \(straightenedImage.size)")
                print("[Debug] Rotation applied: \(String(format: "%.2f", straightenAngle))°")

                // STEP 0.5: Run OCR for skew detection and bounds
                print("[Debug] Running initial OCR for skew detection...")
                let initialOCR = try await runVisionKitOCR(image: straightenedImage)
                print("[Debug] Initial OCR: \(initialOCR.blocks.count) blocks")

                let newAngles = initialOCR.blocks.map { $0.angle }
                print("[Debug] Angles after straightening: \(newAngles.prefix(10).map { String(format: "%.1f", $0) }.joined(separator: ", "))\(newAngles.count > 10 ? "..." : "")")

                // STEP 0.6: Crop to OCR bounds (removes rotation padding)
                var workingImage = cropToOCRBounds(straightenedImage, ocrResult: initialOCR)
                print("[Debug] After OCR crop: \(workingImage.size)")

                // STEP 1: Iterative deskew - keep correcting until slope is minimal
                let maxDeskewIterations = 3
                let slopeThreshold = 0.015  // Stop when slope is below this

                for iteration in 1...maxDeskewIterations {
                    let iterOCR = try await runVisionKitOCR(image: workingImage)
                    print("[Debug] Deskew iteration \(iteration): \(iterOCR.blocks.count) blocks")

                    guard let slope = self.detectSkewSlope(from: iterOCR) else {
                        print("[Debug] Iteration \(iteration): No slope detected, stopping")
                        break
                    }

                    if abs(slope) < slopeThreshold {
                        print("[Debug] Iteration \(iteration): Slope \(String(format: "%.4f", slope)) below threshold, stopping")
                        break
                    }

                    print("[Debug] Iteration \(iteration): Applying shear correction for slope \(String(format: "%.4f", slope))")
                    workingImage = applyHorizontalShear(workingImage, slope: -slope)
                    print("[Debug] Iteration \(iteration): Deskewed image size: \(workingImage.size)")
                }

                // STEP 2: Enhance (2x upscale + high contrast) for final OCR
                print("[Debug] Applying image enhancement for final OCR...")
                workingImage = enhanceImageForOCR(workingImage)
                print("[Debug] Enhanced image size: \(workingImage.size)")

                // STEP 3: Run final OCR
                print("[Debug] Running final OCR...")
                let rawOCRResult = try await runVisionKitOCR(image: workingImage)
                print("[Debug] Final OCR: \(rawOCRResult.blocks.count) blocks")

                // PREPROCESSING PIPELINE (coordinate adjustments)
                let processedResult = preprocessOCR(rawOCRResult)

//                // Convert to JSON
//                let encoder = JSONEncoder()
//                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
//
//                print("=== RAW OCR RESULT (\(rawOCRResult.blocks.count) blocks) ===")
//                if let rawJson = try? encoder.encode(rawOCRResult),
//                   let rawStr = String(data: rawJson, encoding: .utf8) {
//                    print(rawStr)
//                }
//                print("=== PROCESSED OCR RESULT (\(processedResult.blocks.count) blocks) ===")
//                if let procJson = try? encoder.encode(processedResult),
//                   let procStr = String(data: procJson, encoding: .utf8) {
//                    print(procStr)
//                }
//                print("========================")

                await MainActor.run {
                    isAnalyzing = false
                    debugOCRResult = processedResult
                    debugOriginalImage = workingImage  // Use final processed image for debug view
                }
            } catch {
                print("[DEBUG OCR] Failed: \(error)")
                await MainActor.run {
                    isAnalyzing = false
                    analyzeError = "OCR failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // OCR types are defined in OCRTypes.swift

    // MARK: - Image Straightening

    /// Straighten and crop image based on detected text
    /// Returns the processed image and the angle it was rotated by
    private func straightenImage(_ image: UIImage) async throws -> (UIImage, Double) {
        // First, do a quick OCR pass to detect text angles and bounds
        let initialOCR = try await runVisionKitOCR(image: image)

        guard !initialOCR.blocks.isEmpty else {
            print("[Straighten] No text blocks found, returning original image")
            return (image, 0)
        }

        // Step 1: Crop to receipt bounds (remove background noise)
        let croppedImage = cropToReceiptBounds(image: image, ocrResult: initialOCR)

        // Step 2: Calculate rotation angle from initial OCR
        let angles = initialOCR.blocks.map { $0.angle }
        let averageAngle = calculateAverageAngleExcludingOutliers(angles)

        print("[Straighten] Detected \(angles.count) blocks, angles: \(angles.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        print("[Straighten] Average angle (excluding outliers): \(String(format: "%.2f", averageAngle))°")

        // If angle is very small, don't bother rotating
        guard abs(averageAngle) > 0.3 else {
            print("[Straighten] Angle \(String(format: "%.2f", averageAngle))° too small, skipping rotation")
            return (croppedImage, 0)
        }

        // Rotate image to counteract the detected angle
        // VisionKit uses bottom-left origin (Y up), UIKit uses top-left origin (Y down)
        // So we need to rotate by +averageAngle (not negative) to straighten
        print("[Straighten] Rotating image by \(String(format: "%.2f", averageAngle))°")
        let rotatedImage = rotateImage(croppedImage, byDegrees: averageAngle)

        print("[Straighten] Rotated image size: \(rotatedImage.size) (original: \(image.size))")

        // Note: Cropping now happens later using OCR bounds (more reliable)
        return (rotatedImage, averageAngle)
    }

    /// Crop image based on OCR text bounds (simple and reliable)
    private func cropToOCRBounds(_ image: UIImage, ocrResult: OCRResult) -> UIImage {
        guard !ocrResult.blocks.isEmpty, let cgImage = image.cgImage else { return image }

        // Find min/max X and Y from all OCR blocks
        let minX = ocrResult.blocks.map { $0.boundingBox.x }.min() ?? 0
        let maxX = ocrResult.blocks.map { $0.boundingBox.x + $0.boundingBox.width }.max() ?? 1
        let minY = ocrResult.blocks.map { $0.boundingBox.y }.min() ?? 0
        let maxY = ocrResult.blocks.map { $0.boundingBox.y + $0.boundingBox.height }.max() ?? 1

        // Add padding (5%)
        let padX = (maxX - minX) * 0.05
        let padY = (maxY - minY) * 0.05

        let cropMinX = max(0, minX - padX)
        let cropMaxX = min(1, maxX + padX)
        let cropMinY = max(0, minY - padY)
        let cropMaxY = min(1, maxY + padY)

        // Convert normalized coords to pixels
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // VisionKit uses bottom-left origin, CGImage uses top-left
        // So we need to flip Y: cgY = height - visionY
        let pixelX = Int(cropMinX * width)
        let pixelWidth = Int((cropMaxX - cropMinX) * width)
        let pixelY = Int((1 - cropMaxY) * height)  // Flip Y
        let pixelHeight = Int((cropMaxY - cropMinY) * height)

        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            print("[CropOCR] Cropping failed, returning original")
            return image
        }

        print("[CropOCR] Cropped from \(Int(width))x\(Int(height)) to \(pixelWidth)x\(pixelHeight)")

        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Crop image to remove empty padding (e.g., after rotation)
    /// Detects transparent, white, or black padding
    private func cropToContentBounds(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        // Fill with magenta so we can detect the rotation padding (which will be default/transparent)
        context.setFillColor(UIColor.magenta.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return image }
        let data = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, maxX = 0, minY = height, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]
                let a = data[offset + 3]

                // Check if pixel has content (not transparent, not magenta background)
                let isTransparent = a < 10
                let isMagenta = r > 240 && g < 15 && b > 240  // Our fill color
                let isBlack = r < 10 && g < 10 && b < 10

                if !isTransparent && !isMagenta && !isBlack {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        // Check if we found content
        guard minX < maxX && minY < maxY else {
            print("[CropContent] No content found, returning original")
            return image
        }

        // Add small padding (1%)
        let padX = max(5, Int(Double(maxX - minX) * 0.01))
        let padY = max(5, Int(Double(maxY - minY) * 0.01))

        let cropX = max(0, minX - padX)
        let cropY = max(0, minY - padY)
        let cropWidth = min(width - cropX, (maxX - minX) + padX * 2)
        let cropHeight = min(height - cropY, (maxY - minY) + padY * 2)

        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return image
        }

        print("[CropContent] Cropped from \(width)x\(height) to \(cropWidth)x\(cropHeight)")

        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Detect skew slope by finding columns and measuring their vertical alignment
    /// Uses column-based grouping for more accurate slope detection
    private func detectSkewSlope(from ocrResult: OCRResult) -> Double? {
        guard ocrResult.blocks.count >= 4 else {
            print("[Deskew] Not enough blocks (\(ocrResult.blocks.count)) to detect skew")
            return nil
        }

        // APPROACH: Group blocks into columns by X position, then measure slope of each column
        let blocks = ocrResult.blocks

        // Group blocks by approximate X position (left edge) to find columns
        // Use 8% width tolerance for same column
        let columnTolerance = 0.08
        var columns: [[OCRBlock]] = []

        for block in blocks {
            let blockX = block.boundingBox.x
            var foundColumn = false

            for i in 0..<columns.count {
                let columnX = columns[i][0].boundingBox.x
                if abs(blockX - columnX) < columnTolerance {
                    columns[i].append(block)
                    foundColumn = true
                    break
                }
            }

            if !foundColumn {
                columns.append([block])
            }
        }

        print("[Deskew] Found \(columns.count) potential columns: \(columns.map { $0.count }.sorted(by: >).prefix(5))")

        // For each column with 3+ blocks, calculate slope using linear regression
        var columnSlopes: [Double] = []

        for column in columns where column.count >= 3 {
            // Sort by Y (top to bottom = high Y to low Y)
            let sorted = column.sorted { $0.boundingBox.y > $1.boundingBox.y }

            // Calculate slope using all pairs (more robust than consecutive only)
            var pairSlopes: [Double] = []
            for i in 0..<sorted.count {
                for j in (i+1)..<sorted.count {
                    let dY = sorted[j].boundingBox.y - sorted[i].boundingBox.y
                    let dX = sorted[j].boundingBox.x - sorted[i].boundingBox.x
                    if abs(dY) > 0.02 {  // Need enough vertical separation
                        let slope = dX / dY
                        if abs(slope) < 0.5 {  // Reasonable slope
                            pairSlopes.append(slope)
                        }
                    }
                }
            }

            if pairSlopes.count >= 2 {
                // Use median of pairs for this column
                let sortedPairs = pairSlopes.sorted()
                let medianSlope = sortedPairs[sortedPairs.count / 2]
                columnSlopes.append(medianSlope)
                print("[Deskew] Column with \(column.count) blocks, slope: \(String(format: "%.4f", medianSlope))")
            }
        }

        // Also use consecutive-block approach as fallback
        let sortedByY = blocks.sorted { $0.boundingBox.y > $1.boundingBox.y }
        var consecutiveSlopes: [Double] = []

        for i in 0..<(sortedByY.count - 1) {
            let current = sortedByY[i]
            let next = sortedByY[i + 1]

            let dY = next.boundingBox.y - current.boundingBox.y
            guard abs(dY) > 0.008 else { continue }

            let dX = next.boundingBox.x - current.boundingBox.x
            let slope = dX / dY

            if abs(slope) < 0.5 && abs(dX) < 0.1 {  // Only if blocks are close horizontally
                consecutiveSlopes.append(slope)
            }
        }

        print("[Deskew] Consecutive slopes: \(consecutiveSlopes.map { String(format: "%.4f", $0) }.prefix(10).joined(separator: ", "))\(consecutiveSlopes.count > 10 ? "..." : "")")

        // Combine column slopes with consecutive slopes
        var allSlopes = columnSlopes
        allSlopes.append(contentsOf: consecutiveSlopes)

        guard allSlopes.count >= 2 else {
            print("[Deskew] Not enough slope samples")
            return nil
        }

        // Find the most common slope using clustering
        let clusterTolerance = 0.06
        var bestCluster: [Double] = []

        for slope in allSlopes {
            let cluster = allSlopes.filter { abs($0 - slope) < clusterTolerance }
            if cluster.count > bestCluster.count {
                bestCluster = cluster
            }
        }

        guard bestCluster.count >= 2 else {
            print("[Deskew] No consistent slope pattern (best cluster: \(bestCluster.count))")
            return nil
        }

        // Use median of cluster, with slight amplification for under-correction
        let sortedCluster = bestCluster.sorted()
        let medianSlope = sortedCluster[sortedCluster.count / 2]
        let amplifiedSlope = medianSlope * 1.15  // Slight amplification for under-correction

        print("[Deskew] Found column pattern with \(bestCluster.count) consistent slopes")
        print("[Deskew] Slope cluster: \(bestCluster.map { String(format: "%.4f", $0) }.joined(separator: ", "))")
        print("[Deskew] Median slope: \(String(format: "%.4f", medianSlope)), amplified: \(String(format: "%.4f", amplifiedSlope))")

        return amplifiedSlope
    }

    /// Calculate slope (dX/dY) for a set of blocks using average rate of change, excluding outliers
    private func calculateColumnSlope(_ blocks: [OCRBlock]) -> Double? {
        guard blocks.count >= 3 else { return nil }

        // Sort blocks by Y position (top to bottom in VisionKit coords = high Y to low Y)
        let sortedBlocks = blocks.sorted { $0.boundingBox.y > $1.boundingBox.y }

        // Calculate rate of change (dX/dY) between consecutive blocks
        var slopes: [Double] = []
        for i in 0..<(sortedBlocks.count - 1) {
            let current = sortedBlocks[i]
            let next = sortedBlocks[i + 1]

            let currentX = current.boundingBox.x + current.boundingBox.width / 2
            let currentY = current.boundingBox.y + current.boundingBox.height / 2
            let nextX = next.boundingBox.x + next.boundingBox.width / 2
            let nextY = next.boundingBox.y + next.boundingBox.height / 2

            let dY = nextY - currentY
            guard abs(dY) > 0.001 else { continue }  // Skip if blocks are at same Y

            let dX = nextX - currentX
            let slope = dX / dY
            slopes.append(slope)
        }

        guard slopes.count >= 2 else { return nil }

        // Use IQR method to exclude outliers and get average
        return calculateAverageSlopeExcludingOutliers(slopes)
    }

    /// Calculate average slope excluding outliers using IQR method
    private func calculateAverageSlopeExcludingOutliers(_ slopes: [Double]) -> Double? {
        guard !slopes.isEmpty else { return nil }
        guard slopes.count >= 4 else {
            // Not enough data for outlier detection, just average
            return slopes.reduce(0, +) / Double(slopes.count)
        }

        let sorted = slopes.sorted()
        let q1Index = sorted.count / 4
        let q3Index = (sorted.count * 3) / 4

        let q1 = sorted[q1Index]
        let q3 = sorted[q3Index]
        let iqr = q3 - q1

        // Filter out outliers (values outside 1.5 * IQR from quartiles)
        let lowerBound = q1 - 1.5 * iqr
        let upperBound = q3 + 1.5 * iqr

        let filtered = slopes.filter { $0 >= lowerBound && $0 <= upperBound }

        guard !filtered.isEmpty else {
            // All values were outliers? Fall back to median
            return sorted[sorted.count / 2]
        }

        let average = filtered.reduce(0, +) / Double(filtered.count)

        if filtered.count < slopes.count {
            print("[Deskew] Excluded \(slopes.count - filtered.count) slope outlier(s)")
        }

        return average
    }

    /// Apply horizontal shear transform to correct perspective skew
    /// Uses Core Image for GPU-accelerated, memory-efficient processing
    private func applyHorizontalShear(_ image: UIImage, slope: Double) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

        // CIAffineTransform for shear: x' = x + slope * y
        // Matrix: [1, 0, slope, 1, 0, 0]
        let shearTransform = CGAffineTransform(a: 1, b: 0, c: CGFloat(slope), d: 1, tx: 0, ty: 0)

        let transformed = ciImage.transformed(by: shearTransform)

        // Translate to keep image in positive coordinates
        let translatedImage = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.origin.x, y: -transformed.extent.origin.y))

        // Render using shared context
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(translatedImage, from: translatedImage.extent) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Crop image to receipt bounds, removing background noise
    private func cropToReceiptBounds(image: UIImage, ocrResult: OCRResult) -> UIImage {
        guard !ocrResult.blocks.isEmpty else { return image }

        // Collect X bounds (left edge and right edge) of all blocks
        let leftEdges = ocrResult.blocks.map { $0.boundingBox.x }
        let rightEdges = ocrResult.blocks.map { $0.boundingBox.x + $0.boundingBox.width }

        // Use IQR to find typical bounds, excluding outliers
        let typicalLeft = findTypicalMinimum(leftEdges)
        let typicalRight = findTypicalMaximum(rightEdges)

        // Also get Y bounds
        let topEdges = ocrResult.blocks.map { $0.boundingBox.y + $0.boundingBox.height }
        let bottomEdges = ocrResult.blocks.map { $0.boundingBox.y }

        let typicalTop = findTypicalMaximum(topEdges)
        let typicalBottom = findTypicalMinimum(bottomEdges)

        print("[Crop] X bounds: \(String(format: "%.3f", typicalLeft)) - \(String(format: "%.3f", typicalRight))")
        print("[Crop] Y bounds: \(String(format: "%.3f", typicalBottom)) - \(String(format: "%.3f", typicalTop))")

        // Add small padding (2%)
        let padding = 0.02
        let cropLeft = max(0, typicalLeft - padding)
        let cropRight = min(1, typicalRight + padding)
        let cropBottom = max(0, typicalBottom - padding)
        let cropTop = min(1, typicalTop + padding)

        // Check if crop is significantly different from full image
        let cropWidth = cropRight - cropLeft
        let cropHeight = cropTop - cropBottom

        if cropWidth > 0.95 && cropHeight > 0.95 {
            print("[Crop] Bounds cover most of image, skipping crop")
            return image
        }

        // Convert normalized coords to pixel coords
        // Note: VisionKit Y is bottom-up, UIKit Y is top-down
        let imageWidth = image.size.width
        let imageHeight = image.size.height

        let pixelX = cropLeft * imageWidth
        let pixelWidth = cropWidth * imageWidth
        // Flip Y for UIKit coordinate system
        let pixelY = (1 - cropTop) * imageHeight
        let pixelHeight = cropHeight * imageHeight

        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)

        print("[Crop] Cropping to rect: \(cropRect)")

        guard let cgImage = image.cgImage,
              let croppedCGImage = cgImage.cropping(to: cropRect) else {
            print("[Crop] Failed to crop, returning original")
            return image
        }

        let croppedImage = UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
        print("[Crop] Cropped image size: \(croppedImage.size) (original: \(image.size))")

        return croppedImage
    }

    /// Find typical minimum value excluding low outliers
    private func findTypicalMinimum(_ values: [Double]) -> Double {
        guard values.count >= 4 else {
            return values.min() ?? 0
        }

        let sorted = values.sorted()
        let q1 = sorted[sorted.count / 4]
        let q3 = sorted[(sorted.count * 3) / 4]
        let iqr = q3 - q1

        // Lower bound for outliers
        let lowerBound = q1 - 1.5 * iqr

        // Find minimum that's not an outlier
        let filtered = sorted.filter { $0 >= lowerBound }
        return filtered.min() ?? sorted[0]
    }

    /// Find typical maximum value excluding high outliers
    private func findTypicalMaximum(_ values: [Double]) -> Double {
        guard values.count >= 4 else {
            return values.max() ?? 1
        }

        let sorted = values.sorted()
        let q1 = sorted[sorted.count / 4]
        let q3 = sorted[(sorted.count * 3) / 4]
        let iqr = q3 - q1

        // Upper bound for outliers
        let upperBound = q3 + 1.5 * iqr

        // Find maximum that's not an outlier
        let filtered = sorted.filter { $0 <= upperBound }
        return filtered.max() ?? sorted[sorted.count - 1]
    }

    /// Calculate average angle excluding outliers using IQR method
    private func calculateAverageAngleExcludingOutliers(_ angles: [Double]) -> Double {
        guard !angles.isEmpty else { return 0 }
        guard angles.count >= 4 else {
            // Not enough data for outlier detection, just average
            return angles.reduce(0, +) / Double(angles.count)
        }

        let sorted = angles.sorted()
        let q1Index = sorted.count / 4
        let q3Index = (sorted.count * 3) / 4

        let q1 = sorted[q1Index]
        let q3 = sorted[q3Index]
        let iqr = q3 - q1

        // Filter out outliers (values outside 1.5 * IQR from quartiles)
        let lowerBound = q1 - 1.5 * iqr
        let upperBound = q3 + 1.5 * iqr

        let filtered = angles.filter { $0 >= lowerBound && $0 <= upperBound }

        guard !filtered.isEmpty else {
            // All values were outliers? Fall back to median
            return sorted[sorted.count / 2]
        }

        let average = filtered.reduce(0, +) / Double(filtered.count)

        if filtered.count < angles.count {
            print("[Straighten] Excluded \(angles.count - filtered.count) outlier(s)")
        }

        return average
    }

    /// Rotate a UIImage by the specified degrees
    private func rotateImage(_ image: UIImage, byDegrees degrees: Double) -> UIImage {
        guard abs(degrees) > 0.01 else { return image }

        let radians = CGFloat(degrees * .pi / 180)

        // Calculate new size to fit rotated image
        let originalRect = CGRect(origin: .zero, size: image.size)
        let rotatedRect = originalRect.applying(CGAffineTransform(rotationAngle: radians))

        let newSize = CGSize(
            width: abs(rotatedRect.width),
            height: abs(rotatedRect.height)
        )

        // Use UIGraphicsImageRenderer for better quality
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let rotatedImage = renderer.image { context in
            let cgContext = context.cgContext

            // Move to center, rotate, then translate back
            cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cgContext.rotate(by: radians)
            cgContext.translateBy(x: -image.size.width / 2, y: -image.size.height / 2)

            // Draw the image
            image.draw(at: .zero)
        }

        return rotatedImage
    }

    // MARK: - Image Enhancement for OCR

    /// Upscale image for better OCR recognition
    private func upscaleImage(_ image: UIImage, scale: CGFloat) -> UIImage {
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Enhance image for better OCR recognition
    private func enhanceImageForOCR(_ image: UIImage) -> UIImage {
        // Upscale 2x for better OCR on small text
        let upscaled = upscaleImage(image, scale: 2.0)

        guard let ciImage = CIImage(image: upscaled) else { return upscaled }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var outputImage = ciImage

        // Boost exposure slightly to brighten dark areas
        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(outputImage, forKey: kCIInputImageKey)
            exposureFilter.setValue(0.3, forKey: kCIInputEVKey)
            if let result = exposureFilter.outputImage {
                outputImage = result
            }
        }

        // Dramatic contrast increase for better text visibility
        if let contrastFilter = CIFilter(name: "CIColorControls") {
            contrastFilter.setValue(outputImage, forKey: kCIInputImageKey)
            contrastFilter.setValue(1.25, forKey: kCIInputContrastKey)  // High contrast
            contrastFilter.setValue(0.05, forKey: kCIInputBrightnessKey)  // Slight brightness
            if let result = contrastFilter.outputImage {
                outputImage = result
            }
        }

        // Strong sharpening for crisp text edges
        if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(outputImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(0.8, forKey: kCIInputSharpnessKey)  // High sharpening
            if let result = sharpenFilter.outputImage {
                outputImage = result
            }
        }

        // Unsharp mask for additional edge enhancement
        if let unsharpFilter = CIFilter(name: "CIUnsharpMask") {
            unsharpFilter.setValue(outputImage, forKey: kCIInputImageKey)
            unsharpFilter.setValue(2.5, forKey: kCIInputRadiusKey)
            unsharpFilter.setValue(0.5, forKey: kCIInputIntensityKey)
            if let result = unsharpFilter.outputImage {
                outputImage = result
            }
        }

        // Render the final image
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return upscaled
        }

        return UIImage(cgImage: cgImage, scale: upscaled.scale, orientation: upscaled.imageOrientation)
    }

    /// Apply adaptive thresholding for better text/background separation
    /// Useful for receipts with varying lighting conditions
    private func applyAdaptiveEnhancement(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var outputImage = ciImage

        // Use exposure adjustment to normalize brightness
        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(outputImage, forKey: kCIInputImageKey)
            exposureFilter.setValue(0.3, forKey: kCIInputEVKey)  // Slight exposure boost
            if let result = exposureFilter.outputImage {
                outputImage = result
            }
        }

        // Apply highlight/shadow adjustment for better dynamic range
        if let highlightFilter = CIFilter(name: "CIHighlightShadowAdjust") {
            highlightFilter.setValue(outputImage, forKey: kCIInputImageKey)
            highlightFilter.setValue(0.3, forKey: "inputHighlightAmount")  // Reduce highlights
            highlightFilter.setValue(-0.3, forKey: "inputShadowAmount")  // Lighten shadows
            if let result = highlightFilter.outputImage {
                outputImage = result
            }
        }

        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - OCR Preprocessing Pipeline

    /// Main preprocessing function - runs all preprocessing steps in order
    private func preprocessOCR(_ input: OCRResult) -> OCRResult {
        var result = input

        // Step 0: Deskew coordinates - DISABLED since we now deskew the image itself
        // The image shear is applied before final OCR, so coordinates are already correct
        // result = preprocessDeskewCoordinates(result)

        // Step 1: Fix common OCR errors and merge split prices
        result = preprocessFixPriceText(result)

        // Step 2: Split blocks that contain both text and amounts
        // This separates "Item $12.99" into ["Item", "$12.99"]
        result = preprocessSplitAmounts(result)

        // Step 3: Crop to items section (first price to last price)
        // Now that prices are separate blocks, we can find them reliably
        result = preprocessCropToItemsSection(result)

        // Step 4: Clean amount blocks to pure decimal format
        // Strips $, F, and other chars, leaving just numbers like "12.99"
        result = preprocessCleanAmounts(result)

        return result
    }

    /// Clean amount/price blocks to pure decimal format
    /// Removes $, F, and other non-numeric chars, leaving clean decimals
    private func preprocessCleanAmounts(_ input: OCRResult) -> OCRResult {
        var blocks = input.blocks

        // Pattern to identify price-like blocks (may have $, F, etc.)
        // Matches: $12.99, 12.99, $12.99F, $1,234.56, etc.
        // Group 1: dollars (with optional comma separators)
        // Group 2: cents
        let pricePattern = #"^[\$\s]*(\d{1,3}(?:,\d{3})*|\d+)[.,](\d{2})\s*[A-Za-z]?$"#
        let priceRegex = try? NSRegularExpression(pattern: pricePattern, options: [])

        blocks = blocks.map { block in
            var newBlock = block
            let text = block.text.trimmingCharacters(in: .whitespaces)

            // Check if this looks like a price
            if let regex = priceRegex,
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
                // Extract the numeric parts
                if let dollarsRange = Range(match.range(at: 1), in: text),
                   let centsRange = Range(match.range(at: 2), in: text) {
                    // Remove commas from dollars part
                    let dollars = String(text[dollarsRange]).replacingOccurrences(of: ",", with: "")
                    let cents = String(text[centsRange])
                    // Format as clean decimal
                    newBlock.text = "\(dollars).\(cents)"
                }
            }

            return newBlock
        }

        return OCRResult(imageWidth: input.imageWidth, imageHeight: input.imageHeight, blocks: blocks)
    }

    /// Fix common OCR errors in price text and merge split price blocks
    private func preprocessFixPriceText(_ input: OCRResult) -> OCRResult {
        var blocks = input.blocks

        // Step A: Fix text in each block
        blocks = blocks.map { block in
            var fixedText = block.text

            // Fix "$" misread as "S" at start of price-like text
            // Only fix "S" (not "5") since "5" is ambiguous (could be $500 or 5500)
            // Pattern: S followed by digits (e.g., "S30.00" -> "$30.00")
            let dollarFixPattern = #"^S(\d{1,3}[.,\s]?\d{0,2})$"#
            if let regex = try? NSRegularExpression(pattern: dollarFixPattern, options: []),
               regex.firstMatch(in: fixedText, options: [], range: NSRange(fixedText.startIndex..., in: fixedText)) != nil {
                fixedText = "$" + String(fixedText.dropFirst())
                print("[FixPrice] Fixed S->$: \"\(block.text)\" -> \"\(fixedText)\"")
            }

            // Fix spaces around decimal point (e.g., "196. 02" -> "196.02", "196 .02" -> "196.02")
            let spacedDecimalPattern = #"(\d+)\s*\.\s*(\d{2})$"#
            if let regex = try? NSRegularExpression(pattern: spacedDecimalPattern, options: []),
               let match = regex.firstMatch(in: fixedText, options: [], range: NSRange(fixedText.startIndex..., in: fixedText)) {
                let range1 = Range(match.range(at: 1), in: fixedText)!
                let range2 = Range(match.range(at: 2), in: fixedText)!
                let wholePart = String(fixedText[range1])
                let decimalPart = String(fixedText[range2])
                let prefix = String(fixedText[..<range1.lowerBound])
                let newText = prefix + wholePart + "." + decimalPart
                if newText != fixedText {
                    print("[FixPrice] Fixed spaced decimal: \"\(fixedText)\" -> \"\(newText)\"")
                    fixedText = newText
                }
            }

            // Fix space or comma as decimal separator (e.g., "30 00" -> "30.00", "30,00" -> "30.00")
            // Pattern: digits followed by space/comma and exactly 2 digits at end
            let decimalFixPattern = #"(\d+)[,\s](\d{2})$"#
            if let regex = try? NSRegularExpression(pattern: decimalFixPattern, options: []),
               let match = regex.firstMatch(in: fixedText, options: [], range: NSRange(fixedText.startIndex..., in: fixedText)) {
                let range1 = Range(match.range(at: 1), in: fixedText)!
                let range2 = Range(match.range(at: 2), in: fixedText)!
                let wholePart = String(fixedText[range1])
                let decimalPart = String(fixedText[range2])
                let prefix = String(fixedText[..<range1.lowerBound])

                // Skip if prefix is all digits/spaces - likely a card number, phone, etc.
                // e.g., "00 00 00 03 10 10" has prefix "00 00 00 03 " which is all digits/spaces
                let prefixIsNumberSequence = prefix.allSatisfy { $0.isNumber || $0.isWhitespace }
                let prefixHasDigits = prefix.contains(where: { $0.isNumber })

                if prefixIsNumberSequence && prefixHasDigits {
                    // Don't convert - this looks like a continuous number sequence
                    print("[FixPrice] Skipping decimal fix (number sequence): \"\(fixedText)\"")
                } else {
                    let newText = prefix + wholePart + "." + decimalPart
                    if newText != fixedText {
                        print("[FixPrice] Fixed decimal: \"\(fixedText)\" -> \"\(newText)\"")
                        fixedText = newText
                    }
                }
            }

            if fixedText != block.text {
                return OCRBlock(
                    text: fixedText,
                    confidence: block.confidence,
                    boundingBox: block.boundingBox,
                    angle: block.angle,
                    words: block.words
                )
            }
            return block
        }

        // Step B: Merge adjacent blocks that look like split prices
        // e.g., "$30" + "00" on same line should become "$30.00"
        var mergedBlocks: [OCRBlock] = []
        var skipNext = false

        // Sort by Y (top to bottom), then X (left to right)
        let sortedBlocks = blocks.sorted { a, b in
            if abs(a.boundingBox.y - b.boundingBox.y) > 0.015 {
                return a.boundingBox.y > b.boundingBox.y
            }
            return a.boundingBox.x < b.boundingBox.x
        }

        for i in 0..<sortedBlocks.count {
            if skipNext {
                skipNext = false
                continue
            }

            let current = sortedBlocks[i]

            // Check if there's a next block on the same line
            if i + 1 < sortedBlocks.count {
                let next = sortedBlocks[i + 1]

                // Same line? (Y positions close)
                let sameLine = abs(current.boundingBox.y - next.boundingBox.y) < 0.015

                // Adjacent? (next block starts near where current ends)
                let currentRight = current.boundingBox.x + current.boundingBox.width
                let gap = next.boundingBox.x - currentRight
                let adjacent = gap < 0.03 && gap > -0.01  // Small gap or slight overlap

                if sameLine && adjacent {
                    // Check if this looks like a split price
                    // Current ends with $ or digit, next is 2 digits
                    let currentEndsWithPrice = current.text.range(of: #"[\$\d]$"#, options: .regularExpression) != nil
                    let nextIsTwoDigits = next.text.range(of: #"^\d{2}$"#, options: .regularExpression) != nil

                    if currentEndsWithPrice && nextIsTwoDigits {
                        // Merge them with a decimal point
                        let mergedText = current.text + "." + next.text
                        print("[FixPrice] Merged split price: \"\(current.text)\" + \"\(next.text)\" -> \"\(mergedText)\"")

                        let mergedBbox = OCRBoundingBox(
                            x: current.boundingBox.x,
                            y: min(current.boundingBox.y, next.boundingBox.y),
                            width: (next.boundingBox.x + next.boundingBox.width) - current.boundingBox.x,
                            height: max(current.boundingBox.height, next.boundingBox.height),
                            pixelX: current.boundingBox.pixelX,
                            pixelY: min(current.boundingBox.pixelY, next.boundingBox.pixelY),
                            pixelWidth: (next.boundingBox.pixelX + next.boundingBox.pixelWidth) - current.boundingBox.pixelX,
                            pixelHeight: max(current.boundingBox.pixelHeight, next.boundingBox.pixelHeight)
                        )

                        mergedBlocks.append(OCRBlock(
                            text: mergedText,
                            confidence: min(current.confidence, next.confidence),
                            boundingBox: mergedBbox,
                            angle: current.angle,
                            words: []
                        ))
                        skipNext = true
                        continue
                    }
                }
            }

            mergedBlocks.append(current)
        }

        return OCRResult(
            imageWidth: input.imageWidth,
            imageHeight: input.imageHeight,
            blocks: mergedBlocks
        )
    }

    /// Regex pattern for detecting prices
    private var priceRegexPattern: String {
        #"\$?\d{1,3}(?:,\d{3})*\.?\d{0,2}\s*[A-Za-z]?"#
    }

    /// Step 0: Deskew coordinates by adjusting X based on detected column slope
    /// This corrects for perspective distortion without transforming the image
    /// Runs two passes for better accuracy
    private func preprocessDeskewCoordinates(_ input: OCRResult) -> OCRResult {
        var result = input

        // Pass 1: Initial deskew
        if let slope1 = detectSkewSlope(from: result), abs(slope1) > 0.02 {
            print("[Preprocess] Deskew Pass 1: Correcting with slope \(String(format: "%.4f", slope1))")
            result = applyCoordinateDeskew(result, slope: slope1)

            // Pass 2: Refine with second detection on adjusted coordinates
            if let slope2 = detectSkewSlope(from: result), abs(slope2) > 0.01 {
                print("[Preprocess] Deskew Pass 2: Refining with slope \(String(format: "%.4f", slope2))")
                result = applyCoordinateDeskew(result, slope: slope2)
            } else {
                print("[Preprocess] Deskew Pass 2: No significant remaining skew")
            }
        } else {
            print("[Preprocess] Deskew: No significant skew detected")
        }

        return result
    }

    /// Apply coordinate deskew adjustment
    private func applyCoordinateDeskew(_ input: OCRResult, slope: Double) -> OCRResult {
        // Find the center Y of the image (normalized 0-1)
        let centerY = 0.5

        // Adjust each block's X coordinate based on its Y position
        // Formula: new_x = old_x - slope * (y - centerY)
        // This shifts blocks horizontally to align columns vertically
        let adjustedBlocks = input.blocks.map { block -> OCRBlock in
            let blockCenterY = block.boundingBox.y + block.boundingBox.height / 2
            let xAdjustment = slope * (blockCenterY - centerY)

            let newX = block.boundingBox.x - xAdjustment
            let newBbox = OCRBoundingBox(
                x: newX,
                y: block.boundingBox.y,
                width: block.boundingBox.width,
                height: block.boundingBox.height,
                pixelX: Int(newX * Double(input.imageWidth)),
                pixelY: block.boundingBox.pixelY,
                pixelWidth: block.boundingBox.pixelWidth,
                pixelHeight: block.boundingBox.pixelHeight
            )

            return OCRBlock(
                text: block.text,
                confidence: block.confidence,
                boundingBox: newBbox,
                angle: block.angle,
                words: block.words
            )
        }

        return OCRResult(
            imageWidth: input.imageWidth,
            imageHeight: input.imageHeight,
            blocks: adjustedBlocks
        )
    }

    /// Check if a price string represents a non-zero value
    private func isNonZeroPrice(_ text: String) -> Bool {
        // Extract numeric value from price string
        let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        guard let value = Double(cleaned) else { return false }
        return value > 0.001  // Treat anything <= 0.00 as zero
    }

    /// Step: Crop to items section by finding first and last price lines
    /// Removes header (store name, address) and footer (thank you, etc.)
    private func preprocessCropToItemsSection(_ input: OCRResult) -> OCRResult {
        // Stricter regex for standalone price blocks (after split, prices should be mostly alone)
        // Requires either $ sign OR decimal point to avoid matching plain numbers like "123"
        let standalonePricePattern = #"^\s*(\$\d{1,3}(?:,\d{3})*\.?\d{0,2}|\d{1,3}(?:,\d{3})*\.\d{2})\s*[A-Za-z]?\s*$"#
        let priceRegex = try? NSRegularExpression(pattern: standalonePricePattern, options: [])

        // Find all blocks that contain a non-zero price
        var blocksWithPrices: [(block: OCRBlock, index: Int)] = []

        for (index, block) in input.blocks.enumerated() {
            let text = block.text
            if let regex = priceRegex,
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil,
               isNonZeroPrice(text) {  // Exclude $0.00 prices
                blocksWithPrices.append((block, index))
            }
        }

        guard !blocksWithPrices.isEmpty else {
            print("[Preprocess] CropToItems: No prices found, keeping all blocks")
            return input
        }

        // VisionKit uses bottom-left origin:
        // - Higher Y = higher on screen (top of receipt)
        // - Lower Y = lower on screen (bottom of receipt)
        // So: blocks ABOVE first price have HIGHER Y values (remove these)
        //     blocks BELOW last price have LOWER Y values (remove these)

        // Find the FIRST price (topmost = highest Y value among prices)
        let firstPriceBlock = blocksWithPrices.max(by: { $0.block.boundingBox.y < $1.block.boundingBox.y })!
        let firstPriceCenterY = firstPriceBlock.block.boundingBox.y + firstPriceBlock.block.boundingBox.height / 2

        // Find the LAST price (bottommost = lowest Y, then rightmost X among those)
        let minY = blocksWithPrices.map { $0.block.boundingBox.y }.min()!
        let bottomBlocks = blocksWithPrices.filter { abs($0.block.boundingBox.y - minY) < 0.02 }
        let lastPriceBlock = bottomBlocks.max(by: { $0.block.boundingBox.x < $1.block.boundingBox.x })!
        let lastPriceCenterY = lastPriceBlock.block.boundingBox.y + lastPriceBlock.block.boundingBox.height / 2

        print("[Preprocess] CropToItems: First price \"\(firstPriceBlock.block.text)\" centerY=\(String(format: "%.3f", firstPriceCenterY))")
        print("[Preprocess] CropToItems: Last price \"\(lastPriceBlock.block.text)\" centerY=\(String(format: "%.3f", lastPriceCenterY))")

        // Filter blocks by their center Y position
        let firstPriceTolerance = 0.02  // 2% tolerance for first price
        let lastPriceTolerance = 0.02  // 2% tolerance for last price
        let filteredBlocks = input.blocks.filter { block in
            let blockCenterY = block.boundingBox.y + block.boundingBox.height / 2

            // Keep blocks whose center is:
            // - At or below first price (centerY <= firstPriceCenterY) -- removes headers
            // - At or above last price (centerY >= lastPriceCenterY) -- removes footers
            let belowFirstPrice = blockCenterY <= firstPriceCenterY + firstPriceTolerance
            let aboveLastPrice = blockCenterY >= lastPriceCenterY - lastPriceTolerance

            let keep = belowFirstPrice && aboveLastPrice

            if !keep {
                print("[Preprocess] CropToItems: Removing \"\(block.text)\" centerY=\(String(format: "%.3f", blockCenterY))")
            }

            return keep
        }

        let removedCount = input.blocks.count - filteredBlocks.count
        print("[Preprocess] CropToItems: Removed \(removedCount) blocks, kept \(filteredBlocks.count)")

        return OCRResult(
            imageWidth: input.imageWidth,
            imageHeight: input.imageHeight,
            blocks: filteredBlocks
        )
    }

    /// Step 1: Split blocks that have item text + amount into separate blocks
    /// e.g., "Burger $12.99" -> ["Burger", "$12.99"]
    private func preprocessSplitAmounts(_ input: OCRResult) -> OCRResult {
        var newBlocks: [OCRBlock] = []

        // Regex to match price patterns at the end of a string
        // REQUIRES decimal point to avoid matching zip codes, suite numbers, etc.
        // Matches: $12.99, 12.99, $1,234.56, $12.99F (with decimal required)
        let pricePattern = #"^(.+?)\s+(\$?\d{1,3}(?:,\d{3})*\.\d{2}\s*[A-Za-z]?)\s*$"#
        let priceRegex = try? NSRegularExpression(pattern: pricePattern, options: [])

        for block in input.blocks {
            let text = block.text.trimmingCharacters(in: .whitespaces)

            // Check if this block contains text followed by a price
            if let regex = priceRegex,
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges == 3 {

                // Extract the two parts
                let itemRange = Range(match.range(at: 1), in: text)!
                let priceRange = Range(match.range(at: 2), in: text)!

                let itemText = String(text[itemRange]).trimmingCharacters(in: .whitespaces)
                let priceText = String(text[priceRange]).trimmingCharacters(in: .whitespaces)

                // Only split if we have meaningful text on both sides
                guard !itemText.isEmpty && !priceText.isEmpty else {
                    newBlocks.append(block)
                    continue
                }

                // Calculate approximate positions for the split
                // Estimate based on character count ratio
                let totalLen = Double(text.count)
                let itemLen = Double(itemText.count)
                let priceLen = Double(priceText.count)

                // Item takes the left portion, price takes the right
                let itemWidthRatio = (itemLen / totalLen) * 0.9  // Give some margin
                let priceWidthRatio = (priceLen / totalLen) * 1.1

                let originalBox = block.boundingBox

                // Create item block (left side)
                let itemBox = OCRBoundingBox.make(
                    x: originalBox.x,
                    y: originalBox.y,
                    width: originalBox.width * itemWidthRatio,
                    height: originalBox.height,
                    imageWidth: input.imageWidth,
                    imageHeight: input.imageHeight
                )

                let itemBlock = OCRBlock(
                    text: itemText,
                    confidence: block.confidence,
                    boundingBox: itemBox,
                    angle: block.angle,
                    words: []  // We don't preserve word-level data for split blocks
                )

                // Create price block (right side)
                let priceX = originalBox.x + originalBox.width * (1 - priceWidthRatio)
                let priceBox = OCRBoundingBox.make(
                    x: priceX,
                    y: originalBox.y,
                    width: originalBox.width * priceWidthRatio,
                    height: originalBox.height,
                    imageWidth: input.imageWidth,
                    imageHeight: input.imageHeight
                )

                let priceBlock = OCRBlock(
                    text: priceText,
                    confidence: block.confidence,
                    boundingBox: priceBox,
                    angle: block.angle,
                    words: []
                )

                newBlocks.append(itemBlock)
                newBlocks.append(priceBlock)

                print("[Preprocess] Split: \"\(text)\" -> [\"\(itemText)\", \"\(priceText)\"]")
            } else {
                // No split needed, keep original
                newBlocks.append(block)
            }
        }

        return OCRResult(
            imageWidth: input.imageWidth,
            imageHeight: input.imageHeight,
            blocks: newBlocks
        )
    }

    /// Run VisionKit text recognition and extract structured data
    private func runVisionKitOCR(image: UIImage) async throws -> OCRResult {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get CGImage"])
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(imageWidth: imageWidth, imageHeight: imageHeight, blocks: []))
                    return
                }

                var blocks: [OCRBlock] = []

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }

                    let bbox = observation.boundingBox

                    // Calculate angle from the observation's transform if available
                    // VisionKit doesn't directly give angle, but we can estimate from bounding box corners
                    let angle = self.estimateTextAngle(observation: observation)

                    // Get word-level recognition
                    var words: [OCRWord] = []

                    // Try to get individual word boxes (VisionKit 2.0+)
                    let wordRanges = self.getWordRanges(from: topCandidate.string)
                    for range in wordRanges {
                        if let wordBox = try? topCandidate.boundingBox(for: range) {
                            let wordBbox = wordBox.boundingBox
                            words.append(OCRWord(
                                text: String(topCandidate.string[range]),
                                confidence: topCandidate.confidence,
                                boundingBox: OCRBoundingBox(
                                    x: wordBbox.origin.x,
                                    y: wordBbox.origin.y,
                                    width: wordBbox.width,
                                    height: wordBbox.height,
                                    pixelX: Int(wordBbox.origin.x * Double(imageWidth)),
                                    pixelY: Int(wordBbox.origin.y * Double(imageHeight)),
                                    pixelWidth: Int(wordBbox.width * Double(imageWidth)),
                                    pixelHeight: Int(wordBbox.height * Double(imageHeight))
                                )
                            ))
                        }
                    }

                    let block = OCRBlock(
                        text: topCandidate.string,
                        confidence: topCandidate.confidence,
                        boundingBox: OCRBoundingBox(
                            x: bbox.origin.x,
                            y: bbox.origin.y,
                            width: bbox.width,
                            height: bbox.height,
                            pixelX: Int(bbox.origin.x * Double(imageWidth)),
                            pixelY: Int(bbox.origin.y * Double(imageHeight)),
                            pixelWidth: Int(bbox.width * Double(imageWidth)),
                            pixelHeight: Int(bbox.height * Double(imageHeight))
                        ),
                        angle: angle,
                        words: words
                    )
                    blocks.append(block)
                }

                // Sort blocks by Y position (top to bottom), then X (left to right)
                blocks.sort { a, b in
                    // Higher Y value = higher on screen (VisionKit uses bottom-left origin)
                    if abs(a.boundingBox.y - b.boundingBox.y) > 0.01 {
                        return a.boundingBox.y > b.boundingBox.y
                    }
                    return a.boundingBox.x < b.boundingBox.x
                }

                continuation.resume(returning: OCRResult(
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    blocks: blocks
                ))
            }

            // Configure for best accuracy and sensitivity
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.0  // Pick up even very small text (0.0 = no minimum)
            request.revision = VNRecognizeTextRequestRevision3  // Use latest revision for better recognition

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Estimate text angle from observation (rough approximation)
    private func estimateTextAngle(observation: VNRecognizedTextObservation) -> Double {
        // Get the four corners of the bounding quad
        let topLeft = observation.topLeft
        let topRight = observation.topRight

        // Calculate angle from the top edge
        let dx = topRight.x - topLeft.x
        let dy = topRight.y - topLeft.y
        let radians = atan2(dy, dx)
        let degrees = radians * 180 / .pi

        return degrees
    }

    /// Split string into word ranges
    private func getWordRanges(from string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        string.enumerateSubstrings(in: string.startIndex..., options: .byWords) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    /// Two-phase receipt analysis:
    /// Phase 1: Quick merchant + total extraction → Navigate immediately
    /// Phase 2: Full items + breakdown (runs in background)
    private func analyzeCapturedTwoPhase(image: UIImage) {
        isAnalyzing = true
        analyzeError = nil

        Task {
            do {
                // UPLOAD: Upload image once, get file URI for reuse
                print("[Scan] Uploading image...")
                let fileUri = try await LLMClient.shared.uploadImage(image)

                // PHASE 1: Quick merchant + total extraction
                print("[Scan] Phase 1: Extracting merchant and total...")
                let phase1 = try await LLMClient.shared.analyzeReceiptPhase1(fileUri: fileUri)
                print("[Scan] Phase 1 complete: merchant=\(phase1.merchant ?? "nil"), total=\(phase1.total_cents ?? 0)")

                let total = max(0, phase1.total_cents ?? 0)

                await MainActor.run {
                    // Update form fields with phase 1 data
                    amountString = String(format: "%.2f", Double(total) / 100.0)

                    if let merchant = phase1.merchant, !merchant.isEmpty {
                        receiptName = merchant
                    }

                    // Create partial receipt (empty items - will be populated by phase 2)
                    uiModel.currentReceipt = ReceiptDisplay(
                        id: UUID().uuidString,
                        title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                        createdAt: Date(),
                        subtotalCents: total,  // Use total as subtotal initially
                        feesCents: 0,
                        taxCents: 0,
                        tipCents: 0,
                        discountCents: 0,
                        totalCents: total,
                        items: []  // Empty - loading
                    )

                    uiModel.itemsLoadingState = .loading
                    confirmationCameFromManual = false

                    // Navigate immediately after phase 1!
                    isAnalyzing = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .confirmation
                    }
                }

                // PHASE 2: Background item extraction (reuses same file URI)
                let knownTotal = total
                uiModel.phase2Task = Task { @MainActor in
                    do {
                        print("[Scan] Phase 2: Extracting items and breakdown...")
                        let phase2 = try await LLMClient.shared.analyzeReceiptPhase2(
                            fileUri: fileUri,
                            knownTotalCents: knownTotal
                        )
                        print("[Scan] Phase 2 complete: \(phase2.items.count) items")

                        // Build full ParsedReceipt for compatibility
                        let fullParsed = ParsedReceipt(
                            merchant: phase1.merchant,
                            total_cents: knownTotal,
                            subtotal_cents: phase2.subtotal_cents,
                            tax_cents: phase2.tax_cents,
                            tip_cents: phase2.tip_cents,
                            fees_cents: phase2.fees_cents,
                            discount_cents: phase2.discount_cents,
                            items: phase2.items.map { ParsedReceipt.Item(label: $0.label, qty: $0.qty, cents: $0.cents) },
                            issues: phase2.issues
                        )
                        uiModel.parsedReceipt = fullParsed

                        // Extract breakdown
                        let breakdown = fullParsed.breakdownDefaults()
                        let subtotal = max(0, phase2.subtotal_cents ?? (knownTotal - breakdown.tax - breakdown.fees - breakdown.tip + breakdown.discount))

                        // Check if user already added a tip manually (don't overwrite it)
                        let userAddedTip = !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
                        let existingUserTip = uiModel.currentReceipt?.tipCents ?? 0

                        // Only prefill tip from scan if user hasn't added one manually
                        if !userAddedTip && existingUserTip == 0 && breakdown.tip > 0 {
                            tipAmount = String(format: "%.2f", Double(breakdown.tip) / 100.0)
                        }

                        // Preserve user's tip if they added one, otherwise use scanned tip
                        let finalTipCents: Int
                        if userAddedTip {
                            finalTipCents = amountToCents(tipAmount)
                        } else if existingUserTip > 0 {
                            finalTipCents = existingUserTip
                        } else {
                            finalTipCents = breakdown.tip
                        }

                        // Update subtotal field
                        amountString = String(format: "%.2f", Double(subtotal) / 100.0)

                        // Rebuild currentReceipt with items + breakdown, preserving user's tip
                        uiModel.currentReceipt = ReceiptDisplay(
                            id: uiModel.currentReceipt?.id ?? UUID().uuidString,
                            title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                            createdAt: Date(),
                            subtotalCents: subtotal,
                            feesCents: breakdown.fees,
                            taxCents: breakdown.tax,
                            tipCents: finalTipCents,
                            discountCents: breakdown.discount,
                            totalCents: subtotal + breakdown.tax + breakdown.fees - breakdown.discount + finalTipCents,
                            items: fullParsed.toDisplayItems()
                        )

                        uiModel.itemsLoadingState = .loaded(phase2)
                    } catch {
                        print("[Scan] Phase 2 failed: \(error)")
                        uiModel.itemsLoadingState = .failed(error)
                        // Receipt is still usable with merchant/total from phase 1
                    }
                }

            } catch {
                print("[Scan] analyzeReceipt failed: \(error)")
                await MainActor.run {
                    isAnalyzing = false
                    analyzeError = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }
    @MainActor
    private func applySplitDraftToCurrentReceipt(_ draft: SplitDraft) {
        guard let r = uiModel.currentReceipt else { return }

        let updatedItems: [ReceiptDisplay.Item] = {
            switch draft.mode {
            case .byItems:
                let activeGuests = draft.activeGuests
                func displayName(_ g: SplitGuest, at activeIndex: Int) -> String {
                    let t = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                    if g.isMe {
                        let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                        return me.isEmpty ? "Me" : me
                    }
                    return "Guest \(activeIndex + 1)"
                }

                return draft.items.map { it in
                    let responsible = it.assignedGuestIds.compactMap { gid -> ReceiptDisplay.Responsible? in
                        guard let idx = activeGuests.firstIndex(where: { $0.id == gid }) else { return nil }
                        return ReceiptDisplay.Responsible(
                            slotIndex: idx,
                            displayName: displayName(activeGuests[idx], at: idx)
                        )
                    }.sorted(by: { $0.slotIndex < $1.slotIndex })
                    return ReceiptDisplay.Item(
                        id: it.id.uuidString, // adjust if your Item.id type differs
                        label: it.label,
                        priceCents: it.priceCents,
                        responsible: responsible
                    )
                }

            case .equally, .custom:
                return r.items.map { old in
                    ReceiptDisplay.Item(id: old.id, label: old.label, priceCents: old.priceCents, responsible: [])
                }
            }
        }()

        uiModel.currentReceipt = ReceiptDisplay(
            id: r.id,
            title: r.title,
            createdAt: r.createdAt,
            subtotalCents: updatedItems.reduce(0) { $0 + $1.priceCents },
            feesCents: draft.feesCents,
            taxCents: draft.taxCents,
            tipCents: draft.tipCents,
            discountCents: draft.discountCents,
            totalCents: draft.totalCents,
            items: updatedItems
        )
    }
    // MARK: - Body

    var body: some View {
        Group {
            if myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isCheckingBackendUser {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        do {
                            if let name = try await TabService.shared.fetchUserDisplayName(
                                userId: KeychainHelper.getOrCreateUserId()
                            ) {
                                myName = name
                            }
                        } catch {
                            print("[RootContainerView] backend user check failed: \(error)")
                        }
                        isCheckingBackendUser = false
                    }
            } else if myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                IntroView(
                    onRequestExpand: onExpand,
                    onContinue: { name in
                        myName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            try? await TabService.shared.createOrUpdateUser(
                                userId: KeychainHelper.getOrCreateUserId(),
                                displayName: myName
                            )
                        }
                    }
                )
            } else {
                ZStack {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                    switch uiModel.currentScreen {

                    case .tabview:
                        LootTabView(
                            tabName: Binding(
                                get: { receiptName },
                                set: { receiptName = $0 }
                            ),
                            onUpload: {
                                startPhotoLibraryFlow()
                            },
                            onScan: {
                                startScanFlow()
                            },
                            onFill: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .fill
                                }
                            },
                            activeTab: uiModel.activeTab,
                            userTabs: uiModel.userTabs,
                            isExpanded: uiModel.isExpanded,
                            onStartTab: {
                                pendingTabName = ""
                                pendingTabColor = TabColorOptions.defaultHex
                                onExpand()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .newTab
                                }
                            },
                            onSelectTab: { tab in
                                uiModel.activeTab = tab
                                if let convKey = uiModel.conversationKey {
                                    TabService.shared.cacheTab(tab, for: convKey)
                                    Task {
                                        do {
                                            try await TabService.shared.associateConversation(
                                                tabId: tab.id ?? "",
                                                conversationKey: convKey
                                            )
                                        } catch {
                                            print("[RootContainer] associateConversation failed: \(error)")
                                        }
                                    }
                                }
                            },
                            onTabNameTapped: {
                                onExpand()
                            },
                            onClearTab: {
                                uiModel.activeTab = nil
                                if let convKey = uiModel.conversationKey {
                                    TabService.shared.cacheTab(nil, for: convKey)
                                    Task {
                                        try? await TabService.shared.removeConversationMapping(conversationKey: convKey)
                                    }
                                }
                            },
                            onInviteMembers: {
                                if let tab = uiModel.activeTab {
                                    pendingTabName = tab.name
                                    pendingTabColor = tab.colorHex ?? TabColorOptions.defaultHex
                                    pendingTabId = tab.id ?? ""
                                    tabInviteCameFromTabView = true
                                    onCollapse()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        uiModel.currentScreen = .tabInviteConfirmation
                                    }
                                }
                            },
                            onAccountTapped: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .account
                                }
                            }
                        )
                        .transition(.opacity)
                        
                    case .fill:
                        ManualInputView(
                            viewModel: uiModel,
                            receiptName: $receiptName,
                            amountString: $amountString,
                            tipAmount: $tipAmount,
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabview
                                }
                            },
                            onNext: {
                                // Create receipt before transitioning
                                uiModel.currentReceipt = makePreviewReceipt()
                                confirmationCameFromManual = true

                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .confirmation
                                }
                            },
                            onAddTip: {
                                // Go to tip view (amountString is already the subtotal)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tipview
                                }
                            },
                            onRequestExpand: onExpand,
                            onRequestCollapse: onCollapse,
                            titleNamespace: titleNamespace
                        )
                        .transition(.opacity)
                        
                    case .tipview:
                        // Pass breakdown values from scanned receipt if available
                        // This ensures tip is calculated on subtotal + tax + fees - discounts
                        TipView(
                            subtotalString: amountString,  // Pass the item subtotal
                            taxCents: uiModel.currentReceipt?.taxCents ?? 0,
                            feesCents: uiModel.currentReceipt?.feesCents ?? 0,
                            discountCents: uiModel.currentReceipt?.discountCents ?? 0,
                            existingTipCents: uiModel.currentReceipt?.tipCents ?? 0,
                            onBack: {
                                // Return to previous screen (fill for manual, confirmation for scanned)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = confirmationCameFromManual ? .fill : .confirmation
                                }
                            },
                            onNext: { tip, newTotal in
                                // Update the tip amount
                                tipAmount = tip

                                // Update the receipt with the new tip
                                if let receipt = uiModel.currentReceipt {
                                    // For scanned receipts, preserve the breakdown and update tip
                                    let tipCentsValue = amountToCents(tip)
                                    uiModel.currentReceipt = ReceiptDisplay(
                                        id: receipt.id,
                                        title: receipt.title,
                                        createdAt: receipt.createdAt,
                                        subtotalCents: receipt.subtotalCents,
                                        feesCents: receipt.feesCents,
                                        taxCents: receipt.taxCents,
                                        tipCents: tipCentsValue,
                                        discountCents: receipt.discountCents,
                                        totalCents: receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents + tipCentsValue,
                                        items: receipt.items
                                    )
                                } else {
                                    // For manual input, create a simple receipt
                                    uiModel.currentReceipt = makePreviewReceipt()
                                }

                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .confirmation
                                }
                            }
                        )
                        .transition(.opacity)
                        
                    case .confirmation:
                        ConfirmationView(
                            uiModel: uiModel,
                            receiptName: receiptName,
                            amount: totalAmount,  // Use computed total for display
                            participantCount: participantCount,
                            splitMode: splitDraft?.mode,
                            splitDraft: splitDraft,
                            tipAmount: tipAmount,
                            cameFromManual: confirmationCameFromManual,
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .fill
                                }
                            },
                            onSend: {
                                onSendBill(receiptName, totalAmount)  // Send the total amount
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        if !hasPaymentMethodsConfigured() {
                                            paymentMethodsIsPostSend = true
                                            uiModel.currentScreen = .paymentMethods
                                        } else {
                                            uiModel.currentScreen = .tabview
                                        }
                                    }
                                }
                            },
                            onPreviewReceipt: {
                                returnScreen = .confirmation
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .receipt
                                }
                            },
                            onDeleteToLanding: {
                                uiModel.resetForNewReceipt()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabview
                                }
                            },
                            onGoToSplit: {
                                showSplitViewSheet = true
                            },
                            onAddTip: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tipview
                                }
                            },
                            onTipChanged: { tip, total in
                                // Update the tip amount from inline slider
                                tipAmount = tip

                                // Update the receipt if it exists
                                if let receipt = uiModel.currentReceipt {
                                    let tipCentsValue = amountToCents(tip)
                                    uiModel.currentReceipt = ReceiptDisplay(
                                        id: receipt.id,
                                        title: receipt.title,
                                        createdAt: receipt.createdAt,
                                        subtotalCents: receipt.subtotalCents,
                                        feesCents: receipt.feesCents,
                                        taxCents: receipt.taxCents,
                                        tipCents: tipCentsValue,
                                        discountCents: receipt.discountCents,
                                        totalCents: receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents + tipCentsValue,
                                        items: receipt.items
                                    )
                                }

                                // Update split draft if it exists
                                if var draft = uiModel.currentSplitDraft {
                                    let oldTip = draft.tipCents
                                    let newTip = amountToCents(tip)
                                    draft.tipCents = newTip
                                    draft.totalCents = draft.totalCents - oldTip + newTip
                                    uiModel.currentSplitDraft = draft
                                }
                            },
                            onSelectMode: { newMode in
                                if var draft = uiModel.currentSplitDraft {
                                    draft.mode = newMode
                                    uiModel.currentSplitDraft = draft
                                    splitDraft = draft
                                } else if var draft = splitDraft {
                                    draft.mode = newMode
                                    splitDraft = draft
                                    uiModel.currentSplitDraft = draft
                                } else {
                                    // Create a minimal draft with the selected mode
                                    let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                                    var seededGuests: [SplitGuest] = [SplitGuest(name: meName, isIncluded: true, isMe: true, uid: KeychainHelper.getOrCreateUserId())]
                                    if participantCount > 1 {
                                        for _ in 1..<participantCount {
                                            seededGuests.append(SplitGuest(name: "", isIncluded: true, isMe: false))
                                        }
                                    }
                                    let newDraft = SplitDraft(
                                        guests: seededGuests,
                                        payerGuestId: seededGuests.first?.id ?? UUID(),
                                        mode: newMode,
                                        totalCents: amountToCents(totalAmount),
                                        perGuestCents: [],
                                        items: [],
                                        feesCents: uiModel.currentReceipt?.feesCents ?? 0,
                                        taxCents: uiModel.currentReceipt?.taxCents ?? 0,
                                        tipCents: uiModel.currentReceipt?.tipCents ?? amountToCents(tipAmount),
                                        discountCents: uiModel.currentReceipt?.discountCents ?? 0
                                    )
                                    splitDraft = newDraft
                                    uiModel.currentSplitDraft = newDraft
                                }
                            },
                            onGuestsChanged: { newGuests, newPayerId in
                                // Update splitDraft with new guests/payer
                                if var draft = splitDraft {
                                    draft.guests = newGuests
                                    draft.payerGuestId = newPayerId
                                    splitDraft = draft
                                    uiModel.currentSplitDraft = draft
                                } else {
                                    // Create a new draft with the guests
                                    let newDraft = SplitDraft(
                                        guests: newGuests,
                                        payerGuestId: newPayerId,
                                        mode: .equally,
                                        totalCents: amountToCents(totalAmount),
                                        perGuestCents: [],
                                        items: [],
                                        feesCents: uiModel.currentReceipt?.feesCents ?? 0,
                                        taxCents: uiModel.currentReceipt?.taxCents ?? 0,
                                        tipCents: uiModel.currentReceipt?.tipCents ?? amountToCents(tipAmount),
                                        discountCents: uiModel.currentReceipt?.discountCents ?? 0
                                    )
                                    splitDraft = newDraft
                                    uiModel.currentSplitDraft = newDraft
                                }
                            },
                            onRequestCollapse: onCollapse
                        )
                        .transition(.opacity)
                        
                    case .receipt:
                        if let receipt = uiModel.currentReceipt {
                            ReceiptView(uiModel: uiModel, receipt: receipt) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = returnScreen
                                }
                            }
                            .ignoresSafeArea(edges: .bottom)
                        } else {
                            ProgressView("Loading…")
                        }
                    case .messageViewer:
                        if let payload = uiModel.openedMessagePayload {
                            MessageReceiptViewer(
                                uiModel: uiModel,
                                payload: payload,
                                onClose: {
                                    uiModel.openedMessagePayload = nil
                                    uiModel.messageLoadingState = .idle
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        uiModel.currentScreen = .tabview
                                    }
                                }
                            )
                            .ignoresSafeArea(edges: .bottom)
                        } else if uiModel.messageLoadingState.isLoading {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Loading receipt...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = uiModel.messageLoadingState.error {
                            VStack(spacing: 16) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Couldn't load receipt")
                                    .font(.headline)
                                Text(error.localizedDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Go Back") {
                                    uiModel.messageLoadingState = .idle
                                    uiModel.openedMessagePayload = nil
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        uiModel.currentScreen = .tabview
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding()
                        } else {
                            ProgressView("Loading…")
                        }

                    case .newTab:
                        NewTabView(
                            uiModel: uiModel,
                            isExpanded: uiModel.isExpanded,
                            onRequestExpand: onExpand,
                            onBack: {
                                pendingTabId = ""
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabview
                                }
                            },
                            onNext: { name, colorHex in
                                // Reuse existing pending tab ID if user came back from invite screen,
                                // otherwise generate a new one to avoid creating duplicates.
                                let tabId = pendingTabId.isEmpty ? TabService.shared.generateTabId() : pendingTabId
                                let tab = TabService.shared.createLocalTab(name: name, colorHex: colorHex, tabId: tabId)

                                pendingTabName = tab.name
                                pendingTabColor = tab.colorHex ?? colorHex
                                pendingTabId = tabId
                                tabInviteCameFromTabView = false
                                uiModel.activeTab = tab
                                if let convKey = uiModel.conversationKey {
                                    TabService.shared.cacheTab(tab, for: convKey)
                                }
                                onCollapse()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabInviteConfirmation
                                }

                                // Upload (or overwrite) to Firestore in the background
                                Task {
                                    do {
                                        try await TabService.shared.uploadTab(tab, tabId: tabId, conversationKey: uiModel.conversationKey ?? "")
                                        print("[RootContainer] Tab uploaded: \(tabId)")
                                    } catch {
                                        print("[RootContainer] Tab upload failed: \(error)")
                                    }
                                }
                            },
                            tabName: $pendingTabName,
                            selectedColor: $pendingTabColor
                        )
                        .transition(.opacity)

                    case .tabInviteConfirmation:
                        TabInviteConfirmationView(
                            uiModel: uiModel,
                            tabName: pendingTabName,
                            tabColor: pendingTabColor,
                            tabId: pendingTabId,
                            creatorName: myName.isEmpty ? "Me" : myName,
                            onBack: {
                                if tabInviteCameFromTabView {
                                    onExpand()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        uiModel.currentScreen = .tabview
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        uiModel.currentScreen = .newTab
                                    }
                                }
                            },
                            onSend: { tabName, tabColorHex, tabId in
                                onSendTabInvite?(tabName, tabColorHex, tabId)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        uiModel.currentScreen = .tabview
                                    }
                                }
                            },
                            onRequestCollapse: onCollapse
                        )
                        .transition(.opacity)

                    case .joinTab:
                        JoinTabView(
                            uiModel: uiModel,
                            isExpanded: uiModel.isExpanded,
                            onRequestExpand: onExpand,
                            onBack: {
                                uiModel.pendingTabInviteId = nil
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabview
                                }
                            },
                            onJoined: { tab in
                                uiModel.activeTab = tab
                                uiModel.pendingTabInviteId = nil
                                // Persist the conversation→tab link so it survives re-entry
                                if let convKey = uiModel.conversationKey {
                                    TabService.shared.cacheTab(tab, for: convKey)
                                    Task {
                                        try? await TabService.shared.associateConversation(
                                            tabId: tab.id ?? "",
                                            conversationKey: convKey
                                        )
                                    }
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabview
                                }
                            },
                            onAccountTapped: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .account
                                }
                            }
                        )
                        .transition(.opacity)

                    case .account:
                        AccountView(
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .tabview
                                }
                            },
                            onRequestExpand: onExpand,
                            onPaymentMethods: {
                                paymentMethodsIsPostSend = false
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = .paymentMethods
                                }
                            }
                        )
                        .transition(.opacity)

                    case .paymentMethods:
                        PaymentMethodView(
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = paymentMethodsIsPostSend ? .tabview : .account
                                }
                            },
                            onRequestExpand: onExpand,
                            onSaved: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    uiModel.currentScreen = paymentMethodsIsPostSend ? .tabview : .account
                                }
                            },
                            isPostSendPrompt: paymentMethodsIsPostSend
                        )
                        .transition(.opacity)
                    }
                }
                .sheet(
                    isPresented: $showCamera,
                    onDismiss: {
                        guard let img = capturedImage else { return }
                        ReceiptCrop.run(img) { cropped in
                            uiModel.scanImageOriginal = img
                            uiModel.scanImageCropped = cropped
                            analyzeCaptured(image: cropped)
                        }
                    }
                ) { CameraPicker(image: $capturedImage).ignoresSafeArea() }
                .sheet(
                    isPresented: $showPhotoLibrary,
                    onDismiss: {
                        guard let img = photoLibraryImage else { return }
                        ReceiptCrop.run(img) { cropped in
                            uiModel.scanImageOriginal = img
                            uiModel.scanImageCropped = cropped
                            analyzeCaptured(image: cropped)
                        }
                    }
                ) { PhotoLibraryPicker(image: $photoLibraryImage).ignoresSafeArea() }
                // SplitView sheet removed — split panels now integrated into ConfirmationView extension
                // TODO: Wire up showSplitViewSheet to inline split editing in Phase 5
                .overlay {
                    if isAnalyzing {
                        ZStack {
                            Color.black.opacity(0.25).ignoresSafeArea()
                            ProgressView("Analyzing receipt…")
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(12)
                        }
                    }
                }
                .alert("Scan failed", isPresented: Binding(
                    get: { analyzeError != nil },
                    set: { _ in analyzeError = nil }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(analyzeError ?? "")
                }
                .onAppear {
                    if uiModel.openedMessagePayload != nil {
                        uiModel.currentScreen = .messageViewer
                    }
                }
                .onChange(of: uiModel.openedMessagePayload) { _, newValue in
                    if newValue != nil {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            uiModel.currentScreen = .messageViewer
                        }
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { debugOCRResult != nil },
                    set: { if !$0 { debugOCRResult = nil; debugOriginalImage = nil } }
                )) {
                    DebugOCRView(
                        result: debugOCRResult!,
                        originalImage: debugOriginalImage,
                        onDismiss: {
                            debugOCRResult = nil
                            debugOriginalImage = nil
                        }
                    )
                }
            }
        }
    }
}
