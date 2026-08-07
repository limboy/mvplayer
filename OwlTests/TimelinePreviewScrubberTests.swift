import AppKit
import XCTest
@testable import Owl

final class TimelinePreviewScrubberTests: XCTestCase {
    func testAspectRatioComesFromThePixelDimensions() throws {
        let image = try makeImage(width: 1_920, height: 1_080)

        let ratio = try XCTUnwrap(TimelinePreviewScrubber.aspectRatio(of: image))

        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.001)
    }

    func testPortraitFramesReportATallRatio() throws {
        let image = try makeImage(width: 480, height: 854)

        let ratio = try XCTUnwrap(TimelinePreviewScrubber.aspectRatio(of: image))

        XCTAssertEqual(ratio, 480.0 / 854.0, accuracy: 0.001)
        XCTAssertLessThan(ratio, 1)
    }

    func testExtremeRatiosAreClamped() throws {
        let wide = try makeImage(width: 4_000, height: 100)
        let tall = try makeImage(width: 100, height: 4_000)

        XCTAssertEqual(try XCTUnwrap(TimelinePreviewScrubber.aspectRatio(of: wide)), 5)
        XCTAssertEqual(try XCTUnwrap(TimelinePreviewScrubber.aspectRatio(of: tall)), 0.2)
    }

    func testAnEmptyImageHasNoRatio() {
        XCTAssertNil(TimelinePreviewScrubber.aspectRatio(of: NSImage(size: .zero)))
    }

    private func makeImage(width: Int, height: Int) throws -> NSImage {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        // A size that disagrees with the pixel grid, the way a frame carrying
        // its own DPI would arrive.
        let image = NSImage(size: CGSize(width: 10, height: 10))
        image.addRepresentation(rep)
        return image
    }
}
