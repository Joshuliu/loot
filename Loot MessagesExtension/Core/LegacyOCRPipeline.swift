import UIKit
@preconcurrency import Vision

/// Legacy debug OCR pipeline — only used by DEBUG_OCR_ONLY mode in RootContainerView.
/// The active production pipeline lives in TranscriptGenerator.swift + ReceiptCrop.swift.
enum LegacyOCRPipeline {

    // MARK: - Image Straightening

    static func straightenImage(_ image: UIImage) async throws -> (UIImage, Double) {
        let initialOCR = try await runVisionKitOCR(image: image)

        guard !initialOCR.blocks.isEmpty else {
            print("[Straighten] No text blocks found, returning original image")
            return (image, 0)
        }

        let croppedImage = cropToReceiptBounds(image: image, ocrResult: initialOCR)

        let angles = initialOCR.blocks.map { $0.angle }
        let averageAngle = calculateAverageAngleExcludingOutliers(angles)

        print("[Straighten] Detected \(angles.count) blocks, angles: \(angles.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        print("[Straighten] Average angle (excluding outliers): \(String(format: "%.2f", averageAngle))°")

        guard abs(averageAngle) > 0.3 else {
            print("[Straighten] Angle \(String(format: "%.2f", averageAngle))° too small, skipping rotation")
            return (croppedImage, 0)
        }

        print("[Straighten] Rotating image by \(String(format: "%.2f", averageAngle))°")
        let rotatedImage = rotateImage(croppedImage, byDegrees: averageAngle)
        print("[Straighten] Rotated image size: \(rotatedImage.size) (original: \(image.size))")
        return (rotatedImage, averageAngle)
    }

    static func cropToOCRBounds(_ image: UIImage, ocrResult: OCRResult) -> UIImage {
        guard !ocrResult.blocks.isEmpty, let cgImage = image.cgImage else { return image }

        let minX = ocrResult.blocks.map { $0.boundingBox.x }.min() ?? 0
        let maxX = ocrResult.blocks.map { $0.boundingBox.x + $0.boundingBox.width }.max() ?? 1
        let minY = ocrResult.blocks.map { $0.boundingBox.y }.min() ?? 0
        let maxY = ocrResult.blocks.map { $0.boundingBox.y + $0.boundingBox.height }.max() ?? 1

        let padX = (maxX - minX) * 0.05
        let padY = (maxY - minY) * 0.05

        let cropMinX = max(0, minX - padX)
        let cropMaxX = min(1, maxX + padX)
        let cropMinY = max(0, minY - padY)
        let cropMaxY = min(1, maxY + padY)

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let pixelX = Int(cropMinX * width)
        let pixelWidth = Int((cropMaxX - cropMinX) * width)
        let pixelY = Int((1 - cropMaxY) * height)
        let pixelHeight = Int((cropMaxY - cropMinY) * height)

        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            print("[CropOCR] Cropping failed, returning original")
            return image
        }

        print("[CropOCR] Cropped from \(Int(width))x\(Int(height)) to \(pixelWidth)x\(pixelHeight)")
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    static func cropToContentBounds(_ image: UIImage) -> UIImage {
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

        context.setFillColor(UIColor.magenta.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return image }
        let data = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, maxX = 0, minY = height, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = data[offset]; let g = data[offset + 1]; let b = data[offset + 2]; let a = data[offset + 3]
                let isTransparent = a < 10
                let isMagenta = r > 240 && g < 15 && b > 240
                let isBlack = r < 10 && g < 10 && b < 10
                if !isTransparent && !isMagenta && !isBlack {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }

        guard minX < maxX && minY < maxY else {
            print("[CropContent] No content found, returning original")
            return image
        }

        let padX = max(5, Int(Double(maxX - minX) * 0.01))
        let padY = max(5, Int(Double(maxY - minY) * 0.01))
        let cropX = max(0, minX - padX)
        let cropY = max(0, minY - padY)
        let cropWidth = min(width - cropX, (maxX - minX) + padX * 2)
        let cropHeight = min(height - cropY, (maxY - minY) + padY * 2)

        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }

        print("[CropContent] Cropped from \(width)x\(height) to \(cropWidth)x\(cropHeight)")
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Skew Detection

    static func detectSkewSlope(from ocrResult: OCRResult) -> Double? {
        guard ocrResult.blocks.count >= 4 else {
            print("[Deskew] Not enough blocks (\(ocrResult.blocks.count)) to detect skew")
            return nil
        }

        let blocks = ocrResult.blocks
        let columnTolerance = 0.08
        var columns: [[OCRBlock]] = []

        for block in blocks {
            let blockX = block.boundingBox.x
            var foundColumn = false
            for i in 0..<columns.count {
                if abs(blockX - columns[i][0].boundingBox.x) < columnTolerance {
                    columns[i].append(block)
                    foundColumn = true
                    break
                }
            }
            if !foundColumn { columns.append([block]) }
        }

        print("[Deskew] Found \(columns.count) potential columns: \(columns.map { $0.count }.sorted(by: >).prefix(5))")

        var columnSlopes: [Double] = []
        for column in columns where column.count >= 3 {
            let sorted = column.sorted { $0.boundingBox.y > $1.boundingBox.y }
            var pairSlopes: [Double] = []
            for i in 0..<sorted.count {
                for j in (i+1)..<sorted.count {
                    let dY = sorted[j].boundingBox.y - sorted[i].boundingBox.y
                    let dX = sorted[j].boundingBox.x - sorted[i].boundingBox.x
                    if abs(dY) > 0.02 {
                        let slope = dX / dY
                        if abs(slope) < 0.5 { pairSlopes.append(slope) }
                    }
                }
            }
            if pairSlopes.count >= 2 {
                let sortedPairs = pairSlopes.sorted()
                let medianSlope = sortedPairs[sortedPairs.count / 2]
                columnSlopes.append(medianSlope)
                print("[Deskew] Column with \(column.count) blocks, slope: \(String(format: "%.4f", medianSlope))")
            }
        }

        let sortedByY = blocks.sorted { $0.boundingBox.y > $1.boundingBox.y }
        var consecutiveSlopes: [Double] = []
        for i in 0..<(sortedByY.count - 1) {
            let current = sortedByY[i]; let next = sortedByY[i + 1]
            let dY = next.boundingBox.y - current.boundingBox.y
            guard abs(dY) > 0.008 else { continue }
            let dX = next.boundingBox.x - current.boundingBox.x
            let slope = dX / dY
            if abs(slope) < 0.5 && abs(dX) < 0.1 { consecutiveSlopes.append(slope) }
        }

        var allSlopes = columnSlopes
        allSlopes.append(contentsOf: consecutiveSlopes)
        guard allSlopes.count >= 2 else { print("[Deskew] Not enough slope samples"); return nil }

        let clusterTolerance = 0.06
        var bestCluster: [Double] = []
        for slope in allSlopes {
            let cluster = allSlopes.filter { abs($0 - slope) < clusterTolerance }
            if cluster.count > bestCluster.count { bestCluster = cluster }
        }
        guard bestCluster.count >= 2 else { return nil }

        let sortedCluster = bestCluster.sorted()
        let medianSlope = sortedCluster[sortedCluster.count / 2]
        let amplifiedSlope = medianSlope * 1.15
        print("[Deskew] Median slope: \(String(format: "%.4f", medianSlope)), amplified: \(String(format: "%.4f", amplifiedSlope))")
        return amplifiedSlope
    }

    static func calculateColumnSlope(_ blocks: [OCRBlock]) -> Double? {
        guard blocks.count >= 3 else { return nil }
        let sortedBlocks = blocks.sorted { $0.boundingBox.y > $1.boundingBox.y }
        var slopes: [Double] = []
        for i in 0..<(sortedBlocks.count - 1) {
            let current = sortedBlocks[i]; let next = sortedBlocks[i + 1]
            let currentX = current.boundingBox.x + current.boundingBox.width / 2
            let currentY = current.boundingBox.y + current.boundingBox.height / 2
            let nextX = next.boundingBox.x + next.boundingBox.width / 2
            let nextY = next.boundingBox.y + next.boundingBox.height / 2
            let dY = nextY - currentY
            guard abs(dY) > 0.001 else { continue }
            slopes.append((nextX - currentX) / dY)
        }
        guard slopes.count >= 2 else { return nil }
        return calculateAverageSlopeExcludingOutliers(slopes)
    }

    static func calculateAverageSlopeExcludingOutliers(_ slopes: [Double]) -> Double? {
        guard !slopes.isEmpty else { return nil }
        guard slopes.count >= 4 else { return slopes.reduce(0, +) / Double(slopes.count) }
        let sorted = slopes.sorted()
        let q1 = sorted[sorted.count / 4]; let q3 = sorted[(sorted.count * 3) / 4]
        let iqr = q3 - q1
        let filtered = slopes.filter { $0 >= q1 - 1.5 * iqr && $0 <= q3 + 1.5 * iqr }
        guard !filtered.isEmpty else { return sorted[sorted.count / 2] }
        return filtered.reduce(0, +) / Double(filtered.count)
    }

    static func applyHorizontalShear(_ image: UIImage, slope: Double) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let shearTransform = CGAffineTransform(a: 1, b: 0, c: CGFloat(slope), d: 1, tx: 0, ty: 0)
        let transformed = ciImage.transformed(by: shearTransform)
        let translated = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.origin.x, y: -transformed.extent.origin.y))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(translated, from: translated.extent) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    static func cropToReceiptBounds(image: UIImage, ocrResult: OCRResult) -> UIImage {
        guard !ocrResult.blocks.isEmpty else { return image }

        let leftEdges = ocrResult.blocks.map { $0.boundingBox.x }
        let rightEdges = ocrResult.blocks.map { $0.boundingBox.x + $0.boundingBox.width }
        let topEdges = ocrResult.blocks.map { $0.boundingBox.y + $0.boundingBox.height }
        let bottomEdges = ocrResult.blocks.map { $0.boundingBox.y }

        let typicalLeft = findTypicalMinimum(leftEdges)
        let typicalRight = findTypicalMaximum(rightEdges)
        let typicalTop = findTypicalMaximum(topEdges)
        let typicalBottom = findTypicalMinimum(bottomEdges)

        let padding = 0.02
        let cropLeft = max(0, typicalLeft - padding)
        let cropRight = min(1, typicalRight + padding)
        let cropBottom = max(0, typicalBottom - padding)
        let cropTop = min(1, typicalTop + padding)

        let cropWidth = cropRight - cropLeft
        let cropHeight = cropTop - cropBottom
        if cropWidth > 0.95 && cropHeight > 0.95 { return image }

        let pixelX = cropLeft * image.size.width
        let pixelWidth = cropWidth * image.size.width
        let pixelY = (1 - cropTop) * image.size.height
        let pixelHeight = cropHeight * image.size.height

        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)
        guard let cgImage = image.cgImage,
              let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    static func findTypicalMinimum(_ values: [Double]) -> Double {
        guard values.count >= 4 else { return values.min() ?? 0 }
        let sorted = values.sorted()
        let q1 = sorted[sorted.count / 4]; let q3 = sorted[(sorted.count * 3) / 4]
        return sorted.filter { $0 >= q1 - 1.5 * (q3 - q1) }.min() ?? sorted[0]
    }

    static func findTypicalMaximum(_ values: [Double]) -> Double {
        guard values.count >= 4 else { return values.max() ?? 1 }
        let sorted = values.sorted()
        let q1 = sorted[sorted.count / 4]; let q3 = sorted[(sorted.count * 3) / 4]
        return sorted.filter { $0 <= q3 + 1.5 * (q3 - q1) }.max() ?? sorted[sorted.count - 1]
    }

    static func calculateAverageAngleExcludingOutliers(_ angles: [Double]) -> Double {
        guard !angles.isEmpty else { return 0 }
        guard angles.count >= 4 else { return angles.reduce(0, +) / Double(angles.count) }
        let sorted = angles.sorted()
        let q1 = sorted[sorted.count / 4]; let q3 = sorted[(sorted.count * 3) / 4]
        let iqr = q3 - q1
        let filtered = angles.filter { $0 >= q1 - 1.5 * iqr && $0 <= q3 + 1.5 * iqr }
        guard !filtered.isEmpty else { return sorted[sorted.count / 2] }
        return filtered.reduce(0, +) / Double(filtered.count)
    }

    static func rotateImage(_ image: UIImage, byDegrees degrees: Double) -> UIImage {
        guard abs(degrees) > 0.01 else { return image }
        let radians = CGFloat(degrees * .pi / 180)
        let originalRect = CGRect(origin: .zero, size: image.size)
        let rotatedRect = originalRect.applying(CGAffineTransform(rotationAngle: radians))
        let newSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cg.rotate(by: radians)
            cg.translateBy(x: -image.size.width / 2, y: -image.size.height / 2)
            image.draw(at: .zero)
        }
    }

    // MARK: - Image Enhancement

    static func upscaleImage(_ image: UIImage, scale: CGFloat) -> UIImage {
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    static func enhanceImageForOCR(_ image: UIImage) -> UIImage {
        let upscaled = upscaleImage(image, scale: 2.0)
        guard let ciImage = CIImage(image: upscaled) else { return upscaled }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        var out = ciImage

        if let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(out, forKey: kCIInputImageKey); f.setValue(0.3, forKey: kCIInputEVKey)
            if let r = f.outputImage { out = r }
        }
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(1.25, forKey: kCIInputContrastKey); f.setValue(0.05, forKey: kCIInputBrightnessKey)
            if let r = f.outputImage { out = r }
        }
        if let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(out, forKey: kCIInputImageKey); f.setValue(0.8, forKey: kCIInputSharpnessKey)
            if let r = f.outputImage { out = r }
        }
        if let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(2.5, forKey: kCIInputRadiusKey); f.setValue(0.5, forKey: kCIInputIntensityKey)
            if let r = f.outputImage { out = r }
        }
        guard let cg = context.createCGImage(out, from: out.extent) else { return upscaled }
        return UIImage(cgImage: cg, scale: upscaled.scale, orientation: upscaled.imageOrientation)
    }

    static func applyAdaptiveEnhancement(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        var out = ciImage
        if let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(out, forKey: kCIInputImageKey); f.setValue(0.3, forKey: kCIInputEVKey)
            if let r = f.outputImage { out = r }
        }
        if let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(0.3, forKey: "inputHighlightAmount"); f.setValue(-0.3, forKey: "inputShadowAmount")
            if let r = f.outputImage { out = r }
        }
        guard let cg = context.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - OCR Preprocessing

    static var priceRegexPattern: String {
        #"\$?\d{1,3}(?:,\d{3})*\.?\d{0,2}\s*[A-Za-z]?"#
    }

    static func preprocessOCR(_ input: OCRResult) -> OCRResult {
        var result = input
        result = preprocessFixPriceText(result)
        result = preprocessSplitAmounts(result)
        result = preprocessCropToItemsSection(result)
        result = preprocessCleanAmounts(result)
        return result
    }

    static func preprocessCleanAmounts(_ input: OCRResult) -> OCRResult {
        let pricePattern = #"^[\$\s]*(\d{1,3}(?:,\d{3})*|\d+)[.,](\d{2})\s*[A-Za-z]?$"#
        let priceRegex = try? NSRegularExpression(pattern: pricePattern)
        let blocks = input.blocks.map { block -> OCRBlock in
            let text = block.text.trimmingCharacters(in: .whitespaces)
            if let regex = priceRegex,
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text) {
                let dollars = String(text[r1]).replacingOccurrences(of: ",", with: "")
                var newBlock = block; newBlock.text = "\(dollars).\(String(text[r2]))"; return newBlock
            }
            return block
        }
        return OCRResult(imageWidth: input.imageWidth, imageHeight: input.imageHeight, blocks: blocks)
    }

    static func preprocessFixPriceText(_ input: OCRResult) -> OCRResult {
        var blocks = input.blocks.map { block -> OCRBlock in
            var fixedText = block.text

            let dollarFixPattern = #"^S(\d{1,3}[.,\s]?\d{0,2})$"#
            if let regex = try? NSRegularExpression(pattern: dollarFixPattern),
               regex.firstMatch(in: fixedText, range: NSRange(fixedText.startIndex..., in: fixedText)) != nil {
                fixedText = "$" + String(fixedText.dropFirst())
            }

            let spacedDecimalPattern = #"(\d+)\s*\.\s*(\d{2})$"#
            if let regex = try? NSRegularExpression(pattern: spacedDecimalPattern),
               let match = regex.firstMatch(in: fixedText, range: NSRange(fixedText.startIndex..., in: fixedText)),
               let r1 = Range(match.range(at: 1), in: fixedText),
               let r2 = Range(match.range(at: 2), in: fixedText) {
                let prefix = String(fixedText[..<r1.lowerBound])
                let newText = prefix + String(fixedText[r1]) + "." + String(fixedText[r2])
                if newText != fixedText { fixedText = newText }
            }

            let decimalFixPattern = #"(\d+)[,\s](\d{2})$"#
            if let regex = try? NSRegularExpression(pattern: decimalFixPattern),
               let match = regex.firstMatch(in: fixedText, range: NSRange(fixedText.startIndex..., in: fixedText)),
               let r1 = Range(match.range(at: 1), in: fixedText),
               let r2 = Range(match.range(at: 2), in: fixedText) {
                let prefix = String(fixedText[..<r1.lowerBound])
                let prefixIsNumberSequence = prefix.allSatisfy { $0.isNumber || $0.isWhitespace }
                let prefixHasDigits = prefix.contains(where: { $0.isNumber })
                if !(prefixIsNumberSequence && prefixHasDigits) {
                    let newText = prefix + String(fixedText[r1]) + "." + String(fixedText[r2])
                    if newText != fixedText { fixedText = newText }
                }
            }

            if fixedText != block.text {
                return OCRBlock(text: fixedText, confidence: block.confidence, boundingBox: block.boundingBox, angle: block.angle, words: block.words)
            }
            return block
        }

        var mergedBlocks: [OCRBlock] = []
        var skipNext = false
        let sortedBlocks = blocks.sorted { a, b in
            if abs(a.boundingBox.y - b.boundingBox.y) > 0.015 { return a.boundingBox.y > b.boundingBox.y }
            return a.boundingBox.x < b.boundingBox.x
        }
        for i in 0..<sortedBlocks.count {
            if skipNext { skipNext = false; continue }
            let current = sortedBlocks[i]
            if i + 1 < sortedBlocks.count {
                let next = sortedBlocks[i + 1]
                let sameLine = abs(current.boundingBox.y - next.boundingBox.y) < 0.015
                let gap = next.boundingBox.x - (current.boundingBox.x + current.boundingBox.width)
                let adjacent = gap < 0.03 && gap > -0.01
                if sameLine && adjacent,
                   current.text.range(of: #"[\$\d]$"#, options: .regularExpression) != nil,
                   next.text.range(of: #"^\d{2}$"#, options: .regularExpression) != nil {
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
                    mergedBlocks.append(OCRBlock(text: current.text + "." + next.text, confidence: min(current.confidence, next.confidence), boundingBox: mergedBbox, angle: current.angle, words: []))
                    skipNext = true
                    continue
                }
            }
            mergedBlocks.append(current)
        }
        blocks = mergedBlocks
        return OCRResult(imageWidth: input.imageWidth, imageHeight: input.imageHeight, blocks: blocks)
    }

    static func preprocessDeskewCoordinates(_ input: OCRResult) -> OCRResult {
        var result = input
        if let slope1 = detectSkewSlope(from: result), abs(slope1) > 0.02 {
            result = applyCoordinateDeskew(result, slope: slope1)
            if let slope2 = detectSkewSlope(from: result), abs(slope2) > 0.01 {
                result = applyCoordinateDeskew(result, slope: slope2)
            }
        }
        return result
    }

    static func applyCoordinateDeskew(_ input: OCRResult, slope: Double) -> OCRResult {
        let centerY = 0.5
        let adjustedBlocks = input.blocks.map { block -> OCRBlock in
            let blockCenterY = block.boundingBox.y + block.boundingBox.height / 2
            let newX = block.boundingBox.x - slope * (blockCenterY - centerY)
            let newBbox = OCRBoundingBox(
                x: newX, y: block.boundingBox.y,
                width: block.boundingBox.width, height: block.boundingBox.height,
                pixelX: Int(newX * Double(input.imageWidth)), pixelY: block.boundingBox.pixelY,
                pixelWidth: block.boundingBox.pixelWidth, pixelHeight: block.boundingBox.pixelHeight
            )
            return OCRBlock(text: block.text, confidence: block.confidence, boundingBox: newBbox, angle: block.angle, words: block.words)
        }
        return OCRResult(imageWidth: input.imageWidth, imageHeight: input.imageHeight, blocks: adjustedBlocks)
    }

    static func isNonZeroPrice(_ text: String) -> Bool {
        let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        return (Double(cleaned) ?? 0) > 0.001
    }

    static func preprocessCropToItemsSection(_ input: OCRResult) -> OCRResult {
        let standalonePricePattern = #"^\s*(\$\d{1,3}(?:,\d{3})*\.?\d{0,2}|\d{1,3}(?:,\d{3})*\.\d{2})\s*[A-Za-z]?\s*$"#
        let priceRegex = try? NSRegularExpression(pattern: standalonePricePattern)

        var blocksWithPrices: [(block: OCRBlock, index: Int)] = []
        for (index, block) in input.blocks.enumerated() {
            let text = block.text
            if let regex = priceRegex,
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
               isNonZeroPrice(text) {
                blocksWithPrices.append((block, index))
            }
        }
        guard !blocksWithPrices.isEmpty else { return input }

        let firstPriceBlock = blocksWithPrices.max(by: { $0.block.boundingBox.y < $1.block.boundingBox.y })!
        let firstPriceCenterY = firstPriceBlock.block.boundingBox.y + firstPriceBlock.block.boundingBox.height / 2
        let minY = blocksWithPrices.map { $0.block.boundingBox.y }.min()!
        let bottomBlocks = blocksWithPrices.filter { abs($0.block.boundingBox.y - minY) < 0.02 }
        let lastPriceBlock = bottomBlocks.max(by: { $0.block.boundingBox.x < $1.block.boundingBox.x })!
        let lastPriceCenterY = lastPriceBlock.block.boundingBox.y + lastPriceBlock.block.boundingBox.height / 2

        let filteredBlocks = input.blocks.filter { block in
            let centerY = block.boundingBox.y + block.boundingBox.height / 2
            return centerY <= firstPriceCenterY + 0.02 && centerY >= lastPriceCenterY - 0.02
        }
        return OCRResult(imageWidth: input.imageWidth, imageHeight: input.imageHeight, blocks: filteredBlocks)
    }

    static func preprocessSplitAmounts(_ input: OCRResult) -> OCRResult {
        var newBlocks: [OCRBlock] = []
        let pricePattern = #"^(.+?)\s+(\$?\d{1,3}(?:,\d{3})*\.\d{2}\s*[A-Za-z]?)\s*$"#
        let priceRegex = try? NSRegularExpression(pattern: pricePattern)

        for block in input.blocks {
            let text = block.text.trimmingCharacters(in: .whitespaces)
            if let regex = priceRegex,
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges == 3,
               let itemRange = Range(match.range(at: 1), in: text),
               let priceRange = Range(match.range(at: 2), in: text) {
                let itemText = String(text[itemRange]).trimmingCharacters(in: .whitespaces)
                let priceText = String(text[priceRange]).trimmingCharacters(in: .whitespaces)
                guard !itemText.isEmpty && !priceText.isEmpty else { newBlocks.append(block); continue }

                let totalLen = Double(text.count)
                let itemWidthRatio = (Double(itemText.count) / totalLen) * 0.9
                let priceWidthRatio = (Double(priceText.count) / totalLen) * 1.1
                let originalBox = block.boundingBox

                let itemBox = OCRBoundingBox.make(x: originalBox.x, y: originalBox.y, width: originalBox.width * itemWidthRatio, height: originalBox.height, imageWidth: input.imageWidth, imageHeight: input.imageHeight)
                let priceBox = OCRBoundingBox.make(x: originalBox.x + originalBox.width * (1 - priceWidthRatio), y: originalBox.y, width: originalBox.width * priceWidthRatio, height: originalBox.height, imageWidth: input.imageWidth, imageHeight: input.imageHeight)

                newBlocks.append(OCRBlock(text: itemText, confidence: block.confidence, boundingBox: itemBox, angle: block.angle, words: []))
                newBlocks.append(OCRBlock(text: priceText, confidence: block.confidence, boundingBox: priceBox, angle: block.angle, words: []))
            } else {
                newBlocks.append(block)
            }
        }
        return OCRResult(imageWidth: input.imageWidth, imageHeight: input.imageHeight, blocks: newBlocks)
    }

    // MARK: - VisionKit OCR

    static func runVisionKitOCR(image: UIImage) async throws -> OCRResult {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get CGImage"])
        }
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(imageWidth: imageWidth, imageHeight: imageHeight, blocks: []))
                    return
                }

                var blocks: [OCRBlock] = []
                for obs in observations {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let bbox = obs.boundingBox
                    let angle = estimateTextAngle(observation: obs)
                    var words: [OCRWord] = []
                    for range in getWordRanges(from: top.string) {
                        if let wordBox = try? top.boundingBox(for: range) {
                            let wb = wordBox.boundingBox
                            words.append(OCRWord(text: String(top.string[range]), confidence: top.confidence, boundingBox: OCRBoundingBox(x: wb.origin.x, y: wb.origin.y, width: wb.width, height: wb.height, pixelX: Int(wb.origin.x * Double(imageWidth)), pixelY: Int(wb.origin.y * Double(imageHeight)), pixelWidth: Int(wb.width * Double(imageWidth)), pixelHeight: Int(wb.height * Double(imageHeight)))))
                        }
                    }
                    blocks.append(OCRBlock(text: top.string, confidence: top.confidence, boundingBox: OCRBoundingBox(x: bbox.origin.x, y: bbox.origin.y, width: bbox.width, height: bbox.height, pixelX: Int(bbox.origin.x * Double(imageWidth)), pixelY: Int(bbox.origin.y * Double(imageHeight)), pixelWidth: Int(bbox.width * Double(imageWidth)), pixelHeight: Int(bbox.height * Double(imageHeight))), angle: angle, words: words))
                }
                blocks.sort { a, b in
                    abs(a.boundingBox.y - b.boundingBox.y) > 0.01 ? a.boundingBox.y > b.boundingBox.y : a.boundingBox.x < b.boundingBox.x
                }
                continuation.resume(returning: OCRResult(imageWidth: imageWidth, imageHeight: imageHeight, blocks: blocks))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.0
            request.revision = VNRecognizeTextRequestRevision3
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) } catch { continuation.resume(throwing: error) }
        }
    }

    static func estimateTextAngle(observation: VNRecognizedTextObservation) -> Double {
        let dx = observation.topRight.x - observation.topLeft.x
        let dy = observation.topRight.y - observation.topLeft.y
        return atan2(dy, dx) * 180 / .pi
    }

    static func getWordRanges(from string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        string.enumerateSubstrings(in: string.startIndex..., options: .byWords) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}
