import ChalkLineEffects
import CoreGraphics
import LiveTextAppleRendering
import LiveTextEffects
import SwiftUI
import XCTest

@MainActor
final class SnapshotRenderConsistencyTests: XCTestCase {
  func testFilteredSnapshotsAreIdenticalFromTheFirstRender() throws {
    let configuration = try WritingChalkConfiguration(
      seed: 0xFADE, grainAmount: 0.74, erosionAmount: 0.22,
      grainScale: 4, edgeRoughness: 0.58, textureStyle: .referenceSampled)
    let color = try ChalkColor(red: 0.92, green: 0.18, blue: 0.08)
    for scale in [CGFloat(1), 2, 3] {
      let size = CGSize(width: 240, height: 84)
      var first: Data?
      for _ in 0..<8 {
        let content = Text("Chalk")
          .font(.system(size: 52, weight: .bold))
          .chalkEffect(configuration, color: color)
        let snapshot = try InlineApplePresentationSnapshotter.snapshot(
          content: content, size: size, scale: scale)
        XCTAssertEqual(snapshot.image.bitsPerComponent, 8)
        XCTAssertEqual(snapshot.image.bitsPerPixel, 32)
        XCTAssertEqual(snapshot.image.alphaInfo, .premultipliedLast)
        let bytes = try XCTUnwrap(snapshot.image.dataProvider?.data) as Data
        let maximumAlpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max() ?? 0
        XCTAssertGreaterThan(maximumAlpha, 128, "Snapshot must retain readable pigment")
        if let first { XCTAssertEqual(bytes, first, "scale=\(scale)") }
        else { first = bytes }
      }
    }
  }

  func testSnapshotKeepsVerticalOriginAndScaledClipping() throws {
    for (scale, height) in [(CGFloat(0.5), CGFloat(6)), (1, 5), (2, 5), (3, 5)] {
      let content = VStack(spacing: 0) {
        Color(red: 1, green: 0, blue: 0).frame(height: 2)
        Color(red: 0, green: 0, blue: 1).frame(height: 4)
      }.frame(width: 4, height: 6)
      let image = try InlineApplePresentationSnapshotter.snapshot(
        content: content, size: CGSize(width: 4, height: height), scale: scale).image
      XCTAssertEqual(image.width, Int(4 * scale))
      XCTAssertEqual(image.height, Int(height * scale))
      let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
      for y in 0..<image.height {
        let expected: [UInt8] = y < Int(2 * scale) ? [255, 0, 0, 255] : [0, 0, 255, 255]
        for x in 0..<image.width {
          let index = y * image.bytesPerRow + x * 4
          XCTAssertEqual(Array(bytes[index..<(index + 4)]), expected, "scale=\(scale), x=\(x), y=\(y)")
        }
      }
    }
  }
}
