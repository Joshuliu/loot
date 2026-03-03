//
//  ReceiptCrop.swift - OPTIMIZED for speed + Gemini reliability
//  Loot
//

import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ReceiptCrop {

    struct Config {
        // OPTIMIZED: Smaller size, Gemini handles 800-1024px perfectly
        var maxLongEdge: CGFloat = 1024  // Was 1280, reduced 20%
        
        // OPTIMIZED: More aggressive compression, Gemini is resilient
        var jpegQuality: CGFloat = 0.55  // Was 0.70, ~40% smaller files
        
        // Rectangle detection tuning
        var minConfidence: VNConfidence = 0.55
        var minAspectRatio: VNAspectRatio = 0.20
        var quadTolerance: Float = 30
        
        // OPTIMIZED: Reduce enhancement (Gemini prefers original)
        var contrast: Float = 1.05       // Was 1.10, more subtle
        var sharpen: Float = 0.20        // Was 0.40, less aggressive
        
        // NEW: Adaptive quality based on image characteristics
        var useAdaptiveCompression: Bool = true
        var skipEnhancementForClearImages: Bool = true
    }

    static func run(_ input: UIImage, config: Config = .init(), done: @escaping (UIImage) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let startTime = Date()
            
            // 1) Normalize orientation first
            let img = input.up

            guard let ci = CIImage(image: img) else {
                let fallback = downscaleAndCompress(img, config: config)
                print("[Crop] ⚠️  No CIImage, fallback: \(fallback.jpegData(compressionQuality: config.jpegQuality)?.count ?? 0) bytes")
                return DispatchQueue.main.async { done(fallback) }
            }

            // 2) Detect receipt rectangle
            let rectReq = VNDetectRectanglesRequest()
            rectReq.maximumObservations = 8
            rectReq.minimumConfidence = config.minConfidence
            rectReq.minimumAspectRatio = config.minAspectRatio
            rectReq.quadratureTolerance = config.quadTolerance

            if #available(iOS 15.0, *) {
                rectReq.minimumSize = 0.25
            }

            let handler = VNImageRequestHandler(ciImage: ci, options: [:])
            try? handler.perform([rectReq])

            func score(_ o: VNRectangleObservation) -> Float {
                let bb = o.boundingBox
                let area = bb.width * bb.height
                let dx = bb.midX - 0.5
                let dy = bb.midY - 0.5
                let centerPenalty = dx*dx + dy*dy
                return Float(area) * o.confidence - Float(centerPenalty) * 0.15
            }

            let best = rectReq.results?
                .sorted { score($0) > score($1) }
                .first

            let correctedCI: CIImage
            var didCrop = false
            if let obs = best {
                let area = obs.boundingBox.width * obs.boundingBox.height
                if area >= 0.30 && obs.confidence >= config.minConfidence {
                    correctedCI = perspectiveCorrect(ciImage: ci, observation: obs)
                    didCrop = true
                } else {
                    correctedCI = ci
                }
            } else {
                correctedCI = ci
            }

            // 3) NEW: Check if image needs enhancement
            let needsEnhancement = config.skipEnhancementForClearImages
                ? imageNeedsEnhancement(correctedCI)
                : true
            
            let enhancedCI: CIImage
            if needsEnhancement {
                enhancedCI = enhance(ciImage: correctedCI, contrast: config.contrast, sharpen: config.sharpen)
            } else {
                enhancedCI = correctedCI
                print("[Crop] ✨ Skipping enhancement (image is clear)")
            }

            // 4) Render to UIImage
            let rendered = render(enhancedCI) ?? img

            // 5) NEW: Adaptive compression
            let output = downscaleAndCompress(rendered, config: config, wasCropped: didCrop)
            
            let duration = Date().timeIntervalSince(startTime)
            let sizeKB = (output.jpegData(compressionQuality: config.jpegQuality)?.count ?? 0) / 1024
            print("[Crop] ✅ Processed in \(String(format: "%.2f", duration))s → \(sizeKB)KB (cropped: \(didCrop), enhanced: \(needsEnhancement))")

            DispatchQueue.main.async { done(output) }
        }
    }
}

// MARK: - Core helpers

private func perspectiveCorrect(ciImage: CIImage, observation o: VNRectangleObservation) -> CIImage {
    let w = ciImage.extent.width
    let h = ciImage.extent.height

    func px(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * w, y: p.y * h)
    }

    let f = CIFilter.perspectiveCorrection()
    f.inputImage = ciImage
    f.topLeft = px(o.topLeft)
    f.topRight = px(o.topRight)
    f.bottomLeft = px(o.bottomLeft)
    f.bottomRight = px(o.bottomRight)

    return f.outputImage ?? ciImage
}

private func enhance(ciImage: CIImage, contrast: Float, sharpen: Float) -> CIImage {
    // OPTIMIZED: Lighter enhancement
    let color = CIFilter.colorControls()
    color.inputImage = ciImage
    color.contrast = contrast
    color.saturation = 0
    let contrasted = color.outputImage ?? ciImage

    // OPTIMIZED: Less aggressive sharpening
    let sharp = CIFilter.sharpenLuminance()
    sharp.inputImage = contrasted
    sharp.sharpness = sharpen
    return sharp.outputImage ?? contrasted
}

