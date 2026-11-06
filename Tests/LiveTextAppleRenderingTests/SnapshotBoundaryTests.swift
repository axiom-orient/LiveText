import CoreGraphics
import LiveTextAppleRendering
import SwiftUI
import XCTest

@MainActor
final class SnapshotBoundaryTests: XCTestCase {
  func testFixedSizeContentCannotOverrideRequestedRasterBudget() throws {
    let limits = try InlineAppleRasterSnapshotLimits(maximumDimension: 16, maximumPixels: 64)
    let snapshot = try InlineApplePresentationSnapshotter.snapshot(
      content: Color.red.frame(width: 40, height: 30),
      size: CGSize(width: 8, height: 6), limits: limits)
    XCTAssertEqual(snapshot.image.width, 8)
    XCTAssertEqual(snapshot.image.height, 6)
    XCTAssertLessThanOrEqual(snapshot.image.width * snapshot.image.height, limits.maximumPixels)
  }

  func testFractionalOutputUsesAdmittedPixelDimensions() throws {
    let snapshot = try InlineApplePresentationSnapshotter.snapshot(
      content: Color.red.frame(width: 40, height: 30),
      size: CGSize(width: 7.25, height: 5.5), scale: 2)
    XCTAssertEqual(snapshot.image.width, 15)
    XCTAssertEqual(snapshot.image.height, 11)
  }

  func testClippingPreservesTopLeadingOrigin() throws {
    let content = HStack(spacing: 0) {
      Color(red: 1, green: 0, blue: 0).frame(width: 8)
      Color(red: 0, green: 0, blue: 1).frame(width: 32)
    }.frame(width: 40, height: 30)
    let snapshot = try InlineApplePresentationSnapshotter.snapshot(
      content: content, size: CGSize(width: 8, height: 6))
    var rgba = [UInt8](repeating: 0, count: 8 * 6 * 4)
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(
        data: bytes.baseAddress, width: 8, height: 6, bitsPerComponent: 8,
        bytesPerRow: 8 * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(snapshot.image, in: CGRect(x: 0, y: 0, width: 8, height: 6))
    }
    for pixel in stride(from: 0, to: rgba.count, by: 4) {
      XCTAssertGreaterThan(rgba[pixel], 200)
      XCTAssertEqual(rgba[pixel + 2], 0)
      XCTAssertEqual(rgba[pixel + 3], 255)
    }
  }
}
