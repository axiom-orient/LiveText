import CoreGraphics
import LiveTextEffects
import SwiftUI
import XCTest
@testable import LiveTextChalkRendering

/// These tests render the actual bundled masks through SwiftUI. They are not
/// a replacement for human assessment of chalk realism on an Apple display.
final class ChalkContactRasterTests: XCTestCase {
  private static let width = 256
  private static let height = 128

  private func plan(texture: WritingChalkTextureStyle = .fineGrain) throws -> ChalkPreparedContactPlan {
    try ChalkPreparedContactPlan.prepare(strokes: [
      ChalkRenderStrokeGeometry(id: "raster-line", points: [
        ChalkRenderStrokePoint(x: 20, y: 64, width: 8),
        ChalkRenderStrokePoint(x: 220, y: 64, width: 8),
      ])
    ], material: .liveText(WritingChalkConfiguration(textureStyle: texture)))
  }

  @MainActor
  private func pixels(
    _ plan: ChalkPreparedContactPlan,
    visibility: ChalkContactVisibility = .full,
    color: Color = .white
  ) throws -> [UInt8] {
    let canvas = Canvas { context, _ in
      ChalkContactRenderer.paint(
        plan: plan, visibility: [visibility], color: color,
        documentOriginAtContextZero: .zero,
        clipBounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), in: &context)
    }.frame(width: CGFloat(Self.width), height: CGFloat(Self.height))
    let renderer = ImageRenderer(content: canvas)
    renderer.scale = 1
    let rendered = renderer.cgImage
    let image = try XCTUnwrap(rendered, "The real SwiftUI renderer must produce a bitmap")
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
    try bytes.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(CGContext(
        data: storage.baseAddress, width: Self.width, height: Self.height,
        bitsPerComponent: 8, bytesPerRow: Self.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
    }
    return bytes
  }

  @MainActor
  func testRealRasterIsNonemptyAndDeterministic() async throws {
    let prepared = try plan()
    let first = try pixels(prepared)
    XCTAssertEqual(first, try pixels(prepared))
    XCTAssertTrue(stride(from: 3, to: first.count, by: 4).contains { first[$0] > 0 })
  }

  @MainActor
  func testWriteStartAndEraseEndAreCompletelyTransparent() async throws {
    let prepared = try plan()
    for visibility in [ChalkContactVisibility.prefix(0), .suffix(1)] {
      let result = try pixels(prepared, visibility: visibility)
      XCTAssertTrue(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 0 })
    }
  }

  @MainActor
  func testEachPublicSubstrateChangesActualPixels() async throws {
    let fine = try pixels(plan(texture: .fineGrain))
    let photographic = try pixels(plan(texture: .photographic))
    let sampled = try pixels(plan(texture: .referenceSampled))
    XCTAssertNotEqual(fine, photographic)
    XCTAssertNotEqual(fine, sampled)
    XCTAssertNotEqual(photographic, sampled)
  }

  @MainActor
  func testDepositedGrainDoesNotMoveAsTheFrontAdvances() async throws {
    let prepared = try plan()
    let early = try pixels(prepared, visibility: .prefix(0.35))
    let later = try pixels(prepared, visibility: .prefix(0.75))
    // Exclude the advancing tip footprint. New dabs cannot cover this region.
    for y in 0..<Self.height {
      for x in 20..<65 {
        let index = (y * Self.width + x) * 4
        XCTAssertEqual(Array(early[index..<(index + 4)]), Array(later[index..<(index + 4)]))
      }
    }
  }
}
