import XCTest
import CoreGraphics
@testable import RemoteDroidCore

final class GeometryTests: XCTestCase {
    func testPortraitLetterboxCentersHorizontally() {
        let rect = DisplayGeometry.aspectFitRect(
            videoSize: CGSize(width: 1080, height: 1920),
            in: CGRect(x: 0, y: 0, width: 800, height: 800)
        )
        XCTAssertEqual(rect.height, 800, accuracy: 0.05)
        XCTAssertEqual(rect.width, 450, accuracy: 0.05)
        XCTAssertEqual(rect.minX, 175, accuracy: 0.05)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.05)
    }

    func testLandscapeLetterboxCentersVertically() {
        let rect = DisplayGeometry.aspectFitRect(
            videoSize: CGSize(width: 2400, height: 1080),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertEqual(rect.width, 800, accuracy: 0.05)
        XCTAssertEqual(rect.height, 360, accuracy: 0.05)
        XCTAssertEqual(rect.minY, 120, accuracy: 0.05)
    }

    func testCenterMapsToCenterAndYFlips() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let center = try XCTUnwrap(DisplayGeometry.devicePoint(
            for: CGPoint(x: 200, y: 400),
            videoSize: CGSize(width: 1080, height: 1920),
            in: bounds
        ))
        XCTAssertEqual(center.x, 540)
        XCTAssertEqual(center.y, 960)

        // AppKit top-left is y=800, which becomes Android's first rows.
        let rect = DisplayGeometry.aspectFitRect(
            videoSize: CGSize(width: 1080, height: 1920),
            in: bounds
        )
        let top = try XCTUnwrap(DisplayGeometry.devicePoint(
            for: CGPoint(x: rect.midX, y: rect.maxY - 0.5),
            videoSize: CGSize(width: 1080, height: 1920),
            in: bounds
        ))
        XCTAssertLessThan(top.y, 5)
    }

    func testLetterboxTapIsIgnored() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
        let point = CGPoint(x: 50, y: 400)
        XCTAssertNil(DisplayGeometry.devicePoint(
            for: point,
            videoSize: CGSize(width: 1080, height: 1920),
            in: bounds
        ))
    }

    func testClampsToVideoBounds() throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
        let rect = DisplayGeometry.aspectFitRect(
            videoSize: CGSize(width: 1080, height: 1920),
            in: bounds
        )
        let bottomRight = try XCTUnwrap(DisplayGeometry.devicePoint(
            for: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5),
            videoSize: CGSize(width: 1080, height: 1920),
            in: bounds
        ))
        XCTAssertEqual(bottomRight.x, 1078)
        XCTAssertEqual(bottomRight.y, 1918)
    }
}
