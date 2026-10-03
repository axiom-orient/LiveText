import Foundation

/// A small, renderer-neutral pigment tile used by non-chalk filled surfaces.
///
/// The tile is intentionally independent of SwiftUI/Core Graphics.  The
/// render adapters turn the bytes into one cached image and clip repeated
/// copies to the actual glyph path.  Keeping the phase in document space and
/// deriving the samples from the material seed makes scrolling and adapter
/// choice unable to change the material pattern.
public struct WritingMaterialTexturePlan: Codable, Equatable, Hashable, Sendable {
  public static let defaultDimension = 96
  public static let defaultPointSize = 48.0
  public static let maximumDimension = 128

  /// The tile is square and encoded as RGBA8, row-major, top-to-bottom.
  /// Pixels are non-premultiplied so the platform adapter can construct a
  /// normal `CGImage` without changing the recipe's color/alpha relationship.
  public let dimension: Int
  public let pointSize: Double
  public let pixels: [UInt8]
  public let seed: UInt64
  public let kind: WritingMaterialKind

  public init(
    material: WritingMaterial,
    dimension: Int = Self.defaultDimension,
    pointSize: Double = Self.defaultPointSize
  ) {
    precondition(material.kind != .chalk, "chalk uses WritingChalkSurfacePlan")
    let dimension = max(8, min(Self.maximumDimension, dimension))
    let pointSize = pointSize.isFinite && pointSize > 0
      ? min(256, max(8, pointSize))
      : Self.defaultPointSize
    self.dimension = dimension
    self.pointSize = pointSize
    self.seed = material.seed
    self.kind = material.kind

    let random = MaterialTextureRandom(seed: material.seed ^ 0x5445_5854_5552_45)
    var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
    // Sample a half-open [0, 1) domain. The non-chalk pigment recipes are
    // periodic by construction, so adjacent tiles share the same boundary.
    let period = Double(max(1, dimension))
    for y in 0..<dimension {
      for x in 0..<dimension {
        let u = Double(x) / period
        let v = Double(y) / period
        let coarse = random.periodicNoise(
          u: u, v: v, frequencyX: 3, frequencyY: 2)
        let fine = random.periodicNoise(
          u: u, v: v, frequencyX: 9, frequencyY: 7)
        let directional = random.periodicDirectional(u: u, v: v)
        let sample: MaterialTextureSample
        switch material {
        case .chalk:
          preconditionFailure("chalk uses WritingChalkSurfacePlan")
        case .brush(let configuration):
          sample = Self.brushSample(
            u: u,
            v: v,
            coarse: coarse,
            fine: fine,
            directional: directional,
            configuration: configuration
          )
        case .pen(let configuration):
          sample = Self.penSample(
            u: u,
            v: v,
            coarse: coarse,
            fine: fine,
            directional: directional,
            configuration: configuration
          )
        case .ink(let configuration):
          sample = Self.inkSample(
            u: u,
            v: v,
            coarse: coarse,
            fine: fine,
            directional: directional,
            configuration: configuration
          )
        case .marker(let configuration):
          sample = Self.markerSample(
            u: u,
            v: v,
            coarse: coarse,
            fine: fine,
            configuration: configuration
          )
        case .knockout:
          // The punch surface has no pigment texture.
          sample = MaterialTextureSample(alpha: 0, isWhite: true)
        }
        let offset = (y * dimension + x) * 4
        // The recipes use white for chalk's additive deposition and black for
        // the subtractive pigment recipes.  Adapters select the blend mode;
        // no source color is hard-coded into this renderer-neutral plan.
        let component: UInt8 = sample.isWhite ? 255 : 0
        pixels[offset] = component
        pixels[offset + 1] = component
        pixels[offset + 2] = component
        pixels[offset + 3] = UInt8((min(1, max(0, sample.alpha)) * 255).rounded())
      }
    }
    self.pixels = pixels
  }

