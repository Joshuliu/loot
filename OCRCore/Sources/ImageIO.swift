import Foundation
import CoreGraphics
import AppKit
import ImageIO

public struct ReceiptImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let size: CGSize

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
        self.size = CGSize(width: cgImage.width, height: cgImage.height)
    }

    public static func load(from url: URL) throws -> ReceiptImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "ReceiptImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open image source at \(url.path)"])
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ReceiptImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not decode image at \(url.path)"])
        }
        return ReceiptImage(cgImage: cgImage)
    }
}