// NEW: Aggressive OCR-optimized enhancement for receipt parsing
private func enhanceForOCR(ciImage: CIImage) -> CIImage {
    var current = ciImage

    // 1) Convert to grayscale first
    let grayscale = CIFilter.colorControls()
    grayscale.inputImage = current
    grayscale.saturation = 0
    current = grayscale.outputImage ?? current

    // 2) Auto-adjust exposure (normalize brightness)
    let exposure = CIFilter.exposureAdjust()
    exposure.inputImage = current
    exposure.ev = 0.3  // Slight brightening helps faded receipts
    current = exposure.outputImage ?? current

    // 3) Aggressive contrast stretch
    let contrast = CIFilter.colorControls()
    contrast.inputImage = current
    contrast.contrast = 1.8  // Much stronger than default 1.05
    contrast.brightness = 0.05  // Slight brightness boost
    current = contrast.outputImage ?? current

    // 4) Unsharp mask for edge enhancement (better than simple sharpen)
    let unsharp = CIFilter.unsharpMask()
    unsharp.inputImage = current
    unsharp.radius = 2.5
    unsharp.intensity = 0.8
    current = unsharp.outputImage ?? current

    // 5) Gamma correction to push midtones toward white (makes text pop)
    let gamma = CIFilter.gammaAdjust()
    gamma.inputImage = current
    gamma.power = 0.8  // < 1 brightens midtones
    current = gamma.outputImage ?? current

    return current
}

// NEW: Detect if image needs enhancement
private func imageNeedsEnhancement(_ ci: CIImage) -> Bool {
    // Sample center region brightness
    let extent = ci.extent
    let centerRect = CGRect(
        x: extent.midX - extent.width * 0.2,
        y: extent.midY - extent.height * 0.2,
        width: extent.width * 0.4,
        height: extent.height * 0.4
    )
    
    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    guard let sample = ctx.createCGImage(ci, from: centerRect) else { return true }
    
    // Measure average brightness
    let width = sample.width
    let height = sample.height
    guard width > 0, height > 0 else { return true }
    
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var buffer = [UInt8](repeating: 0, count: width * height)
    
    guard let context = CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return true }
    
    context.draw(sample, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    let sum = buffer.reduce(0) { $0 + Int($1) }
    let avg = Double(sum) / Double(width * height)
    let brightness = avg / 255.0
    
    // If brightness is good (0.4-0.8), skip enhancement
    let needsBoost = brightness < 0.4 || brightness > 0.8
    return needsBoost
}

private func render(_ ci: CIImage) -> UIImage? {
    let ctx = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false  // NEW: Don't cache, save memory
    ])
    guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
    return UIImage(cgImage: cg, scale: 1, orientation: .up)
}

// OPTIMIZED: Adaptive compression
private func downscaleAndCompress(_ img: UIImage, config: ReceiptCrop.Config, wasCropped: Bool = false) -> UIImage {
    let size = img.size
    let longEdge = max(size.width, size.height)

    // 1) Downscale if needed
    let scaled: UIImage
    if longEdge > config.maxLongEdge, longEdge > 0 {
        let scale = config.maxLongEdge / longEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        img.draw(in: CGRect(origin: .zero, size: newSize))
        scaled = UIGraphicsGetImageFromCurrentImageContext() ?? img
        UIGraphicsEndImageContext()
    } else {
        scaled = img
    }

    // 2) NEW: Adaptive quality
    let quality: CGFloat
    if config.useAdaptiveCompression {
        // If we successfully cropped the receipt, we can compress more aggressively
        // If no crop, be more conservative (might have important context)
        quality = wasCropped ? config.jpegQuality : min(config.jpegQuality + 0.10, 0.75)
    } else {
        quality = config.jpegQuality
    }

    // 3) JPEG compress
    guard let data = scaled.jpegData(compressionQuality: quality),
          let out = UIImage(data: data) else {
        return scaled
    }
    return out
}

// MARK: - Orientation fix

private extension UIImage {
    var up: UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, true, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out ?? self
    }
}

// MARK: - Additional optimization utilities

extension ReceiptCrop {
    // NEW: Preset for maximum speed (smaller files, faster upload)
    static var fastConfig: Config {
        var config = Config()
        config.maxLongEdge = 896           // Even smaller
        config.jpegQuality = 0.50          // More aggressive
        config.contrast = 1.03             // Minimal enhancement
        config.sharpen = 0.15
        config.useAdaptiveCompression = true
        config.skipEnhancementForClearImages = true
        return config
    }
    
    // NEW: Preset for maximum quality (larger files, better accuracy)
    static var qualityConfig: Config {
        var config = Config()
        config.maxLongEdge = 1280          // Keep original
        config.jpegQuality = 0.75          // Higher quality
        config.contrast = 1.10
        config.sharpen = 0.40
        config.useAdaptiveCompression = false
        config.skipEnhancementForClearImages = false
        return config
    }
    
    // NEW: Balanced (recommended default)
    static var balancedConfig: Config {
        var config = Config()
        config.maxLongEdge = 1024
        config.jpegQuality = 0.55
        config.contrast = 1.05
        config.sharpen = 0.20
        config.useAdaptiveCompression = true
        config.skipEnhancementForClearImages = true
        return config
    }
}
