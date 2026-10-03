#if os(iOS)
import CoreGraphics
import Foundation
import UIKit

public enum DustError: Error, LocalizedError, Sendable {
  case emptyContent(operation: String)
  case rasterizationFailed(operation: String)
  case invalidImage
  case invalidSVG(reason: String)
  case invalidConfiguration(reason: String)
  case resourceLimitExceeded(operation: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .emptyContent(let operation):
      return "DustKit \(operation) produced no visible content."
    case .rasterizationFailed(let operation):
      return "DustKit could not rasterize \(operation)."
    case .invalidImage:
      return "DustKit received an image that could not be normalized."
    case .invalidSVG(let reason):
      return "DustKit could not parse SVG: \(reason)"
    case .invalidConfiguration(let reason):
      return "DustKit configuration is invalid: \(reason)."
    case .resourceLimitExceeded(let operation, let reason):
      return "DustKit rejected \(operation) before allocation: \(reason)."
    }
  }
}

public enum DustRenderingError: Error, LocalizedError, Equatable, Sendable {
  case metalUnavailable
  case commandQueueUnavailable
  case shaderLibraryUnavailable(cause: String)
  case missingShader(name: String)
  case pipelineCreationFailed(operation: String, cause: String)
  case textureCreationFailed(operation: String, cause: String)
  case bufferCreationFailed(operation: String)
  case commandEncodingFailed(operation: String)
  case commandExecutionFailed(cause: String)

  public var errorDescription: String? {
    switch self {
    case .metalUnavailable:
      return "DustKit cannot render because Metal is unavailable."
    case .commandQueueUnavailable:
      return "DustKit could not create a Metal command queue."
    case .shaderLibraryUnavailable(let cause):
      return "DustKit could not load its Metal shader library: \(cause)"
    case .missingShader(let name):
      return "DustKit shader library is missing entry point \(name)."
    case .pipelineCreationFailed(let operation, let cause):
      return "DustKit could not create the \(operation) render pipeline: \(cause)"
    case .textureCreationFailed(let operation, let cause):
      return "DustKit could not create the \(operation) texture: \(cause)"
    case .bufferCreationFailed(let operation):
      return "DustKit could not create the Metal buffer for \(operation)."
    case .commandEncodingFailed(let operation):
      return "DustKit could not encode the Metal command for \(operation)."
    case .commandExecutionFailed(let cause):
      return "DustKit Metal command execution failed: \(cause)"
    }
  }
}

public enum DustPreset: String, CaseIterable, Sendable {
  case softDust
  case thanos
  case ash
  case sand
  /// Expands the assembled source into a deterministic 360° particle burst.
  case radialExpand
}

public enum DustTransition: String, CaseIterable, Sendable {
  /// Starts with the canonical source and ends with dispersed particles.
  ///
  /// As progress increases, the source resolves from its trailing edge toward
  /// its leading edge. The particle trajectory follows the configured travel
  /// vector, so this is the tail-to-leading disappearance order.
  case disintegrate
  /// Starts with dispersed particles and ends with the canonical source.
  ///
  /// As progress increases, the source resolves from its leading edge toward
  /// its trailing edge. The particle trajectory is evaluated backward while
  /// this source-axis order remains forward.
  case assemble
}

extension DustTransition {
  func motionProgress(for progress: Float) -> Float {
    switch self {
    case .disintegrate:
      return progress
    case .assemble:
      return 1 - progress
    }
  }

  func drawsSource(at progress: Float) -> Bool {
    switch self {
    case .disintegrate:
      return progress <= 0
    case .assemble:
      return progress >= 1
    }
  }

  func drawsParticles(at progress: Float) -> Bool {
    switch self {
    case .disintegrate:
      return progress > 0 && progress < 1
    case .assemble:
      return progress >= 0 && progress < 1
    }
  }
}

public enum DustLayoutPolicy: String, Codable, CaseIterable, Hashable, Sendable {
  /// Preserves the source's layout size and lets particles draw outside it.
  /// Ancestor clipping can trim the effect envelope in this mode.
  case sourceBounds

  /// Reserves the complete conservative particle envelope in layout.
  /// Use this when the immediate container clips to the DustView bounds.
  case effectBounds
}

public struct DustConfiguration: Sendable {
  public static let minimumParticleSize: CGFloat = 0.35
  public static let maximumParticleSize: CGFloat = 128
  public static let maximumTravelDistance: CGFloat = 4_096
  public static let minimumSpreadRadians: CGFloat = 0
  public static let maximumSpreadRadians: CGFloat = .pi * 2
  public static let maximumSupportedParticleCount = 250_000

