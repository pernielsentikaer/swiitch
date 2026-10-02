import AppKit

/// Only immutable pixels cross capture/cache actor boundaries. AppKit's mutable image
/// wrapper is created lazily and reused exclusively on the main actor, including on
/// older SDKs where NSImage explicitly does not conform to Sendable.
final class CapturedThumbnail: Sendable {
    let bitmap: CGImage
    let size: CGSize
    let byteCost: Int
    @MainActor private var presentationImage: NSImage?

    init(bitmap: CGImage) {
        self.bitmap = bitmap
        size = CGSize(width: bitmap.width, height: bitmap.height)
        byteCost = bitmap.bytesPerRow * bitmap.height
    }

    @MainActor var image: NSImage {
        if let presentationImage { return presentationImage }
        // Keep the actual bitmap rather than creating a display-scaled backing image.
        let image = NSImage(size: size)
        image.addRepresentation(NSBitmapImageRep(cgImage: bitmap))
        presentationImage = image
        return image
    }
}
