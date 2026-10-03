import CoreGraphics
import Foundation
import LiveTextChalkRendering
import LiveTextEffects

/// Platform bridge for the renderer-neutral material tile.
///
/// This target owns the Core Graphics object; the writing-effects target stays
/// free of Apple framework types.  The resulting image is immutable and can be
/// retained by a bounded renderer cache and reused for every glyph in a
/// document.
package enum InlineWritingMaterialTextureFactory {
  public static func makeImage(
    from plan: WritingMaterialTexturePlan
  ) -> CGImage? {
    let dimension = plan.dimension
    guard dimension >= 8,
      plan.pixels.count == dimension * dimension * 4,
      plan.pointSize.isFinite, plan.pointSize > 0
    else { return nil }
    let data = Data(plan.pixels)
    guard let provider = CGDataProvider(data: data as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: dimension,
      height: dimension,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: dimension * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  }

  /// Returns the package-canonical chalk substrate coverage mask. Resource decoding
  /// is owned by the single LiveTextChalkRendering engine so public factory and
  /// runtime pigment paths cannot drift.
  public static func makeChalkCoverageMask(
    for plan: WritingChalkSurfacePlan
  ) throws -> CGImage {
    try ChalkSubstrateResource.coverageMask(for: plan.textureStyle)
  }

}