  public static let `default` = DustConfiguration(
    validatedDirection: nil,
    distance: nil,
    particleSize: 1,
    seed: 42,
    maximumParticleCount: 60_000,
    spreadRadians: nil
  )

  public let direction: CGVector?
  public let distance: CGFloat?
  public let particleSize: CGFloat
  public let seed: UInt32
  public let maximumParticleCount: Int
  /// Overrides the preset's angular particle spread when non-nil.
  public let spreadRadians: CGFloat?

  public init(
    direction: CGVector? = nil,
    distance: CGFloat? = nil,
    particleSize: CGFloat = 1,
    seed: UInt32 = 42,
    maximumParticleCount: Int = 60_000,
    spreadRadians: CGFloat? = nil
  ) throws {
    if let direction {
      guard direction.dx.isFinite, direction.dy.isFinite else {
        throw DustError.invalidConfiguration(reason: "direction components must be finite")
      }
    }
    if let distance {
      guard distance.isFinite, distance >= 0, distance <= Self.maximumTravelDistance else {
        throw DustError.invalidConfiguration(
          reason: "distance must be finite and within 0...\(Int(Self.maximumTravelDistance)) pt"
        )
      }
    }
    if let spreadRadians {
      guard spreadRadians.isFinite,
        spreadRadians >= Self.minimumSpreadRadians,
        spreadRadians <= Self.maximumSpreadRadians
      else {
        throw DustError.invalidConfiguration(
          reason:
            "spreadRadians must be finite and within 0...\(Self.maximumSpreadRadians) radians"
        )
      }
    }
    guard particleSize.isFinite,
      particleSize >= Self.minimumParticleSize,
      particleSize <= Self.maximumParticleSize
    else {
      throw DustError.invalidConfiguration(
        reason:
          "particleSize must be finite and within \(Self.minimumParticleSize)...\(Self.maximumParticleSize) pt"
      )
    }
    guard maximumParticleCount >= 1,
      maximumParticleCount <= Self.maximumSupportedParticleCount
    else {
      throw DustError.invalidConfiguration(
        reason: "maximumParticleCount must be within 1...\(Self.maximumSupportedParticleCount)"
      )
    }

    self.init(
      validatedDirection: direction,
      distance: distance,
      particleSize: particleSize,
      seed: seed,
      maximumParticleCount: maximumParticleCount,
      spreadRadians: spreadRadians
    )
  }

  private init(
    validatedDirection: CGVector?,
    distance: CGFloat?,
    particleSize: CGFloat,
    seed: UInt32,
    maximumParticleCount: Int,
    spreadRadians: CGFloat?
  ) {
    self.direction = validatedDirection
    self.distance = distance
    self.particleSize = particleSize
    self.seed = seed
    self.maximumParticleCount = maximumParticleCount
    self.spreadRadians = spreadRadians
  }
}

public struct DustPathStyle: @unchecked Sendable {
  public static let maximumStrokeWidth: CGFloat = 4_096
  public static let `default` = DustPathStyle(
    validatedFill: .label,
    stroke: nil,
    strokeWidth: 0
  )

  public let fill: UIColor?
  public let stroke: UIColor?
  public let strokeWidth: CGFloat

  public init(
    fill: UIColor? = .label,
    stroke: UIColor? = nil,
    strokeWidth: CGFloat = 0
  ) throws {
    guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= Self.maximumStrokeWidth else {
      throw DustError.invalidConfiguration(
        reason: "strokeWidth must be finite and within 0...\(Int(Self.maximumStrokeWidth)) pt"
      )
    }
    self.init(validatedFill: fill, stroke: stroke, strokeWidth: strokeWidth)
  }

  private init(validatedFill: UIColor?, stroke: UIColor?, strokeWidth: CGFloat) {
    self.fill = validatedFill
    self.stroke = stroke
    self.strokeWidth = strokeWidth
  }
}

public struct DustSource {
  let raster: DustRaster
  let semanticLabel: String?

  public var size: CGSize { raster.canvasSize }

  public init(image: UIImage) throws {
    self.raster = try DustRasterizer.image(image)
    self.semanticLabel = nil
  }

  /// Creates a particle source from an already-rendered authoritative surface.
  ///
  /// Unlike `init(image:)`, this initializer preserves the complete pixel
  /// bounds instead of cropping transparent edges. It is intended for renderer
  /// handoffs such as LiveText → DustKit, where layout and reveal have already
  /// been resolved and the particle surface must keep exactly the same canvas.
  /// DustKit only normalizes the pixels for its Metal texture/alpha mask; it
  /// does not parse, shape, or lay out text on this path.
  public init(
    snapshot image: CGImage,
    scale: CGFloat,
    semanticLabel: String? = nil
  ) throws {
    self.raster = try DustRasterizer.snapshot(image, scale: scale)
    self.semanticLabel = semanticLabel
  }

