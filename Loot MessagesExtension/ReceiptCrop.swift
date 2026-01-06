//
//  ReceiptCrop.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//

import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ReceiptCrop {

    struct Config {
        /// Max long-edge in pixels after processing (speed win).
        var maxLongEdge: CGFloat = 1280

        /// JPEG quality used to force recompression (network win).
        var jpegQuality: CGFloat = 0.70

        /// Rectangle detection tuning.
        var minConfidence: VNConfidence = 0.55
        var minAspectRatio: VNAspectRatio = 0.20
        var quadTolerance: Float = 30

        /// Image enhancement (mild, so we don’t destroy text).
        var contrast: Float = 1.10
        var sharpen: Float = 0.40
    }

    static func run(_ input: UIImage, config: Config = .init(), done: @escaping (UIImage) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) Normalize orientation first (Vision + CI behave better).
            let img = input.up

            // If we can’t make CIImage, still return a compressed+downsized version.
            guard let ci = CIImage(image: img) else {
                let fallback = downscaleAndCompress(img, maxLongEdge: config.maxLongEdge, jpegQuality: config.jpegQuality)
                return DispatchQueue.main.async { done(fallback) }
            }

            // 2) Try to detect the receipt rectangle.
            let rectReq = VNDetectRectanglesRequest()
            rectReq.maximumObservations = 8
            rectReq.minimumConfidence = config.minConfidence
            rectReq.minimumAspectRatio = config.minAspectRatio
            rectReq.quadratureTolerance = config.quadTolerance

            if #available(iOS 15.0, *) {
                rectReq.minimumSize = 0.25   // ignore small “random” rectangles
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
            if let obs = best {
                let area = obs.boundingBox.width * obs.boundingBox.height
                // Only crop if it's plausibly the receipt; otherwise skip cropping.
                if area >= 0.30 && obs.confidence >= config.minConfidence {
                    correctedCI = perspectiveCorrect(ciImage: ci, observation: obs)
                } else {
                    correctedCI = ci
                }
            } else {
                correctedCI = ci
            }

            // 3) Mild enhancement to help faint receipts.
            let enhancedCI = enhance(ciImage: correctedCI, contrast: config.contrast, sharpen: config.sharpen)

            // 4) Render to UIImage (up orientation).
            let rendered = render(enhancedCI) ?? img

            // 5) Downscale + JPEG recompress.
            let output = downscaleAndCompress(rendered, maxLongEdge: config.maxLongEdge, jpegQuality: config.jpegQuality)

            DispatchQueue.main.async { done(output) }
        }
    }
}

// MARK: - Core helpers

private func perspectiveCorrect(ciImage: CIImage, observation o: VNRectangleObservation) -> CIImage {
    let w = ciImage.extent.width
    let h = ciImage.extent.height

    func px(_ p: CGPoint) -> CGPoint {
        // VNRectangleObservation points are normalized to the image.
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
    // Contrast
    let color = CIFilter.colorControls()
    color.inputImage = ciImage
    color.contrast = contrast
    color.saturation = 0 // receipts are usually better as grayscale-ish
    let contrasted = color.outputImage ?? ciImage

    // Sharpen (mild)
    let sharp = CIFilter.sharpenLuminance()
    sharp.inputImage = contrasted
    sharp.sharpness = sharpen
    return sharp.outputImage ?? contrasted
}

private func render(_ ci: CIImage) -> UIImage? {
    let ctx = CIContext(options: [
        .useSoftwareRenderer: false
    ])
    guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
    return UIImage(cgImage: cg, scale: 1, orientation: .up)
}

private func downscaleAndCompress(_ img: UIImage, maxLongEdge: CGFloat, jpegQuality: CGFloat) -> UIImage {
    let size = img.size
    let longEdge = max(size.width, size.height)

    let scaled: UIImage
    if longEdge > maxLongEdge, longEdge > 0 {
        let scale = maxLongEdge / longEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        img.draw(in: CGRect(origin: .zero, size: newSize))
        scaled = UIGraphicsGetImageFromCurrentImageContext() ?? img
        UIGraphicsEndImageContext()
    } else {
        scaled = img
    }

    // Force JPEG recompression to drop file size.
    guard let data = scaled.jpegData(compressionQuality: jpegQuality),
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
