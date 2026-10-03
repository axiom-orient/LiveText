import Foundation

/// The one renderer-neutral surface recipe used by every chalk adapter.
///
/// Chalk is a pigment surface, not a second stroke geometry.  The caller
/// supplies the source mask/centerline and adapters only apply this bounded
/// recipe to that geometry.  Keeping these values here prevents SwiftUI,
/// Canvas, and the semantic writing view from drifting apart.
public struct WritingChalkSurfacePlan: Codable, Equatable, Hashable, Sendable {
  /// Maximum outward expansion of the one-point source mask, including the
  /// bounded edge-dust offsets. Adapters use this for vector cell bounds and
  /// section culling; it never changes the source stroke geometry.
  public static let maximumPaintOutset = 2.75

  public let configuration: WritingChalkConfiguration
  public let textureStyle: WritingChalkTextureStyle
  public let texturePointSize: Double
  public let textureOpacity: Double
  public let erosionOpacity: Double
  /// The complete deterministic edge-dust recipe shared by every Apple
  /// adapter. It includes the seed-derived deposit phase/offsets and the
  /// texture-mask policy; adapters only translate the values to their drawing
  /// API.
  public let edgeDustRecipe: WritingChalkEdgeDustRecipe
  public let paintOutset: Double
  public let baseOpacity: Double
  /// Portion of the face mask that is removed to expose the board between
  /// chalk particles. This is separate from `erosionOpacity`, which controls
  /// the larger edge/coverage loss.
  public let grainCutoutOpacity: Double
  /// Low-opacity pigment deposited by the same face mask. Keeping this pass
  /// caller-tinted preserves the writing color while the cutout creates
  /// visible powder gaps.
  public let grainPigmentOpacity: Double

  /// A second, smaller document-space scale keeps chalk's granular structure
  /// visible inside ordinary text while `texturePointSize` carries the broad
  /// powder variation. Both scales use the same source mask and seed phase;
  /// this is material detail, never a change to source geometry.
  public var detailTexturePointSize: Double {
    let normalizedScale = min(2.5, max(0.5, configuration.grainScale / 3.5))
    let base: Double
    switch configuration.textureStyle {
    case .fineGrain: base = 12
    case .photographic: base = 16
    case .referenceSampled: base = 14
    }
    return min(48, max(8, (base * normalizedScale).rounded()))
  }

  /// Opacity budget for the fine-grain pass. It is zero for the explicit
  /// zero-variation control, preserving the ordinary solid-face contract.
  public var detailTextureOpacity: Double {
    let hasSurfaceVariation = configuration.grainAmount > 0
      || configuration.erosionAmount > 0
      || configuration.edgeRoughness > 0
    guard hasSurfaceVariation else { return 0 }
    return min(
      0.42,
      0.10 + configuration.grainAmount * 0.30
        + configuration.erosionAmount * 0.08
    )
  }

  /// Portions of the fine-grain pass used to expose bounded board-colored
  /// gaps and low-opacity pigment. Keeping these derived from one opacity
  /// value prevents SwiftUI and Canvas from selecting different recipes.
  public var detailGrainCutoutOpacity: Double {
    min(0.22, detailTextureOpacity * 0.56)
  }

  public var detailGrainPigmentOpacity: Double {
    min(0.18, detailTextureOpacity * 0.44)
  }