  public init(
    text: NSAttributedString,
    maxWidth: CGFloat? = nil,
    scale: CGFloat = 3
  ) throws {
    self.raster = try DustRasterizer.text(text, maxWidth: maxWidth, scale: scale)
    self.semanticLabel = text.string
  }

  public init(
    text: String,
    font: UIFont,
    color: UIColor = .label,
    maxWidth: CGFloat? = nil,
    scale: CGFloat = 3
  ) throws {
    self.raster = try DustRasterizer.text(
      NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: color,
        ]
      ),
      maxWidth: maxWidth,
      scale: scale
    )
    self.semanticLabel = text
  }

  public init(
    path: CGPath,
    style: DustPathStyle = .default,
    scale: CGFloat = 3
  ) throws {
    self.raster = try DustRasterizer.path(path, style: style, scale: scale)
    self.semanticLabel = nil
  }

  public init(svgData: Data, scale: CGFloat = 3) throws {
    self.raster = try DustRasterizer.svg(svgData, scale: scale)
    self.semanticLabel = nil
  }
}

struct DustRaster {
  let image: CGImage
  let alphaMask: DustAlphaMask
  let canvasSize: CGSize
  let scale: CGFloat
}

enum DustResourceLimits {
  static let maximumRasterDimension = 8_192
  static let maximumRasterPixels = 16_777_216
  static let maximumSVGBytes = 4 * 1_024 * 1_024
  static let maximumSVGShapes = 10_000

  static func validateRaster(size: CGSize, scale: CGFloat, operation: String) throws {
    guard size.width.isFinite, size.height.isFinite, scale.isFinite,
      size.width > 0, size.height > 0, scale >= 1
    else {
      throw DustError.invalidConfiguration(
        reason: "\(operation) size and scale must be finite, positive, and scale must be >= 1"
      )
    }

    let pixelWidth = ceil(size.width * scale)
    let pixelHeight = ceil(size.height * scale)
    guard pixelWidth.isFinite, pixelHeight.isFinite,
      pixelWidth <= CGFloat(maximumRasterDimension),
      pixelHeight <= CGFloat(maximumRasterDimension)
    else {
      throw DustError.resourceLimitExceeded(
        operation: operation,
        reason: "raster dimensions exceed \(maximumRasterDimension) px"
      )
    }

    let area = pixelWidth * pixelHeight
    guard area.isFinite, area <= CGFloat(maximumRasterPixels) else {
      throw DustError.resourceLimitExceeded(
        operation: operation,
        reason: "raster area exceeds \(maximumRasterPixels) pixels"
      )
    }
  }

  static func validateRaster(widthPixels: Int, heightPixels: Int, operation: String) throws {
    guard widthPixels > 0, heightPixels > 0,
      widthPixels <= maximumRasterDimension,
      heightPixels <= maximumRasterDimension
    else {
      throw DustError.resourceLimitExceeded(
        operation: operation,
        reason: "raster dimensions exceed \(maximumRasterDimension) px"
      )
    }
    let (area, overflow) = widthPixels.multipliedReportingOverflow(by: heightPixels)
    guard !overflow, area <= maximumRasterPixels else {
      throw DustError.resourceLimitExceeded(
        operation: operation,
        reason: "raster area exceeds \(maximumRasterPixels) pixels"
      )
    }
  }
}

struct DustMotionProfile {
  let direction: CGVector
  let distance: CGFloat
  let spreadRadians: Float
  let rotationRadians: Float
  let stagger: Float
  let gravity: CGFloat
  let flutter: CGFloat
  let fadeStart: Float
  let endScale: Float
  let morphStart: Float
  let morphEnd: Float
  let particleRoundness: Float
  let driftFrequency: Float
  let microFrequency: Float
  let waveDirectionRadians: Float
  let minimumDistanceMultiplier: CGFloat
  let maximumDistanceMultiplier: CGFloat

  func renderPadding(particleExtent: CGFloat) -> CGFloat {
    let extent = particleExtent.isFinite ? max(particleExtent, 0) : 0
    let maximumParticleScale = max(CGFloat(endScale), 1)
    return ceil(
      distance * maximumDistanceMultiplier
        + abs(gravity)
        + flutter
        + extent * maximumParticleScale
        + 1
    )
  }

