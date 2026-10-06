import CoreGraphics
import LiveTextEffects
import SwiftUI
import Testing
@testable import ChalkLineEffects
@testable import LiveTextChalkRendering

struct ChalkContactContractTests {
  @Test(arguments: [WritingChalkStyle.fineLine, .dryBrush])
  func preservesPreviouslyAcceptedLongThinStrokes(style: WritingChalkStyle) throws {
    let configuration = try WritingChalkConfiguration(style: style)
    let plan = try ChalkPreparedContactPlan.prepare(strokes: [
      ChalkRenderStrokeGeometry(id: "long-thin", points: [
        ChalkRenderStrokePoint(x: 0, y: 20, width: 1),
        ChalkRenderStrokePoint(x: 2700, y: 20, width: 1),
      ])
    ], material: .liveText(configuration))
    let stroke = try #require(plan.strokes.first)
    #expect(stroke.dabs.count <= 8192)
    #expect(stroke.dabs.count > 2)
    #expect(stroke.dabs.first?.arcFraction == 0)
    #expect(stroke.dabs.last?.arcFraction == 1)
    #expect(abs(try #require(stroke.dabs.last).centerX - 2700) < 1)
  }

  @Test
  func rejectsTravelBeyondTheOriginalBudget() throws {
    let geometry = ChalkRenderStrokeGeometry(id: "over-budget", points: [
      ChalkRenderStrokePoint(x: 0, y: 0, width: 1),
      ChalkRenderStrokePoint(x: 4000, y: 0, width: 1),
    ])
    #expect(throws: ChalkRenderError.resourceLimitExceeded(
      resource: "chalk contact dabs", actual: 8193, limit: 8192)) {
      try ChalkPreparedContactPlan.prepare(strokes: [geometry], material: .liveText(.default))
    }
  }

  @Test(arguments: [WritingChalkStyle.fineLine, .dryBrush], [1.0, 3.0, 12.0])
  @MainActor
  func realCurvedRasterRespectsClipAndReveal(style: WritingChalkStyle, width: Double) throws {
    let plan = try ChalkPreparedContactPlan.prepare(strokes: [
      ChalkRenderStrokeGeometry(id: "pressure-curve", points: [
        ChalkRenderStrokePoint(x: 12, y: 50, width: width),
        ChalkRenderStrokePoint(x: 50, y: 22, width: width * 1.6),
        ChalkRenderStrokePoint(x: 92, y: 65, width: width),
        ChalkRenderStrokePoint(x: 145, y: 45, width: width * 0.7),
      ])
    ], material: .liveText(try WritingChalkConfiguration(style: style)))
    let clip = CGRect(x: 30, y: 10, width: 90, height: 80)
    let pixels = try raster(Canvas { context, _ in
      ChalkContactRenderer.paint(
        plan: plan, visibility: [.full], color: .cyan,
        documentOriginAtContextZero: .zero, clipBounds: clip, in: &context)
    }.frame(width: 160, height: 100), width: 160, height: 100)
    var insideCoverage = 0
    var outsideCoverage = 0
    for y in 0..<100 {
      for x in 0..<160 {
        let alpha = pixels[(y * 160 + x) * 4 + 3]
        if clip.contains(CGPoint(x: x, y: y)) { insideCoverage += Int(alpha) }
        else { outsideCoverage += Int(alpha) }
      }
    }
    #expect(insideCoverage > 0)
    #expect(outsideCoverage == 0)
  }

  @Test(arguments: ["한글 ABC", "곡선 OQ89"], ChalkWritingAnimation.allCases)
  @MainActor
  func publicSemanticViewRendersAndHasEmptyAnimationEndpoint(
    text: String, animation: ChalkWritingAnimation
  ) throws {
    let preparation = try ChalkWritingPreparation(text: text)
    let full = animation == .write ? 1.0 : 0.0
    let empty = 1 - full
    let painted = try raster(ChalkWritingText(
      preparation: preparation, animation: animation, progress: full
    ).frame(width: 500, height: 160), width: 500, height: 160)
    let erased = try raster(ChalkWritingText(
      preparation: preparation, animation: animation, progress: empty
    ).frame(width: 500, height: 160), width: 500, height: 160)
    #expect(stride(from: 3, to: painted.count, by: 4).contains { painted[$0] > 0 })
    #expect(stride(from: 3, to: erased.count, by: 4).allSatisfy { erased[$0] == 0 })
  }

  @Test
  @MainActor
  func dryBrushRetainsReadablePigmentAndCallerColor() throws {
    let plan = try ChalkPreparedContactPlan.prepare(strokes: [
      ChalkRenderStrokeGeometry(id: "readable-dry-line", points: [
        ChalkRenderStrokePoint(x: 10, y: 50, width: 8),
        ChalkRenderStrokePoint(x: 150, y: 50, width: 8),
      ])
    ], material: .liveText(try WritingChalkConfiguration(style: .dryBrush)))
    let pixels = try raster(Canvas { context, _ in
      ChalkContactRenderer.paint(
        plan: plan, visibility: [.full], color: .red,
        documentOriginAtContextZero: .zero,
        clipBounds: CGRect(x: 0, y: 0, width: 160, height: 100), in: &context)
    }.frame(width: 160, height: 100), width: 160, height: 100)
    var coverage = 0
    var tintedPixels = 0
    for y in 48..<52 {
      for x in 36..<124 {
        let index = (y * 160 + x) * 4
        coverage += Int(pixels[index + 3])
        if pixels[index] > pixels[index + 1] && pixels[index] > pixels[index + 2] {
          tintedPixels += 1
        }
      }
    }
    // Guard the observed ghost-like center while keeping the brush porous.
    let meanAlpha = Double(coverage) / (88 * 4)
    print("Dry brush center mean alpha: \(meanAlpha)")
    #expect(meanAlpha > 180)
    #expect(meanAlpha < 230)
    #expect(tintedPixels > 300)
  }

  @MainActor
  private func raster<V: View>(_ view: V, width: Int, height: Int) throws -> [UInt8] {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
  }
}
