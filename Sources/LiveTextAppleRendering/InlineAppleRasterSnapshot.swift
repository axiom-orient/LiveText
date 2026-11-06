import CoreGraphics
import Foundation
import SwiftUI

/// One immutable raster export of an already-configured LiveText Apple renderer.
///
/// The source renderer owns document preparation, layout, reveal, material,
/// viewport, and composition. This value is only the pixel result plus the
/// coordinate scale needed by downstream presentation effects.
public struct InlineAppleRasterSnapshot {
  public let image: CGImage
  public let size: CGSize
  public let scale: CGFloat
}

/// Resource policy applied before `ImageRenderer` is created.
///
/// The limits are owned here because `InlineApplePresentationSnapshotter` is
/// a public, standalone raster boundary.
public struct InlineAppleRasterSnapshotLimits: Sendable, Hashable {
  public static let maximumDimensionCeiling = 32_768
  public static let maximumPixelsCeiling = 268_435_456
  public static let `default` = InlineAppleRasterSnapshotLimits(
    validatedMaximumDimension: 8_192,
    maximumPixels: 16_777_216
  )

  public let maximumDimension: Int
  public let maximumPixels: Int

  public init(
    maximumDimension: Int = 8_192,
    maximumPixels: Int = 16_777_216
  ) throws {
    guard maximumDimension > 0,
      maximumDimension <= Self.maximumDimensionCeiling,
      maximumPixels > 0,
      maximumPixels <= Self.maximumPixelsCeiling
    else {
      throw InlineAppleRasterSnapshotError.invalidLimits(
        maximumDimension: maximumDimension,
        maximumPixels: maximumPixels
      )
    }
    self.init(
      validatedMaximumDimension: maximumDimension,
      maximumPixels: maximumPixels
    )
  }

  private init(validatedMaximumDimension: Int, maximumPixels: Int) {
    self.maximumDimension = validatedMaximumDimension
    self.maximumPixels = maximumPixels
  }
}

public enum InlineAppleRasterSnapshotError: Error, LocalizedError, Sendable {
  case invalidSize(width: Double, height: Double)
  case invalidScale(Double)
  case invalidLimits(maximumDimension: Int, maximumPixels: Int)
  case resourceLimitExceeded(
    widthPixels: Double,
    heightPixels: Double,
    maximumDimension: Int,
    maximumPixels: Int
  )
  case renderingFailed(width: Double, height: Double, scale: Double)

  public var errorDescription: String? {
    switch self {
    case .invalidSize(let width, let height):
      return "LiveText snapshot size must be finite and positive; received \(width)x\(height)."
    case .invalidScale(let scale):
      return "LiveText snapshot scale must be finite and positive; received \(scale)."
    case .invalidLimits(let maximumDimension, let maximumPixels):
      return
        "LiveText snapshot limits must be positive and within hard bounds; "
        + "received dimension=\(maximumDimension), pixels=\(maximumPixels)."
    case .resourceLimitExceeded(
      let widthPixels, let heightPixels, let maximumDimension, let maximumPixels):
      return
        "LiveText snapshot exceeds the pre-allocation raster budget "
        + "(\(widthPixels)x\(heightPixels) px; maxDimension=\(maximumDimension), "
        + "maxPixels=\(maximumPixels))."
    case .renderingFailed(let width, let height, let scale):
      return
        "LiveText could not rasterize the configured renderer "
        + "(viewport=\(width)x\(height), scale=\(scale))."
    }
  }
}

/// Terminal presentation boundary for hosts that compose LiveText with SwiftUI layer effects
/// before handing pixels to a raster consumer.
///
/// The caller owns the already-configured view and its visual revision. This function performs
/// no document preparation, layout, reveal scheduling, or effect orchestration; it rasterizes
/// the supplied presentation exactly once at the requested logical size and scale.
/// Content outside that size is clipped, with the top-leading origin preserved.
@MainActor
public enum InlineApplePresentationSnapshotter {
  public static func snapshot<Content: View>(
    content: Content,
    size: CGSize,
    scale: CGFloat = 1,
    limits: InlineAppleRasterSnapshotLimits = .default
  ) throws -> InlineAppleRasterSnapshot {
    try InlineAppleRasterSnapshotter.snapshot(
      content: content,
      size: size,
      scale: scale,
      limits: limits
    )
  }
}

/// Shared implementation for the renderer export methods and the public presentation snapshot
/// boundary. It remains package-internal so the validation/rasterization mechanics are not duplicated.
@MainActor
package enum InlineAppleRasterSnapshotter {
  public static func snapshot<Content: View>(
    content: Content,
    size: CGSize,
    scale: CGFloat,
    limits: InlineAppleRasterSnapshotLimits = .default
  ) throws -> InlineAppleRasterSnapshot {
    let width = Double(size.width)
    let height = Double(size.height)
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw InlineAppleRasterSnapshotError.invalidSize(width: width, height: height)
    }
    guard scale.isFinite, scale > 0 else {
      throw InlineAppleRasterSnapshotError.invalidScale(Double(scale))
    }

    let pixelWidth = ceil(width * Double(scale))
    let pixelHeight = ceil(height * Double(scale))
    let pixelArea = pixelWidth * pixelHeight
    guard pixelWidth.isFinite, pixelHeight.isFinite, pixelArea.isFinite,
      pixelWidth <= Double(limits.maximumDimension),
      pixelHeight <= Double(limits.maximumDimension),
      pixelArea <= Double(limits.maximumPixels)
    else {
      throw InlineAppleRasterSnapshotError.resourceLimitExceeded(
        widthPixels: pixelWidth,
        heightPixels: pixelHeight,
        maximumDimension: limits.maximumDimension,
        maximumPixels: limits.maximumPixels
      )
    }

    let renderer = ImageRenderer(
      content: content
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped())
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = scale
    renderer.isOpaque = false
    // Own the output format from the first frame. ImageRenderer.cgImage can
    // change its intermediate raster path after repeated filtered draws.
    // Drawing once into the same explicit RGBA format avoids that transition.
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: Int(pixelWidth), height: Int(pixelHeight),
        bitsPerComponent: 8, bytesPerRow: Int(pixelWidth) * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else {
      throw InlineAppleRasterSnapshotError.renderingFailed(
        width: width, height: height, scale: Double(scale))
    }
    context.scaleBy(x: scale, y: scale)
    var didRender = false
    renderer.render(rasterizationScale: scale) { _, draw in
      draw(context)
      didRender = true
    }
    guard didRender, let image = context.makeImage() else {
      throw InlineAppleRasterSnapshotError.renderingFailed(
        width: width,
        height: height,
        scale: Double(scale)
      )
    }

    return InlineAppleRasterSnapshot(image: image, size: size, scale: scale)
  }
}
