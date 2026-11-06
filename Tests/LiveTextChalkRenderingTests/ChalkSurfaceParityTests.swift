import CoreGraphics
import LiveTextEffects
import SwiftUI
import Testing
@testable import ChalkLineEffects
@testable import LiveTextChalkRendering

@MainActor
struct ChalkSurfaceParityTests {
  private let size = CGSize(width: 128, height: 96)
  private let rect = CGRect(x: 32, y: 28, width: 64, height: 32)

  @Test
  func separateLossFiltersPreserveCoverage() throws {
    let result = try renderPair(edgeRoughness: 0)
    let baseline = max(result.view, result.painter)
    #expect(baseline > 0)
    #expect(Double(abs(result.view - result.painter)) / Double(max(baseline, 1)) <= 0.05)
  }

  private func renderPair(edgeRoughness: Double) throws -> (view: Int, painter: Int) {
    let configuration = try WritingChalkConfiguration(
      seed: 0xED6E, grainAmount: 0.68, erosionAmount: 0.18, grainScale: 3.8,
      edgeRoughness: edgeRoughness, textureStyle: .photographic, style: .fineLine)
    let color = Color(red: 0.86, green: 0.19, blue: 0.07)
    let chalkColor = try ChalkColor(red: 0.86, green: 0.19, blue: 0.07)
    let size = size
    let rect = rect
    let view = ZStack(alignment: .topLeading) {
      Color.clear
      Color.white.frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .chalkEffect(configuration, color: chalkColor)
    let target = try WritingMaterialTarget(
      targetID: "surface-parity", documentOriginX: 0, documentOriginY: 0,
      destination: WritingMaterialRect(width: size.width, height: size.height))
    let painter = Canvas { context, _ in
      ChalkMaskRenderer.paint(
        mask: Path(rect), target: target, configuration: configuration,
        color: color, documentOriginAtContextZero: .zero, in: &context)
    }.frame(width: size.width, height: size.height)
    return (try coverage(view), try coverage(painter))
  }

  private func coverage<Content: View>(_ content: Content) throws -> Int {
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(size)
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
  }
}