  public init(configuration: WritingChalkConfiguration) {
    self.configuration = configuration
    self.textureStyle = configuration.textureStyle
    let hasSurfaceVariation = configuration.grainAmount > 0
      || configuration.erosionAmount > 0
      || configuration.edgeRoughness > 0
    // Texture describes physical variation around an authoritative pigment
    // face; it must not turn normal-size text into a low-contrast ghost.
    // Keep a bright center and let the bounded cutout/edge passes carry the
    // material signal seen in the supplied chalk references.
    baseOpacity = hasSurfaceVariation
      ? max(
        0.88,
        min(0.96, 0.96 - configuration.erosionAmount * 0.08
          - configuration.grainAmount * 0.04)
      )
      : 1

    // The physical texture scale is deliberately independent of the target
    // height. A 1pt SVG stroke must remain a 1pt stroke; only the material
    // coverage changes. Larger source samples are used for coarse styles so
    // their structure does not become a repeating micro-hatch. The public
    // grainScale control changes the physical feature size monotonically.
    func scaledPointSize(_ base: Double) -> Double {
      let normalizedScale = min(2.5, max(0.5, configuration.grainScale / 3.5))
      return min(256, max(32, (base * normalizedScale).rounded()))
    }
    switch configuration.textureStyle {
    case .fineGrain:
      texturePointSize = scaledPointSize(64)
      textureOpacity = hasSurfaceVariation
        ? 0.42 + configuration.grainAmount * 0.48
        : 0
      erosionOpacity = min(
        0.68,
        configuration.erosionAmount * 0.65 + configuration.grainAmount * 0.025
      )
    case .photographic:
      texturePointSize = scaledPointSize(96)
      textureOpacity = hasSurfaceVariation
        ? 0.38 + configuration.grainAmount * 0.52
        : 0
      erosionOpacity = min(
        0.72,
        configuration.erosionAmount * 0.72 + configuration.grainAmount * 0.035
      )
    case .referenceSampled:
      texturePointSize = scaledPointSize(84)
      textureOpacity = hasSurfaceVariation
        ? 0.40 + configuration.grainAmount * 0.50
        : 0
      erosionOpacity = min(
        0.76,
        configuration.erosionAmount * 0.78 + configuration.grainAmount * 0.045
      )
    }
    grainCutoutOpacity = hasSurfaceVariation
      ? min(0.24, textureOpacity * 0.28)
      : 0
    grainPigmentOpacity = hasSurfaceVariation
      ? min(0.16, textureOpacity * 0.18)
      : 0
    let edgeDustOpacity = configuration.edgeRoughness * 0.26
    let edgeDustRadius = configuration.edgeRoughness > 0
      ? min(2.25, 0.35 + configuration.edgeRoughness * 1.90)
      : 0
    let depositPhase = edgeDustRadius > 0
      ? Self.phase(seed: configuration.seed, tileSize: edgeDustRadius, pass: .edgeDust)
      : (x: 0, y: 0)
    let texturePhase = edgeDustRadius > 0
      ? Self.phase(seed: configuration.seed, tileSize: texturePointSize, pass: .edgeDust)
      : (x: 0, y: 0)
    edgeDustRecipe = WritingChalkEdgeDustRecipe(
      phaseX: depositPhase.x,
      phaseY: depositPhase.y,
      radius: edgeDustRadius,
      firstOffsetX: depositPhase.x + edgeDustRadius * 0.50,
      firstOffsetY: depositPhase.y - edgeDustRadius * 0.50,
      secondOffsetX: depositPhase.x - edgeDustRadius * 0.50,
      secondOffsetY: depositPhase.y + edgeDustRadius * 0.50,
      opacity: edgeDustOpacity,
      firstDepositScale: 0.32,
      secondDepositScale: 0.24,
      usesTextureMask: edgeDustRadius > 0,
      texturePhaseX: texturePhase.x,
      texturePhaseY: texturePhase.y,
      textureOpacity: edgeDustRadius > 0 ? 1 : 0
    )
    paintOutset = min(
      Self.maximumPaintOutset,
      max(0.5, 0.5 + edgeDustRadius)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case configuration, textureStyle, texturePointSize, textureOpacity, erosionOpacity
    case edgeDustRecipe, paintOutset, baseOpacity, grainCutoutOpacity, grainPigmentOpacity
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let configuration = try values.decode(WritingChalkConfiguration.self, forKey: .configuration)
    let storedTextureStyle = try values.decode(WritingChalkTextureStyle.self, forKey: .textureStyle)
    let storedTexturePointSize = try values.decode(Double.self, forKey: .texturePointSize)
    let storedTextureOpacity = try values.decode(Double.self, forKey: .textureOpacity)
    let storedErosionOpacity = try values.decode(Double.self, forKey: .erosionOpacity)
    let storedEdgeDustRecipe = try values.decode(
      WritingChalkEdgeDustRecipe.self, forKey: .edgeDustRecipe)
    let storedPaintOutset = try values.decode(Double.self, forKey: .paintOutset)
    let storedBaseOpacity = try values.decode(Double.self, forKey: .baseOpacity)
    let storedGrainCutoutOpacity = try values.decode(Double.self, forKey: .grainCutoutOpacity)
    let storedGrainPigmentOpacity = try values.decode(Double.self, forKey: .grainPigmentOpacity)

    let expected = Self(configuration: configuration)
    guard storedTextureStyle == expected.textureStyle,
      storedTexturePointSize == expected.texturePointSize,
      storedTextureOpacity == expected.textureOpacity,
      storedErosionOpacity == expected.erosionOpacity,
      storedEdgeDustRecipe == expected.edgeDustRecipe,
      storedPaintOutset == expected.paintOutset,
      storedBaseOpacity == expected.baseOpacity,
      storedGrainCutoutOpacity == expected.grainCutoutOpacity,
      storedGrainPigmentOpacity == expected.grainPigmentOpacity
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .configuration, in: values,
        debugDescription: "chalk surface derived state does not match its configuration"
      )
    }
    self = expected
  }

  /// Stable phase salt for a specific surface pass.  The phase is part of the
  /// document-space material identity, so scrolling and adapter choice cannot
  /// make the grain swim.
  public func phaseSalt(for pass: WritingChalkSurfacePass) -> UInt64 {
    Self.phaseSalt(for: pass)
  }

  private static func phaseSalt(for pass: WritingChalkSurfacePass) -> UInt64 {
    switch pass {
    case .face: return 0x4348_414C_4B5F_4641
    case .erosion: return 0x4348_414C_4B5F_4552
    case .edgeDust: return 0x4348_414C_4B5F_4544
    }
  }

  public func phase(tileSize: Double, pass: WritingChalkSurfacePass) -> (x: Double, y: Double) {
    Self.phase(seed: configuration.seed, tileSize: tileSize, pass: pass)
  }

  private static func phase(
    seed: UInt64,
    tileSize: Double,
    pass: WritingChalkSurfacePass
  ) -> (x: Double, y: Double) {
    guard tileSize.isFinite, tileSize > 0 else { return (0, 0) }
    var state = seed ^ phaseSalt(for: pass)
    func nextUnit(_ state: inout UInt64) -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var value = state
      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
      value ^= value >> 31
      return Double(value >> 11) / Double(UInt64.max >> 11)
    }
    return (nextUnit(&state) * tileSize, nextUnit(&state) * tileSize)
  }
}

