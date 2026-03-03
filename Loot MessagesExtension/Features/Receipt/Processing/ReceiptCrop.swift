//
//  ReceiptCrop.swift - OPTIMIZED for speed + Gemini reliability
//  Loot
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ReceiptCrop {

struct Config {
        var maxLongEdge: CGFloat = 2048
        var jpegQuality: CGFloat = 0.55
        var contrast: Float = 1.05
        var sharpen: Float = 0.20
        var skipEnhancementForClearImages: Bool = true
    }

    static func run(_ input: UIImage, config: Config = .init(), done: @escaping (UIImage) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let startTime = Date()

            // 1) Normalize orientation first
            let img = input.up

            guard let ci = CIImage(image: img) else {
                let fallback = downscaleAndCompress(img, config: config)
                print("[Crop] ⚠️  No CIImage, fallback")
                return DispatchQueue.main.async { done(fallback) }
            }

            // 2) Check if image needs enhancement
            let needsEnhancement = config.skipEnhancementForClearImages
                ? imageNeedsEnhancement(ci)
                : true

            let enhancedCI: CIImage
            if needsEnhancement {
                enhancedCI = enhance(ciImage: ci, contrast: config.contrast, sharpen: config.sharpen)
            } else {
                enhancedCI = ci
                print("[Crop] ✨ Skipping enhancement (image is clear)")
            }

            // 3) Render to UIImage
            let rendered = render(enhancedCI) ?? img

            // 4) Downscale if needed
            let output = downscaleAndCompress(rendered, config: config)

            let duration = Date().timeIntervalSince(startTime)
            print("[Crop] ✅ Processed in \(String(format: "%.2f", duration))s (enhanced: \(needsEnhancement))")

            DispatchQueue.main.async { done(output) }
        }
    }
}

// MARK: - Core helpers

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

// Downscale only — no JPEG compression since image stays in memory for OCR
private func downscaleAndCompress(_ img: UIImage, config: ReceiptCrop.Config, wasCropped: Bool = false) -> UIImage {
    let size = img.size
    let longEdge = max(size.width, size.height)

    guard longEdge > config.maxLongEdge, longEdge > 0 else { return img }

    let scale = config.maxLongEdge / longEdge
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)

    UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
    img.draw(in: CGRect(origin: .zero, size: newSize))
    let scaled = UIGraphicsGetImageFromCurrentImageContext() ?? img
    UIGraphicsEndImageContext()
    return scaled
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