  private enum CodingKeys: String, CodingKey { case dimension, pointSize, pixels, seed, kind }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let dimension = try values.decode(Int.self, forKey: .dimension)
    let pointSize = try values.decode(Double.self, forKey: .pointSize)
    let pixels = try values.decode([UInt8].self, forKey: .pixels)
    let seed = try values.decode(UInt64.self, forKey: .seed)
    let kind = try values.decode(WritingMaterialKind.self, forKey: .kind)
    guard (8...Self.maximumDimension).contains(dimension),
      pointSize.isFinite, (8...256).contains(pointSize),
      kind != .chalk,
      pixels.count == dimension * dimension * 4
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .pixels, in: values,
        debugDescription: "material texture dimensions, kind, and RGBA byte count must be canonical"
      )
    }
    self.dimension = dimension
    self.pointSize = pointSize
    self.pixels = pixels
    self.seed = seed
    self.kind = kind
  }

  private struct MaterialTextureSample {
    let alpha: Double
    let isWhite: Bool
  }

  private static func brushSample(
    u: Double,
    v: Double,
    coarse: Double,
    fine: Double,
    directional: Double,
    configuration: WritingBrushConfiguration
  ) -> MaterialTextureSample {
    let streak = 0.50 + 0.50 * sin((v * 11 + u * 2) * .pi * 2 + directional * 0.9)
    let bristle = max(0, 0.32 + streak * 0.48 + coarse * 0.22 + fine * 0.10)
    let drySkip = max(0, (0.22 - configuration.coverage) * 1.8) + (1 - fine) * 0.10
    return MaterialTextureSample(
      alpha: max(0, min(1, bristle * (0.58 + configuration.coverage * 0.42) - drySkip)),
      isWhite: false
    )
  }

  private static func penSample(
    u: Double,
    v: Double,
    coarse: Double,
    fine: Double,
    directional: Double,
    configuration: WritingPenConfiguration
  ) -> MaterialTextureSample {
    let nib = 0.74 + 0.16 * sin((u * 9 + v * 2) * .pi * 2 + directional)
    let tooth = 0.94 - (1 - fine) * 0.12 - (1 - coarse) * 0.05
    return MaterialTextureSample(
      alpha: max(0, min(1, nib * tooth * (0.78 + configuration.coverage * 0.22))),
      isWhite: false
    )
  }

  private static func markerSample(
    u: Double,
    v: Double,
    coarse: Double,
    fine: Double,
    configuration: WritingMarkerConfiguration
  ) -> MaterialTextureSample {
    // Flat film with faint bleed mottling across the tile.
    let film = 0.86 + 0.10 * coarse
    let bleed = (0.5 - fine) * configuration.bleed * 0.6
    return MaterialTextureSample(
      alpha: max(0, min(1, film - bleed)),
      isWhite: false
    )
  }

  private static func inkSample(
    u: Double,
    v: Double,
    coarse: Double,
    fine: Double,
    directional: Double,
    configuration: WritingInkConfiguration
  ) -> MaterialTextureSample {
    let pooling = max(0, min(1, 0.62 + coarse * configuration.pooling * 0.40))
    let flow = 0.56 + 0.30 * sin((u * 7 + v * 3) * .pi * 2 + directional * 1.4)
    let diffusion = configuration.bleed * (0.18 + 0.28 * (1 - fine))
    return MaterialTextureSample(
      alpha: max(0, min(1, pooling * flow + diffusion)),
      isWhite: false
    )
  }
}

private struct MaterialTextureRandom {
  private let seed: UInt64

  init(seed: UInt64) { self.seed = seed }

  /// A deterministic, smooth value field on a unit torus. Integer
  /// frequencies make f(0, y) == f(1, y) and f(x, 0) == f(x, 1), while the
  /// seeded phases keep each material configuration distinct. This is a
  /// compact periodic alternative to allocating a larger noise atlas.
  func periodicNoise(
    u: Double,
    v: Double,
    frequencyX: Int,
    frequencyY: Int
  ) -> Double {
    let tau = Double.pi * 2
    let x = u * Double(frequencyX) * tau
    let y = v * Double(frequencyY) * tau
    let phaseA = phase(0x41)
    let phaseB = phase(0xB7)
    let phaseC = phase(0xD3)
    let value = 0.5
      + 0.22 * sin(x + phaseA)
      + 0.18 * cos(y + phaseB)
      + 0.13 * sin(x + y + phaseC)
      + 0.07 * cos(x - y + phase(0xE9))
    return min(1, max(0, value))
  }

  func periodicDirectional(u: Double, v: Double) -> Double {
    let first = periodicNoise(u: u, v: v, frequencyX: 5, frequencyY: 1)
    let second = periodicNoise(u: v, v: u, frequencyX: 7, frequencyY: 2)
    return (first + second) * 0.5
  }

  private func phase(_ salt: UInt64) -> Double {
    let value = mix(seed, salt)
    return Double(value >> 11) / Double(UInt64.max >> 11) * Double.pi * 2
  }

  private func mix(_ value: UInt64, _ input: UInt64) -> UInt64 {
    var result = value ^ input &* 0x9E37_79B9_7F4A_7C15
    result ^= result >> 30
    result &*= 0xBF58_476D_1CE4_E5B9
    result ^= result >> 27
    result &*= 0x94D0_49BB_1331_11EB
    return result ^ (result >> 31)
  }
}