/// Seed-derived edge-dust recipe. This is deliberately renderer-neutral:
/// offsets are expressed in source points and texture participation is an
/// explicit policy rather than an adapter-specific heuristic.
public struct WritingChalkEdgeDustRecipe: Codable, Equatable, Hashable, Sendable {
  public let phaseX: Double
  public let phaseY: Double
  public let radius: Double
  public let firstOffsetX: Double
  public let firstOffsetY: Double
  public let secondOffsetX: Double
  public let secondOffsetY: Double
  public let opacity: Double
  public let firstDepositScale: Double
  public let secondDepositScale: Double
  public let usesTextureMask: Bool
  public let texturePhaseX: Double
  public let texturePhaseY: Double
  public let textureOpacity: Double

  /// Final deposit opacities are derived from the canonical recipe inputs.
  /// Keeping them computed prevents Codable from persisting redundant state
  /// that could disagree with `opacity` or either deposit scale.
  public var firstDepositOpacity: Double {
    opacity * firstDepositScale
  }

  public var secondDepositOpacity: Double {
    opacity * secondDepositScale
  }

  public var isEnabled: Bool {
    radius > 0 && opacity > 0
  }

  fileprivate init(
    phaseX: Double,
    phaseY: Double,
    radius: Double,
    firstOffsetX: Double,
    firstOffsetY: Double,
    secondOffsetX: Double,
    secondOffsetY: Double,
    opacity: Double,
    firstDepositScale: Double,
    secondDepositScale: Double,
    usesTextureMask: Bool,
    texturePhaseX: Double,
    texturePhaseY: Double,
    textureOpacity: Double
  ) {
    self.phaseX = phaseX
    self.phaseY = phaseY
    self.radius = radius
    self.firstOffsetX = firstOffsetX
    self.firstOffsetY = firstOffsetY
    self.secondOffsetX = secondOffsetX
    self.secondOffsetY = secondOffsetY
    self.opacity = opacity
    self.firstDepositScale = firstDepositScale
    self.secondDepositScale = secondDepositScale
    self.usesTextureMask = usesTextureMask
    self.texturePhaseX = texturePhaseX
    self.texturePhaseY = texturePhaseY
    self.textureOpacity = textureOpacity
  }

