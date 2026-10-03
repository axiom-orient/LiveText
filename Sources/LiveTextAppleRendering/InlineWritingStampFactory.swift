import CoreGraphics
import Foundation
import LiveTextEffects
import SwiftUI

/// Procedurally bakes the media stamp sheets consumed by the writing
/// materials, and tints them once per pigment color.
///
/// Each material gets a small set of *nested* density variants computed from
/// one shared noise field (TAM nesting, Praun et al. 2001): a denser variant
/// contains every deposit of the lighter ones, so reveal and pressure ramps
/// never flicker. Brush/ink sheets are elongated erosion stamps whose hard
/// breaks read as dry-brush gaps. Chalk is a resource-backed surface, not a
/// geometry stamp. Generation is pure and deterministic in the material seed
/// — no external assets, no licensing surface.
package enum InlineWritingStampFactory {
  /// Side length of one baked stamp square in pixels.
  public static let stampSide = 128
  /// Density variants x grain phases. Phases offset the sampling window
  /// into the shared grain field (Procreate "Grain Offset"), so two stamps
  /// of the same density never print the same cloud.
  public static let variantCount = 9
  static let densityVariants = 3
  static let grainPhaseOffsets: [(Double, Double)] = [
    (0, 0), (37.4, -18.2), (-22.6, 41.8),
  ]

  /// Purely bakes the material's nested stamp masks (white with coverage alpha).
  /// Cache ownership belongs to the mounted render-content owner; keeping this
  /// factory stateless prevents process-global, unbounded raster retention.
  public static func stampMasks(for material: WritingMaterial) -> [CGImage] {
    bakeMasks(for: material)
  }

  /// Composites white masks into pigment-colored stamps.
  public static func tinted(masks: [CGImage], color: CGColor) -> [CGImage] {
    masks.map { mask in
      let side = CGFloat(stampSide)
      guard let context = makeBitmapContext(side: side) else { return mask }
      context.setFillColor(color)
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      context.setBlendMode(.destinationIn)
      context.draw(mask, in: CGRect(x: 0, y: 0, width: side, height: side))
      context.setBlendMode(.normal)
      return context.makeImage() ?? mask
    }
  }

  // MARK: Baking

  private static func bakeMasks(for material: WritingMaterial) -> [CGImage] {
    let side = stampSide
    let field = StampNoise(seed: material.seed)
    // Thresholds descend so variant N's coverage contains variant N-1's.
    let thresholds: [Double]
    let elongation: Double
    let edgeSoftness: Double
    switch material {
    case .marker, .knockout:
      // Flat film and stencil surfaces carry no media stamps.
      return []
    case .chalk:
      // Chalk is a source-mask surface. It is rendered from the canonical
      // resource-backed recipe and never enters the geometry stamp path.
      return []
    case .brush(let configuration):
      thresholds = [0.58, 0.50, 0.40]
      elongation = 3.0
      edgeSoftness = 0.06
      _ = configuration
    case .pen:
      thresholds = [0.66, 0.58, 0.50]
      elongation = 1.6
      edgeSoftness = 0.05
    case .ink(let configuration):
      thresholds = [0.56, 0.48, 0.40]
      elongation = 2.6
      edgeSoftness = 0.07
      _ = configuration
    }

    return thresholds.flatMap { threshold in
      Self.grainPhaseOffsets.map { offset in
        bakeMask(
          side: side, field: field, threshold: threshold,
          elongation: elongation, edgeSoftness: edgeSoftness,
          phaseOffset: offset)
      }
    }
  }

  private static func bakeMask(
    side: Int,
    field: StampNoise,
    threshold: Double,
    elongation: Double,
    edgeSoftness: Double,
    phaseOffset: (Double, Double)
  ) -> CGImage {
    let context = makeBitmapContext(side: CGFloat(side))!
    let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = context.bytesPerRow
    let inverseStretch = 1.0 / max(elongation, 1)
    for y in 0..<side {
      for x in 0..<side {
        // Normalized coordinates centered at 0, stretched along the stamp
        // axis so the art is elongated inside the square.
        let nx = (Double(x) / Double(side) - 0.5) * 2 * inverseStretch
        let ny = (Double(y) / Double(side) - 0.5) * 2
        let radius = hypot(nx, ny)
        // Superellipse-ish stamp body with a soft edge falloff.
        let bodyEdge = 1.0 - smoothstep(0.82 - edgeSoftness, 0.98, radius)
        guard bodyEdge > 0 else { continue }
        // Grain: coarse tooth plus fine sparkle, thresholded against the
        // variant density so coverage accumulates across nested variants.
        // The coarse tooth comes from the same shared grain field the rail
        // displacement samples, so stamp holes and boundary crumble are one
        // continuous material surface.
        let coarse = WritingStrokeGeometryPlan.grain(
          x: Double(x) + phaseOffset.0,
          y: Double(y) + phaseOffset.1,
          seed: field.seed)
        let fine = field.noise(x: x, y: y, feature: 5)
        let grain = 0.62 * coarse + 0.38 * fine
        let coverage = grain - threshold
        let alpha = max(0, min(1, coverage * 5.0)) * bodyEdge
        guard alpha > 0 else { continue }
        let offset = y * bytesPerRow + x * 4
        // White with straight alpha; premultiplied on write.
        buffer[offset] = UInt8((alpha * 255).rounded())
        buffer[offset + 1] = UInt8((alpha * 255).rounded())
        buffer[offset + 2] = UInt8((alpha * 255).rounded())
        buffer[offset + 3] = UInt8((alpha * 255).rounded())
      }
    }
    return context.makeImage()!
  }

  private static func makeBitmapContext(side: CGFloat) -> CGContext? {
    CGContext(
      data: nil,
      width: Int(side),
      height: Int(side),
      bitsPerComponent: 8,
      bytesPerRow: Int(side) * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let t = min(1, max(0, (value - edge0) / max(edge1 - edge0, 1e-9)))
    return t * t * (3 - 2 * t)
  }
}

/// Deterministic 2-D value noise for stamp baking (three octaves).
struct StampNoise {
  let seed: UInt64

  init(seed: UInt64) {
    self.seed = seed ^ 0x57A0
  }

  /// `feature` is the coarsest cell size in pixels; each octave halves it.
  func noise(x: Int, y: Int, feature: Int) -> Double {
    var amplitude = 1.0
    var total = 0.0
    var norm = 0.0
    var cell = Double(max(feature, 2))
    for octave in 0..<3 {
      total += amplitude * valueNoise(
        u: Double(x) / cell, v: Double(y) / cell, salt: UInt64(octave * 7919))
      norm += amplitude
      amplitude *= 0.55
      cell *= 0.5
    }
    return total / norm
  }

  private func valueNoise(u: Double, v: Double, salt: UInt64) -> Double {
    let ix = floor(u), iy = floor(v)
    let fx = u - ix, fy = v - iy
    let sx = fx * fx * (3 - 2 * fx)
    let sy = fy * fy * (3 - 2 * fy)
    let a = lattice(Int(ix), Int(iy), salt)
    let b = lattice(Int(ix) + 1, Int(iy), salt)
    let c = lattice(Int(ix), Int(iy) + 1, salt)
    let d = lattice(Int(ix) + 1, Int(iy) + 1, salt)
    return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
  }

  private func lattice(_ x: Int, _ y: Int, _ salt: UInt64) -> Double {
    var value = seed ^ salt &* 0x9E37_79B9_7F4A_7C15
    value ^= UInt64(bitPattern: Int64(x)) &* 0xBF58_476D_1CE4_E5B9
    value ^= UInt64(bitPattern: Int64(y)) &* 0x94D0_49BB_1331_11EB
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }
}

/// Draws planned stamps with cached tinted images. One shared implementation
/// keeps SwiftUI and Canvas rasterization identical; both adapters call this
/// inside their coverage-clipped layer. The painter mutates only Graphics
/// Context render state (transform, opacity, blend mode) and restores it.
package enum InlineWritingStampPainter {
  public static func draw(
    _ stamps: [WritingStrokeStamp],
    images: [CGImage],
    in context: inout GraphicsContext
  ) {
    guard !stamps.isEmpty, !images.isEmpty else { return }
    // Canvas Image draws ignore the context blend mode, so erosion stamps
    // cannot punch through a body directly. Erosions accumulate into one
    // nested layer (overlaps must not over-erase) and the layer composites
    // onto the parent with destinationOut — the wash-coverage model.
    let erosions = stamps.filter(\.isErosion)
    let deposits = stamps.filter { !$0.isErosion }

    let base = context.transform
    for stamp in deposits {
      drawStamp(stamp, images: images, base: base, in: &context)
    }
    if !erosions.isEmpty {
      context.blendMode = .destinationOut
      context.drawLayer { stampLayer in
        stampLayer.blendMode = .normal
        stampLayer.opacity = 1
        // Read the layer transform once: each drawStamp mutates it, and a
        // per-iteration read would compound every stamp's translation.
        let layerBase = stampLayer.transform
        for stamp in erosions {
          drawStamp(stamp, images: images, base: layerBase, in: &stampLayer)
        }
      }
      context.blendMode = .normal
    }
    context.transform = base
    context.blendMode = .normal
    context.opacity = 1
  }

  private static func drawStamp(
    _ stamp: WritingStrokeStamp,
    images: [CGImage],
    base: CGAffineTransform,
    in context: inout GraphicsContext
  ) {
    let index = min(images.count - 1, Int(stamp.variant * Double(images.count)))
    let image = Image(decorative: images[index], scale: 1)
    let side = stamp.diameter
    var transform = base
    transform = transform.translatedBy(x: CGFloat(stamp.x), y: CGFloat(stamp.y))
    transform = transform.rotated(by: CGFloat(stamp.angle))
    if stamp.flip {
      transform = transform.scaledBy(x: -1, y: 1)
    }
    context.transform = transform
    context.opacity = stamp.alpha
    context.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
  }
}