  static func resolve(
    preset: DustPreset,
    configuration: DustConfiguration
  ) -> DustMotionProfile {
    let base: DustMotionProfile
    switch preset {
    case .softDust:
      base = .init(
        direction: .init(dx: 0.95, dy: -0.31), distance: 52,
        spreadRadians: .pi / 15, rotationRadians: .pi / 7.5,
        stagger: 0.54, gravity: 0, flutter: 8, fadeStart: 0.36,
        endScale: 0.06, morphStart: 0.10, morphEnd: 0.31,
        particleRoundness: 0.86, driftFrequency: 5.2, microFrequency: 13,
        waveDirectionRadians: 0, minimumDistanceMultiplier: 0.72,
        maximumDistanceMultiplier: 1.28
      )
    case .thanos:
      base = .init(
        direction: .init(dx: 0.92, dy: -0.38), distance: 96,
        spreadRadians: .pi / 4.2, rotationRadians: .pi * 0.9,
        stagger: 0.38, gravity: 12, flutter: 24, fadeStart: 0.18,
        endScale: 0.13, morphStart: 0.03, morphEnd: 0.18,
        particleRoundness: 0.62, driftFrequency: 4.2, microFrequency: 10,
        waveDirectionRadians: 0, minimumDistanceMultiplier: 0.72,
        maximumDistanceMultiplier: 1.28
      )
    case .ash:
      base = .init(
        direction: .init(dx: 0.45, dy: -0.89), distance: 68,
        spreadRadians: .pi / 8, rotationRadians: .pi / 2,
        stagger: 0.46, gravity: -20, flutter: 17, fadeStart: 0.44,
        endScale: 0.04, morphStart: 0.08, morphEnd: 0.26,
        particleRoundness: 0.78, driftFrequency: 3.8, microFrequency: 9,
        waveDirectionRadians: -.pi / 2, minimumDistanceMultiplier: 0.72,
        maximumDistanceMultiplier: 1.28
      )
    case .sand:
      base = .init(
        direction: .init(dx: 0.55, dy: 0.83), distance: 58,
        spreadRadians: .pi / 10, rotationRadians: .pi / 3,
        stagger: 0.43, gravity: 34, flutter: 5, fadeStart: 0.29,
        endScale: 0.09, morphStart: 0.07, morphEnd: 0.23,
        particleRoundness: 0.72, driftFrequency: 4.8, microFrequency: 11,
        waveDirectionRadians: .pi / 2, minimumDistanceMultiplier: 0.72,
        maximumDistanceMultiplier: 1.28
      )
    case .radialExpand:
      base = .init(
        direction: .init(dx: 1, dy: 0), distance: 38,
        spreadRadians: .pi * 2, rotationRadians: .pi * 0.55,
        stagger: 0.34, gravity: 0, flutter: 10, fadeStart: 0.16,
        endScale: 1.42, morphStart: 0.02, morphEnd: 0.24,
        particleRoundness: 0.76, driftFrequency: 4.4, microFrequency: 10,
        waveDirectionRadians: 0, minimumDistanceMultiplier: 0.72,
        maximumDistanceMultiplier: 1.28
      )
    }

    let rawDirection = configuration.direction ?? base.direction
    let length = hypot(rawDirection.dx, rawDirection.dy)
    let direction =
      length > 0.0001
      ? CGVector(dx: rawDirection.dx / length, dy: rawDirection.dy / length)
      : base.direction
    let waveDirectionRadians: Float
    if let customDirection = configuration.direction,
      hypot(customDirection.dx, customDirection.dy) > 0.0001
    {
      waveDirectionRadians = Float(atan2(direction.dy, direction.dx))
    } else {
      waveDirectionRadians = base.waveDirectionRadians
    }

    return .init(
      direction: direction,
      distance: configuration.distance ?? base.distance,
      spreadRadians: Float(configuration.spreadRadians ?? CGFloat(base.spreadRadians)),
      rotationRadians: base.rotationRadians,
      stagger: base.stagger,
      gravity: base.gravity,
      flutter: base.flutter,
      fadeStart: base.fadeStart,
      endScale: base.endScale,
      morphStart: base.morphStart,
      morphEnd: base.morphEnd,
      particleRoundness: base.particleRoundness,
      driftFrequency: base.driftFrequency,
      microFrequency: base.microFrequency,
      waveDirectionRadians: waveDirectionRadians,
      minimumDistanceMultiplier: base.minimumDistanceMultiplier,
      maximumDistanceMultiplier: base.maximumDistanceMultiplier
    )
  }
}
#endif
