import CoreGraphics
import Foundation

/// A 256-bit average hash of an image (spec 9): the image shrunk to 16x16 grey, one bit per pixel brighter than the mean.
public struct ImageHash: Equatable, Hashable, Sendable {
    public static let side = 16
    public static let bitCount = side * side

    /// Four 64-bit words, bit `i` of the hash in word `i / 64`.
    public let words: [UInt64]

    public init(words: [UInt64]) {
        self.words = Array((words + [UInt64](repeating: 0, count: 4)).prefix(4))
    }

    /// The hash of `image`, or nil when it can't be drawn.
    public static func average16(_ image: CGImage) -> ImageHash? {
        var pixels = [UInt8](repeating: 0, count: bitCount)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let total = pixels.reduce(0) { (sum: Int, pixel: UInt8) in sum + Int(pixel) }
        let mean = Double(total) / Double(bitCount)
        var words = [UInt64](repeating: 0, count: 4)
        for (index, pixel) in pixels.enumerated() where Double(pixel) > mean {
            words[index / 64] |= UInt64(1) << UInt64(index % 64)
        }
        return ImageHash(words: words)
    }

    /// The share of bits that differ, from 0 (same) to 1 (every bit).
    public static func difference(_ a: ImageHash, _ b: ImageHash) -> Double {
        let changed = zip(a.words, b.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        return Double(changed) / Double(bitCount)
    }
}
