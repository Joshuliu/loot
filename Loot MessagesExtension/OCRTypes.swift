//
//  OCRTypes.swift
//  Loot
//
//  Created by Joshua Liu on 1/30/26.
//

import Foundation

/// VisionKit OCR result structures
struct OCRResult: Codable {
    var imageWidth: Int
    var imageHeight: Int
    var blocks: [OCRBlock]
}

struct OCRBlock: Codable {
    var text: String
    var confidence: Float
    var boundingBox: OCRBoundingBox  // Normalized 0-1 coordinates
    var angle: Double  // Rotation angle in degrees
    var words: [OCRWord]
}

struct OCRWord: Codable {
    var text: String
    var confidence: Float
    var boundingBox: OCRBoundingBox
}

struct OCRBoundingBox: Codable {
    var x: Double       // Left edge (0-1)
    var y: Double       // Bottom edge (0-1, VisionKit uses bottom-left origin)
    var width: Double   // Width (0-1)
    var height: Double  // Height (0-1)
    // Convenience: pixel coordinates
    var pixelX: Int
    var pixelY: Int
    var pixelWidth: Int
    var pixelHeight: Int

    /// Create a bounding box with normalized coordinates, auto-computing pixel values
    static func make(x: Double, y: Double, width: Double, height: Double, imageWidth: Int, imageHeight: Int) -> OCRBoundingBox {
        OCRBoundingBox(
            x: x, y: y, width: width, height: height,
            pixelX: Int(x * Double(imageWidth)),
            pixelY: Int(y * Double(imageHeight)),
            pixelWidth: Int(width * Double(imageWidth)),
            pixelHeight: Int(height * Double(imageHeight))
        )
    }
}