  private enum CodingKeys: String, CodingKey {
    case phaseX, phaseY, radius, firstOffsetX, firstOffsetY, secondOffsetX, secondOffsetY
    case opacity, firstDepositScale, secondDepositScale, usesTextureMask
    case texturePhaseX, texturePhaseY, textureOpacity
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let phaseX = try values.decode(Double.self, forKey: .phaseX)
    let phaseY = try values.decode(Double.self, forKey: .phaseY)
    let radius = try values.decode(Double.self, forKey: .radius)
    let firstOffsetX = try values.decode(Double.self, forKey: .firstOffsetX)
    let firstOffsetY = try values.decode(Double.self, forKey: .firstOffsetY)
    let secondOffsetX = try values.decode(Double.self, forKey: .secondOffsetX)
    let secondOffsetY = try values.decode(Double.self, forKey: .secondOffsetY)
    let opacity = try values.decode(Double.self, forKey: .opacity)
    let firstDepositScale = try values.decode(Double.self, forKey: .firstDepositScale)
    let secondDepositScale = try values.decode(Double.self, forKey: .secondDepositScale)
    let usesTextureMask = try values.decode(Bool.self, forKey: .usesTextureMask)
    let texturePhaseX = try values.decode(Double.self, forKey: .texturePhaseX)
    let texturePhaseY = try values.decode(Double.self, forKey: .texturePhaseY)
    let textureOpacity = try values.decode(Double.self, forKey: .textureOpacity)
    let finite = [
      phaseX, phaseY, radius, firstOffsetX, firstOffsetY, secondOffsetX, secondOffsetY,
      opacity, firstDepositScale, secondDepositScale, texturePhaseX, texturePhaseY, textureOpacity,
    ]
    .allSatisfy(\.isFinite)
    guard finite, (0...2.25).contains(radius), (0...1).contains(opacity),
      (0...1).contains(firstDepositScale), (0...1).contains(secondDepositScale),
      (0...1).contains(textureOpacity), usesTextureMask == (radius > 0)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .radius, in: values,
        debugDescription: "invalid chalk edge-dust recipe"
      )
    }
    self.init(
      phaseX: phaseX, phaseY: phaseY, radius: radius,
      firstOffsetX: firstOffsetX, firstOffsetY: firstOffsetY,
      secondOffsetX: secondOffsetX, secondOffsetY: secondOffsetY,
      opacity: opacity, firstDepositScale: firstDepositScale,
      secondDepositScale: secondDepositScale, usesTextureMask: usesTextureMask,
      texturePhaseX: texturePhaseX, texturePhaseY: texturePhaseY, textureOpacity: textureOpacity
    )
  }
}

/// The small set of passes supported by the canonical chalk surface recipe.
public enum WritingChalkSurfacePass: String, Codable, CaseIterable, Hashable, Sendable {
  case face
  case erosion
  case edgeDust
}

/// Resource metadata owned by `LiveTextEffects`.
///
/// The target intentionally exposes bytes, not `Image`/`CGImage`.  Platform
/// adapters decode the same bytes into their native drawing image, keeping the
/// material target free of UI framework types.
public enum WritingChalkTextureResource {
  public static let pixelDimension = 256

  public static func name(for style: WritingChalkTextureStyle) -> String {
    switch style {
    case .fineGrain: return "chalk-grain-v1"
    case .photographic: return "chalk-photo-cc0-v1"
    case .referenceSampled: return "chalk-reference-user-v1"
    }
  }

  public static func data(for style: WritingChalkTextureStyle) throws -> Data {
    let resourceName = name(for: style)
    guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png") else {
      throw WritingMaterialError.missingResource(resourceName)
    }
    do {
      return try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw WritingMaterialError.unreadableResource(resourceName)
    }
  }
}
