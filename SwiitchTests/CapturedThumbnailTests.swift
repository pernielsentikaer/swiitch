import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class CapturedThumbnailTests: XCTestCase {
    func testWorkerSnapshotReusesTheSameMainActorImageAcrossCacheAndProgress() async throws {
        let snapshot = await Task.detached {
            thumbnailFixture(size: CGSize(width: 120, height: 80))
        }.value
        let cache = WindowThumbnails(captureProvider: { ids, deliver in
            for id in ids { await deliver(id, snapshot) }
        })
        var delivered: [NSImage] = []
        let first = await cache.images(for: [1]) { _, image in delivered.append(image) }
        let second = await cache.images(for: [1], maximumAge: .infinity) { _, image in delivered.append(image) }
        let image = try XCTUnwrap(first[1]?.image)
        XCTAssertTrue(image === second[1]?.image)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertTrue(delivered.allSatisfy { $0 === image })
        XCTAssertEqual(image.representations.first?.pixelsWide, 120)
        XCTAssertEqual(image.representations.first?.pixelsHigh, 80)
        let stats = await cache.statistics
        XCTAssertEqual(stats.cacheMisses, 1)
        XCTAssertEqual(stats.cacheHits, 1)
    }

    func testByteCostIncludesBitmapRowPadding() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 7, height: 3, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try XCTUnwrap(context.makeImage())
        let snapshot = CapturedThumbnail(bitmap: bitmap)
        XCTAssertEqual(snapshot.size, CGSize(width: 7, height: 3))
        XCTAssertEqual(snapshot.byteCost, 64 * 3)
    }
}
