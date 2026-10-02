import CoreGraphics
@testable import Swiitch

/// Synthetic immutable pixels; never captures the desktop or creates AppKit objects.
func thumbnailFixture(size: CGSize) -> CapturedThumbnail {
    let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return CapturedThumbnail(bitmap: context.makeImage()!)
}
