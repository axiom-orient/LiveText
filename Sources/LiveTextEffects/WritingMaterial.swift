import Foundation
import LiveTextLayout

/// The renderer-neutral material selected for ordinary text and SVG paths.
///
/// The enum deliberately does not contain any SwiftUI/Core Graphics values.
/// Both drawing adapters consume the same numeric plan and only translate it
/// to their platform drawing API at frame time.
public enum WritingMaterial: Codable, Equatable, Hashable, Sendable {
  case chalk(WritingChalkConfiguration)
  case brush(WritingBrushConfiguration)
  case pen(WritingPenConfiguration)
  case ink(WritingInkConfiguration)
  case marker(WritingMarkerConfiguration)
  case knockout(WritingKnockoutConfiguration)

  public var kind: WritingMaterialKind {
    switch self {
    case .chalk: return .chalk
    case .brush: return .brush
    case .pen: return .pen
    case .ink: return .ink
    case .marker: return .marker
    case .knockout: return .knockout
    }
  }

  public var seed: UInt64 {
    switch self {
    case .chalk(let configuration):
      let textureSalt: UInt64
      switch configuration.textureStyle {
      case .fineGrain: textureSalt = 0x4649_4E45
      case .photographic: textureSalt = 0x5048_4F54
      case .referenceSampled: textureSalt = 0x5245_4645
      }
      let topologySalt: UInt64
      switch configuration.style {
      case .fineLine: topologySalt = 0x4649_4E45_4C494E45
      case .dryBrush: topologySalt = 0x4452_5942_52555348
      case .powderFill: topologySalt = 0x504F_5744_45524649
      case .diagonalHatch: topologySalt = 0x4449_4147_48415443
      case .crossHatch: topologySalt = 0x4352_4F53_53484154
      case .smudged: topologySalt = 0x534D_5544_47454400
      }
      return configuration.seed ^ textureSalt ^ topologySalt
    case .brush(let configuration): return configuration.seed
    case .pen(let configuration): return configuration.seed
    case .ink(let configuration): return configuration.seed
    case .marker(let configuration): return configuration.seed
    case .knockout(let configuration): return configuration.seed
    }
  }

  public var coverage: Double {
    switch self {
    case .chalk(let configuration):
      return max(
        configuration.grainAmount,
        max(configuration.erosionAmount, configuration.edgeRoughness * 0.65)
      )
    case .brush(let configuration): return configuration.coverage
    case .pen(let configuration): return configuration.coverage
    case .ink(let configuration): return configuration.coverage
    case .marker(let configuration): return configuration.coverage
    case .knockout: return 1
    }
  }
}

/// The single material selection accepted by a renderer. Keeping colored
/// pencil and all writing materials in one enum makes it impossible for a
/// caller to provide two competing material payloads to the same render pass.
public enum InlineRendererMaterial: Codable, Equatable, Hashable, Sendable {
  case none
  case coloredPencil(ColoredPencilConfiguration)
  case chalk(WritingChalkConfiguration)
  case brush(WritingBrushConfiguration)
  case pen(WritingPenConfiguration)
  case ink(WritingInkConfiguration)
  case marker(WritingMarkerConfiguration)
  case knockout(WritingKnockoutConfiguration)

  public var coloredPencilConfiguration: ColoredPencilConfiguration? {
    guard case .coloredPencil(let configuration) = self else { return nil }
    return configuration
  }

  public var writingMaterial: WritingMaterial? {
    switch self {
    case .chalk(let configuration): return .chalk(configuration)
    case .brush(let configuration): return .brush(configuration)
    case .pen(let configuration): return .pen(configuration)
    case .ink(let configuration): return .ink(configuration)
    case .marker(let configuration): return .marker(configuration)
    case .knockout(let configuration): return .knockout(configuration)
    case .none, .coloredPencil: return nil
    }
  }
}

public enum WritingMaterialKind: String, Codable, Equatable, Hashable, Sendable {
  case chalk
  case brush
  case pen
  case ink
  case marker
  case knockout
}

/// A renderer-neutral chalk material configuration.
///
/// `LiveTextEffects` cannot depend on the SwiftUI-facing
/// `ChalkLineEffects` target without pulling its view compositor into the
/// renderer core. This value carries the same validated numeric contract and
/// texture selection, while the SwiftUI/Canvas adapters consume only the
/// deterministic particle plan produced from it.
/// The single chalk material topology used by both LiveText renderers and standalone chalk effects.
///
/// Topology changes how pigment is deposited, but never changes source layout, text shaping,
/// reveal identity, hit geometry, or accessibility.
public enum WritingChalkStyle: String, Codable, CaseIterable, Hashable, Sendable {
  case fineLine
  case dryBrush
  case powderFill
  case diagonalHatch
  case crossHatch
  case smudged
}

public enum WritingChalkTextureStyle: String, Codable, CaseIterable, Hashable, Sendable {
  case fineGrain
  case photographic
  case referenceSampled
}

public struct WritingChalkConfiguration: Codable, Equatable, Hashable, Sendable {
  public static let maximumGrainScale = 64.0

  public let seed: UInt64
  public let grainAmount: Double
  public let erosionAmount: Double
  public let grainScale: Double
  public let edgeRoughness: Double
  /// Physical pigment topology. This is the chalk style authority.
  public let style: WritingChalkStyle
  /// Substrate microtexture family used by the single chalk renderer.
  /// It affects pigment breakup only and never changes layout, reveal identity, or renderer selection.
  public let textureStyle: WritingChalkTextureStyle

  public init(
    seed: UInt64 = 0xC4_4841_4C_4B,
    grainAmount: Double = 0.58,
    erosionAmount: Double = 0.16,
    grainScale: Double = 3.5,
    edgeRoughness: Double = 0.14,
    textureStyle: WritingChalkTextureStyle = .fineGrain,
    style: WritingChalkStyle = .dryBrush
  ) throws {
    for (field, value) in [
      ("grainAmount", grainAmount),
      ("erosionAmount", erosionAmount),
      ("grainScale", grainScale),
      ("edgeRoughness", edgeRoughness),
    ] {
      guard value.isFinite else {
        throw WritingMaterialError.invalidConfiguration(field: field, value: value)
      }
    }
    guard (0...1).contains(grainAmount) else {
      throw WritingMaterialError.invalidConfiguration(field: "grainAmount", value: grainAmount)
    }
    guard (0...1).contains(erosionAmount) else {
      throw WritingMaterialError.invalidConfiguration(
        field: "erosionAmount", value: erosionAmount)
    }
    guard grainScale > 0, grainScale <= Self.maximumGrainScale else {
      throw WritingMaterialError.invalidConfiguration(field: "grainScale", value: grainScale)
    }
    guard (0...1).contains(edgeRoughness) else {
      throw WritingMaterialError.invalidConfiguration(
        field: "edgeRoughness", value: edgeRoughness)
    }
    self.seed = seed
    self.grainAmount = grainAmount
    self.erosionAmount = erosionAmount
    self.grainScale = grainScale
    self.edgeRoughness = edgeRoughness
    self.style = style
    self.textureStyle = textureStyle
  }

  private enum CodingKeys: String, CodingKey {
    case seed, grainAmount, erosionAmount, grainScale, edgeRoughness, textureStyle, style
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      grainAmount: values.decode(Double.self, forKey: .grainAmount),
      erosionAmount: values.decode(Double.self, forKey: .erosionAmount),
      grainScale: values.decode(Double.self, forKey: .grainScale),
      edgeRoughness: values.decode(Double.self, forKey: .edgeRoughness),
      textureStyle: values.decode(WritingChalkTextureStyle.self, forKey: .textureStyle),
      style: try values.decodeIfPresent(WritingChalkStyle.self, forKey: .style) ?? .fineLine
    )
  }

  public static let soft = WritingChalkConfiguration(
    validatedSeed: 0xC4_4841_4C_4B,
    grainAmount: 0.28,
    erosionAmount: 0.03,
    grainScale: 2.4,
    edgeRoughness: 0.02,
    textureStyle: .fineGrain
  )

  public static let classic = WritingChalkConfiguration(
    validatedSeed: 0xC4_4841_4C_4B,
    grainAmount: 0.58,
    erosionAmount: 0.16,
    grainScale: 3.5,
    edgeRoughness: 0.14,
    textureStyle: .fineGrain
  )

  /// High-contrast chalk for product text on a dark board.
  ///
  /// The reference-sampled grain remains visible inside broad strokes, while
  /// bounded erosion keeps small Hangul and time labels readable. Decorative
  /// outlines can still opt into `dusty` or `rough`; readable text does not
  /// need to trade away its center pigment to look physical.
  public static let legible = WritingChalkConfiguration(
    validatedSeed: 0x4C_4547_4942_4C_45,
    grainAmount: 0.42,
    erosionAmount: 0.06,
    grainScale: 4.2,
    edgeRoughness: 0.18,
    textureStyle: .referenceSampled
  )

  public static let dusty = WritingChalkConfiguration(
    validatedSeed: 0xC4_4841_4C_4B,
    grainAmount: 0.82,
    erosionAmount: 0.38,
    grainScale: 4.8,
    edgeRoughness: 0.48,
    textureStyle: .photographic
  )

  public static let rough = WritingChalkConfiguration(
    validatedSeed: 0xC4_4841_4C_4B,
    grainAmount: 1,
    erosionAmount: 0.82,
    grainScale: 6.4,
    edgeRoughness: 1,
    textureStyle: .referenceSampled
  )

  public static let `default` = classic.withStyle(.dryBrush)

  package init(
    validatedSeed seed: UInt64,
    grainAmount: Double,
    erosionAmount: Double,
    grainScale: Double,
    edgeRoughness: Double,
    textureStyle: WritingChalkTextureStyle,
    style: WritingChalkStyle = .fineLine
  ) {
    self.seed = seed
    self.grainAmount = grainAmount
    self.erosionAmount = erosionAmount
    self.grainScale = grainScale
    self.edgeRoughness = edgeRoughness
    self.style = style
    self.textureStyle = textureStyle
  }

  /// Returns the same validated strength/substrate configuration with another pigment topology.
  /// This is a pure value transformation; no rendering or layout work occurs here.
  public func withStyle(_ style: WritingChalkStyle) -> WritingChalkConfiguration {
    WritingChalkConfiguration(
      validatedSeed: seed,
      grainAmount: grainAmount,
      erosionAmount: erosionAmount,
      grainScale: grainScale,
      edgeRoughness: edgeRoughness,
      textureStyle: textureStyle,
      style: style
    )
  }

  /// Material-showcase presets. They all execute through the same chalk engine.
  public static let fineLine = WritingChalkConfiguration(
    validatedSeed: 0xC4_4841_4C_4B,
    grainAmount: 0.76, erosionAmount: 0.30, grainScale: 3.0, edgeRoughness: 0.48,
    textureStyle: .fineGrain, style: .fineLine
  )
  public static let dryBrush = rough.withStyle(.dryBrush)
  private static let dramaticPowderStrength = WritingChalkConfiguration(
    validatedSeed: 0xC4_4841_4C_4B,
    grainAmount: 0.82, erosionAmount: 0.38, grainScale: 4.8, edgeRoughness: 0.62,
    textureStyle: .photographic, style: .powderFill
  )
  public static let powderFill = dramaticPowderStrength
  public static let diagonalHatch = dramaticPowderStrength.withStyle(.diagonalHatch)
  public static let crossHatch = dramaticPowderStrength.withStyle(.crossHatch)
  public static let smudged = dramaticPowderStrength.withStyle(.smudged)
}

/// Errors raised by the renderer-neutral material configurations.
public enum WritingMaterialError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(field: String, value: Double)
  case invalidGeometry
  case missingResource(String)
  case unreadableResource(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let field, let value):
      return "Invalid writing material configuration '\(field)': \(value)."
    case .invalidGeometry:
      return "Writing material geometry must contain finite, non-negative dimensions."
    case .missingResource(let name):
      return "Required writing material resource is missing: \(name).png."
    case .unreadableResource(let name):
      return "Required writing material resource could not be read: \(name).png."
    }
  }
}

public struct WritingBrushConfiguration: Codable, Equatable, Hashable, Sendable {
  public let seed: UInt64
  public let coverage: Double
  public let streakScale: Double

  public init(
    seed: UInt64 = 0x42_5255_5348,
    coverage: Double = 0.82,
    streakScale: Double = 3.5
  ) throws {
    guard coverage.isFinite, (0...1).contains(coverage) else {
      throw WritingMaterialError.invalidConfiguration(field: "coverage", value: coverage)
    }
    guard streakScale.isFinite, streakScale > 0, streakScale <= 64 else {
      throw WritingMaterialError.invalidConfiguration(field: "streakScale", value: streakScale)
    }
    self.seed = seed
    self.coverage = coverage
    self.streakScale = streakScale
  }

  private enum CodingKeys: String, CodingKey { case seed, coverage, streakScale }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      coverage: values.decode(Double.self, forKey: .coverage),
      streakScale: values.decode(Double.self, forKey: .streakScale)
    )
  }

  public static let `default` = WritingBrushConfiguration(
    validatedSeed: 0x42_5255_5348, coverage: 0.82, streakScale: 3.5)

  package init(validatedSeed seed: UInt64, coverage: Double, streakScale: Double) {
    self.seed = seed
    self.coverage = coverage
    self.streakScale = streakScale
  }
}

public struct WritingPenConfiguration: Codable, Equatable, Hashable, Sendable {
  public let seed: UInt64
  public let coverage: Double
  public let dotScale: Double

  public init(
    seed: UInt64 = 0x5045_4E2D_5631,
    coverage: Double = 0.88,
    dotScale: Double = 1.4
  ) throws {
    guard coverage.isFinite, (0...1).contains(coverage) else {
      throw WritingMaterialError.invalidConfiguration(field: "coverage", value: coverage)
    }
    guard dotScale.isFinite, dotScale > 0, dotScale <= 64 else {
      throw WritingMaterialError.invalidConfiguration(field: "dotScale", value: dotScale)
    }
    self.seed = seed
    self.coverage = coverage
    self.dotScale = dotScale
  }

  private enum CodingKeys: String, CodingKey { case seed, coverage, dotScale }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      coverage: values.decode(Double.self, forKey: .coverage),
      dotScale: values.decode(Double.self, forKey: .dotScale)
    )
  }

  public static let `default` = WritingPenConfiguration(
    validatedSeed: 0x5045_4E2D_5631, coverage: 0.88, dotScale: 1.4)

  package init(validatedSeed seed: UInt64, coverage: Double, dotScale: Double) {
    self.seed = seed
    self.coverage = coverage
    self.dotScale = dotScale
  }
}

public struct WritingInkConfiguration: Codable, Equatable, Hashable, Sendable {
  public let seed: UInt64
  public let coverage: Double
  public let bleed: Double
  public let pooling: Double

  public init(
    seed: UInt64 = 0x494E_4B2D_5631,
    coverage: Double = 0.76,
    bleed: Double = 0.38,
    pooling: Double = 0.26
  ) throws {
    guard coverage.isFinite, (0...1).contains(coverage) else {
      throw WritingMaterialError.invalidConfiguration(field: "coverage", value: coverage)
    }
    guard bleed.isFinite, (0...1).contains(bleed) else {
      throw WritingMaterialError.invalidConfiguration(field: "bleed", value: bleed)
    }
    guard pooling.isFinite, (0...1).contains(pooling) else {
      throw WritingMaterialError.invalidConfiguration(field: "pooling", value: pooling)
    }
    self.seed = seed
    self.coverage = coverage
    self.bleed = bleed
    self.pooling = pooling
  }

  private enum CodingKeys: String, CodingKey { case seed, coverage, bleed, pooling }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      coverage: values.decode(Double.self, forKey: .coverage),
      bleed: values.decode(Double.self, forKey: .bleed),
      pooling: values.decode(Double.self, forKey: .pooling)
    )
  }

  public static let `default` = WritingInkConfiguration(
    validatedSeed: 0x494E_4B2D_5631, coverage: 0.76, bleed: 0.38, pooling: 0.26)

  package init(
    validatedSeed seed: UInt64,
    coverage: Double,
    bleed: Double,
    pooling: Double
  ) {
    self.seed = seed
    self.coverage = coverage
    self.bleed = bleed
    self.pooling = pooling
  }
}

/// A flat, constant-width marker/highlighter material: bold pastel ribbon,
/// squared stops, near-zero edge bleed. The feel is ink sitting on top of
/// the page — no taper, no bristle.
public struct WritingMarkerConfiguration: Codable, Equatable, Hashable, Sendable {
  public let seed: UInt64
  public let coverage: Double
  public let bleed: Double

  public init(
    seed: UInt64 = 0x4D_4152_4B45_52,
    coverage: Double = 0.72,
    bleed: Double = 0.18
  ) throws {
    guard coverage.isFinite, (0...1).contains(coverage) else {
      throw WritingMaterialError.invalidConfiguration(field: "coverage", value: coverage)
    }
    guard bleed.isFinite, (0...1).contains(bleed) else {
      throw WritingMaterialError.invalidConfiguration(field: "bleed", value: bleed)
    }
    self.seed = seed
    self.coverage = coverage
    self.bleed = bleed
  }

  private enum CodingKeys: String, CodingKey { case seed, coverage, bleed }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      coverage: values.decode(Double.self, forKey: .coverage),
      bleed: values.decode(Double.self, forKey: .bleed)
    )
  }

  public static let `default` = WritingMarkerConfiguration(
    validatedSeed: 0x4D_4152_4B45_52, coverage: 0.72, bleed: 0.18)

  package init(validatedSeed seed: UInt64, coverage: Double, bleed: Double) {
    self.seed = seed
    self.coverage = coverage
    self.bleed = bleed
  }
}

/// A stencil stroke that erases the document content beneath it — the
/// punched region shows whatever sits behind the render surface.
public struct WritingKnockoutConfiguration: Codable, Equatable, Hashable, Sendable {
  public let seed: UInt64
  public let edgeSoftness: Double

  public init(
    seed: UInt64 = 0x4B_4E4F_434B,
    edgeSoftness: Double = 0.35
  ) throws {
    guard edgeSoftness.isFinite, (0...1).contains(edgeSoftness) else {
      throw WritingMaterialError.invalidConfiguration(field: "edgeSoftness", value: edgeSoftness)
    }
    self.seed = seed
    self.edgeSoftness = edgeSoftness
  }

  private enum CodingKeys: String, CodingKey { case seed, edgeSoftness }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      edgeSoftness: values.decode(Double.self, forKey: .edgeSoftness)
    )
  }

  public static let `default` = WritingKnockoutConfiguration(
    validatedSeed: 0x4B_4E4F_434B, edgeSoftness: 0.35)

  package init(validatedSeed seed: UInt64, edgeSoftness: Double) {
    self.seed = seed
    self.edgeSoftness = edgeSoftness
  }
}

/// A finite target rectangle in the local coordinate system of one atom.
public struct WritingMaterialRect: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double = 0, y: Double = 0, width: Double, height: Double) throws {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width >= 0, height >= 0
    else {
      throw WritingMaterialError.invalidGeometry
    }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  package init(validatedX x: Double, y: Double, width: Double, height: Double) {
    precondition(
      x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  private enum CodingKeys: String, CodingKey { case x, y, width, height }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }
}

/// The immutable geometry descriptor supplied by a renderer adapter for one
/// material target. The descriptor is intentionally independent of a
/// viewport and of SwiftUI/Core Graphics path values.
public struct WritingMaterialTarget: Codable, Equatable, Hashable, Sendable {
  public let targetID: String
  public let documentOriginX: Double
  public let documentOriginY: Double
  public let destination: WritingMaterialRect

  public init(
    targetID: String,
    documentOriginX: Double,
    documentOriginY: Double,
    destination: WritingMaterialRect
  ) throws {
    guard !targetID.isEmpty,
      documentOriginX.isFinite, documentOriginY.isFinite
    else {
      throw WritingMaterialError.invalidGeometry
    }
    self.targetID = targetID
    self.documentOriginX = documentOriginX
    self.documentOriginY = documentOriginY
    self.destination = destination
  }

  package init(
    validatedTargetID targetID: String,
    documentOriginX: Double,
    documentOriginY: Double,
    destination: WritingMaterialRect
  ) {
    precondition(!targetID.isEmpty && documentOriginX.isFinite && documentOriginY.isFinite)
    self.targetID = targetID
    self.documentOriginX = documentOriginX
    self.documentOriginY = documentOriginY
    self.destination = destination
  }

  private enum CodingKeys: String, CodingKey {
    case targetID, documentOriginX, documentOriginY, destination
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      targetID: values.decode(String.self, forKey: .targetID),
      documentOriginX: values.decode(Double.self, forKey: .documentOriginX),
      documentOriginY: values.decode(Double.self, forKey: .documentOriginY),
      destination: values.decode(WritingMaterialRect.self, forKey: .destination)
    )
  }
}

/// Immutable, document-ordered material targets prepared once with a render
/// content object. The signature includes every target field and its order;
/// it lets the bounded cache distinguish two uses of the same material with
/// different geometry without retaining a second copy of the target array.
public struct WritingMaterialTargetSet: Codable, Equatable, Hashable, Sendable {
  public let targets: [WritingMaterialTarget]
  public let signature: UInt64

  public init(targets: [WritingMaterialTarget]) {
    self.targets = targets
    var value = 0x54_4152_474554_5345 ^ UInt64(targets.count)
    for (index, target) in targets.enumerated() {
      value = Self.mix(value, UInt64(index))
      value = Self.mix(value, target.targetID)
      value = Self.mix(value, target.documentOriginX.bitPattern)
      value = Self.mix(value, target.documentOriginY.bitPattern)
      value = Self.mix(value, target.destination.x.bitPattern)
      value = Self.mix(value, target.destination.y.bitPattern)
      value = Self.mix(value, target.destination.width.bitPattern)
      value = Self.mix(value, target.destination.height.bitPattern)
    }
    self.signature = value
  }

  private enum CodingKeys: String, CodingKey { case targets, signature }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let targets = try values.decode([WritingMaterialTarget].self, forKey: .targets)
    let storedSignature = try values.decode(UInt64.self, forKey: .signature)
    let expected = Self(targets: targets)
    guard storedSignature == expected.signature else {
      throw DecodingError.dataCorruptedError(
        forKey: .signature,
        in: values,
        debugDescription: "material target signature does not match targets"
      )
    }
    self.targets = expected.targets
    self.signature = expected.signature
  }

  private static func mix(_ value: UInt64, _ input: UInt64) -> UInt64 {
    var result = value ^ input &* 0x9E37_79B9_7F4A_7C15
    result ^= result >> 30
    result &*= 0xBF58_476D_1CE4_E5B9
    result ^= result >> 27
    result &*= 0x94D0_49BB_1331_11EB
    return result ^ (result >> 31)
  }

  private static func mix(_ value: UInt64, _ string: String) -> UInt64 {
    var result = value
    for byte in string.utf8 {
      result ^= UInt64(byte)
      result &*= 0x100_0000_01B3
    }
    return result
  }
}

/// One bounded deposition mark. Coordinates are target-local points, not
/// viewport coordinates. The renderer decides whether the mark is stroked or
/// filled and clips it to the ordinary outline/path when appropriate.
public struct WritingMaterialMark: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let dx: Double
  public let dy: Double
  public let length: Double
  public let width: Double
  public let secondaryX: Double
  public let secondaryY: Double
  public let secondarySize: Double
  public let opacity: Double
  /// Material marks with this flag remove pigment from the ordinary surface.
  /// Brush uses it for occasional bristle skips. Pen and ink marks always
  /// deposit pigment; chalk has no generic material marks.
  public let isErosion: Bool

  fileprivate init(
    x: Double,
    y: Double,
    dx: Double,
    dy: Double,
    length: Double,
    width: Double,
    secondaryX: Double,
    secondaryY: Double,
    secondarySize: Double,
    opacity: Double,
    isErosion: Bool = false
  ) {
    self.x = x
    self.y = y
    self.dx = dx
    self.dy = dy
    self.length = length
    self.width = width
    self.secondaryX = secondaryX
    self.secondaryY = secondaryY
    self.secondarySize = secondarySize
    self.opacity = opacity
    self.isErosion = isErosion
  }

  private enum CodingKeys: String, CodingKey {
    case x, y, dx, dy, length, width, secondaryX, secondaryY, secondarySize, opacity, isErosion
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let x = try values.decode(Double.self, forKey: .x)
    let y = try values.decode(Double.self, forKey: .y)
    let dx = try values.decode(Double.self, forKey: .dx)
    let dy = try values.decode(Double.self, forKey: .dy)
    let length = try values.decode(Double.self, forKey: .length)
    let width = try values.decode(Double.self, forKey: .width)
    let secondaryX = try values.decode(Double.self, forKey: .secondaryX)
    let secondaryY = try values.decode(Double.self, forKey: .secondaryY)
    let secondarySize = try values.decode(Double.self, forKey: .secondarySize)
    let opacity = try values.decode(Double.self, forKey: .opacity)
    let isErosion = try values.decode(Bool.self, forKey: .isErosion)
    guard
      [x, y, dx, dy, length, width, secondaryX, secondaryY, secondarySize, opacity]
        .allSatisfy(\.isFinite),
      length >= 0, width >= 0, secondarySize >= 0, (0...1).contains(opacity)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .opacity, in: values, debugDescription: "invalid writing material mark geometry")
    }
    self.init(
      x: x, y: y, dx: dx, dy: dy, length: length, width: width,
      secondaryX: secondaryX, secondaryY: secondaryY, secondarySize: secondarySize,
      opacity: opacity, isErosion: isErosion)
  }
}

/// Shared deterministic geometry consumed by both the SwiftUI and Canvas
/// adapters. It is independent of a viewport and includes the target's
/// document origin in its seed, so scrolling cannot move the material.
public struct WritingMaterialPlan: Codable, Equatable, Hashable, Sendable {
  public static let maximumMarksPerTarget = 256
  public static let maximumMarks = 16_384

  public let kind: WritingMaterialKind
  public let targetID: String
  public let documentOriginX: Double
  public let documentOriginY: Double
  public let destination: WritingMaterialRect
  public let marks: [WritingMaterialMark]
  /// Opacity of the ordinary face before material marks are deposited.
  /// A material must leave enough headroom for its deposition pattern to be
  /// visible. A zero-coverage configuration remains an ordinary opaque face.
  public let baseOpacity: Double

  public init(
    material: WritingMaterial,
    targetID: String,
    documentOriginX: Double,
    documentOriginY: Double,
    destination: WritingMaterialRect,
    markCount: Int? = nil
  ) {
    precondition(!targetID.isEmpty, "writing material target identity must not be empty")
    precondition(documentOriginX.isFinite && documentOriginY.isFinite)
    self.kind = material.kind
    self.targetID = targetID
    self.documentOriginX = documentOriginX
    self.documentOriginY = documentOriginY
    self.destination = destination
    switch material {
    case .chalk(let configuration):
      if configuration.grainAmount == 0,
        configuration.erosionAmount == 0,
        configuration.edgeRoughness == 0
      {
        self.baseOpacity = 1
      } else {
        self.baseOpacity = max(
          0.48,
          min(
            0.92,
            0.84 - configuration.erosionAmount * 0.20
              - configuration.grainAmount * 0.04)
        )
      }
    case .brush(let configuration):
      self.baseOpacity =
        configuration.coverage == 0
        ? 1
        : max(0.52, min(0.74, 0.62 - (1 - configuration.coverage) * 0.08))
    case .pen(let configuration):
      self.baseOpacity =
        configuration.coverage == 0
        ? 1
        : max(0.70, min(0.88, 0.80 - (1 - configuration.coverage) * 0.04))
    case .ink(let configuration):
      self.baseOpacity =
        configuration.coverage == 0
        ? 1
        : max(0.42, min(0.64, 0.54 - (1 - configuration.coverage) * 0.06))
    case .marker(let configuration):
      // Marker reads as flat pigment film: opacity tracks coverage, with
      // headroom for the light bleed flecks.
      self.baseOpacity =
        configuration.coverage == 0
        ? 1
        : max(0.45, min(0.85, 0.55 + configuration.coverage * 0.3))
    case .knockout:
      self.baseOpacity = 1
    }

    let requested =
      markCount
      ?? Self.requestedMarkCount(
        material: material, destination: destination)
    let count = max(0, min(Self.maximumMarksPerTarget, requested))
    var generator = WritingMaterialRandom(
      seed: Self.seed(
        material: material,
        targetID: targetID,
        originX: documentOriginX,
        originY: documentOriginY,
        destination: destination
      ))
    var marks: [WritingMaterialMark] = []
    marks.reserveCapacity(count)
    let minimumDimension = max(1, min(destination.width, destination.height))
    // A stratified surface sample keeps material marks present in thin glyphs
    // and narrow SVG ribbons. The previous uniform rectangle sampler could
    // spend nearly every mark outside the eventual outline mask.
    let aspectRatio: Double
    if destination.width > 0, destination.height > 0 {
      aspectRatio = min(64, max(1.0 / 64.0, destination.width / destination.height))
    } else {
      aspectRatio = 1
    }
    let columns = max(
      1,
      min(count, Int(ceil(sqrt(Double(max(1, count)) * aspectRatio))))
    )
    let rows = max(1, Int(ceil(Double(max(1, count)) / Double(columns))))
    for index in 0..<count {
      let column = index % columns
      let row = index / columns
      let xJitter = (generator.nextUnit() - 0.5) * 0.62 / Double(columns)
      let yJitter = (generator.nextUnit() - 0.5) * 0.62 / Double(rows)
      let xFraction = min(
        0.985,
        max(0.015, (Double(column) + 0.5) / Double(columns) + xJitter)
      )
      let yFraction = min(
        0.985,
        max(0.015, (Double(row) + 0.5) / Double(rows) + yJitter)
      )
      let x = destination.x + xFraction * destination.width
      let y = destination.y + yFraction * destination.height
      let mark: WritingMaterialMark
      switch material {
      case .chalk:
        preconditionFailure("chalk surface does not generate generic marks")
      case .brush(let configuration):
        let skips = generator.nextUnit() < 0.12 + (1 - configuration.coverage) * 0.28
        let pressure = 0.25 + generator.nextUnit() * 0.75
        mark = WritingMaterialMark(
          x: x,
          y: y,
          dx: 0.90 + generator.nextUnit() * 0.22,
          dy: (generator.nextUnit() - 0.5) * 0.32,
          length: max(destination.width, minimumDimension)
            * (0.34 + generator.nextUnit() * 0.64)
            * min(8, configuration.streakScale) / 3.5,
          width: max(0.72, minimumDimension * (0.040 + pressure * 0.075)),
          secondaryX: generator.nextUnit() - 0.5,
          secondaryY: generator.nextUnit() - 0.5,
          secondarySize: pressure,
          opacity: skips
            ? 0.12 + generator.nextUnit() * 0.24
            : 0.48 + generator.nextUnit() * 0.46,
          isErosion: skips
        )
      case .pen(let configuration):
        // A pen deposits short, hard-edged nib strokes rather than a cloud of
        // unrelated dots. Keeping the strokes below 5pt preserves legibility
        // while making pressure/coverage observable at body-text scale.
        mark = WritingMaterialMark(
          x: x,
          y: y,
          dx: 0.84 + generator.nextUnit() * 0.30,
          dy: (generator.nextUnit() - 0.5) * 0.12,
          length: min(
            6,
            max(1.1, minimumDimension * (0.08 + generator.nextUnit() * 0.18))
          ),
          width: max(0.48, configuration.dotScale * (0.34 + generator.nextUnit() * 0.48)),
          secondaryX: generator.nextUnit() - 0.5,
          secondaryY: generator.nextUnit() - 0.5,
          secondarySize: 0.25 + generator.nextUnit() * 0.55,
          opacity: 0.56 + generator.nextUnit() * 0.40
        )
      case .marker(let configuration):
        // Marker flecks: sparse, light bleed specks along the edge film.
        mark = WritingMaterialMark(
          x: x,
          y: y,
          dx: 0.86 + generator.nextUnit() * 0.28,
          dy: (generator.nextUnit() - 0.5) * 0.16,
          length: max(destination.width, minimumDimension)
            * (0.05 + generator.nextUnit() * 0.10),
          width: max(0.30, minimumDimension * 0.020 * (0.7 + generator.nextUnit() * 0.8)),
          secondaryX: generator.nextUnit() - 0.5,
          secondaryY: generator.nextUnit() - 0.5,
          secondarySize: 0.2 + generator.nextUnit() * 0.4,
          opacity: min(0.5, 0.12 + generator.nextUnit() * 0.25 * configuration.bleed),
          isErosion: true
        )
      case .knockout:
        // No pigment marks: the ribbon itself is the punch.
        mark = WritingMaterialMark(
          x: x, y: y, dx: 1, dy: 0, length: 0, width: 0,
          secondaryX: 0, secondaryY: 0, secondarySize: 0, opacity: 0)
      case .ink(let configuration):
        let bleedScale = 0.78 + configuration.bleed * 0.72
        let poolingScale = 0.82 + configuration.pooling * 0.82
        mark = WritingMaterialMark(
          x: x,
          y: y,
          dx: 0.66 + generator.nextUnit() * 0.68,
          dy: (generator.nextUnit() - 0.5) * 0.68,
          length: max(destination.width, minimumDimension)
            * (0.18 + generator.nextUnit() * 0.48) * bleedScale,
          width: max(
            0.82,
            minimumDimension * 0.075 * (0.82 + generator.nextUnit() * 1.08) * bleedScale
          ),
          secondaryX: generator.nextUnit() - 0.5,
          secondaryY: generator.nextUnit() - 0.5,
          secondarySize: (0.68 + generator.nextUnit() * 1.28) * poolingScale,
          opacity: min(1, 0.48 + generator.nextUnit() * 0.50 * poolingScale)
        )
      }
      marks.append(mark)
    }
    self.marks = marks
  }

  private enum CodingKeys: String, CodingKey {
    case kind, targetID, documentOriginX, documentOriginY, destination, marks, baseOpacity
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try values.decode(WritingMaterialKind.self, forKey: .kind)
    let targetID = try values.decode(String.self, forKey: .targetID)
    let documentOriginX = try values.decode(Double.self, forKey: .documentOriginX)
    let documentOriginY = try values.decode(Double.self, forKey: .documentOriginY)
    let destination = try values.decode(WritingMaterialRect.self, forKey: .destination)
    let marks = try values.decode([WritingMaterialMark].self, forKey: .marks)
    let baseOpacity = try values.decode(Double.self, forKey: .baseOpacity)
    guard !targetID.isEmpty, documentOriginX.isFinite, documentOriginY.isFinite,
      marks.count <= Self.maximumMarksPerTarget,
      baseOpacity.isFinite, (0...1).contains(baseOpacity)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .marks, in: values,
        debugDescription: "invalid writing material plan identity, geometry, or bounded mark state")
    }
    self.kind = kind
    self.targetID = targetID
    self.documentOriginX = documentOriginX
    self.documentOriginY = documentOriginY
    self.destination = destination
    self.marks = marks
    self.baseOpacity = baseOpacity
  }

  public static func requestedMarkCount(
    material: WritingMaterial,
    destination: WritingMaterialRect
  ) -> Int {
    guard destination.width > 0, destination.height > 0 else { return 0 }
    let density: Double
    switch material {
    case .chalk:
      // Chalk texture is sampled by WritingChalkSurfacePlan. Surface marks
      // belong to the old generic ribbon compositor and must not be generated.
      return 0
    case .brush: density = 20
    case .pen: density = 24
    case .ink: density = 22
    case .marker: density = 90
    case .knockout:
      return 0
    }
    let requested = destination.width * destination.height / density * material.coverage
    guard requested.isFinite, requested > 0 else { return 0 }
    return Self.boundedCeiling(
      requested, lowerBound: 12, upperBound: maximumMarksPerTarget)
  }

  private static func boundedCeiling(
    _ value: Double,
    lowerBound: Int,
    upperBound: Int
  ) -> Int {
    guard upperBound >= lowerBound, value.isFinite else { return lowerBound }
    if value >= Double(upperBound) { return upperBound }
    let roundedUp = value.rounded(.up)
    guard roundedUp.isFinite else { return upperBound }
    if roundedUp <= Double(lowerBound) { return lowerBound }
    // `roundedUp < upperBound <= maximumMarksPerTarget`, so this conversion
    // cannot trap even for a very large finite destination rectangle.
    return Int(roundedUp)
  }

  /// Divides one global material budget in document order. This prevents a
  /// long document or a large viewport from allocating unbounded marks while
  /// retaining material on both the beginning and end of the document.
  public static func boundedMarkAllocations(
    requestedCounts: [Int],
    maximumMarks: Int = Self.maximumMarks
  ) -> [Int] {
    let requests = requestedCounts.map { max(0, min(Self.maximumMarksPerTarget, $0)) }
    let budget = max(0, maximumMarks)
    guard !requests.isEmpty, budget > 0 else {
      return Array(repeating: 0, count: requests.count)
    }
    let total = requests.reduce(0, +)
    guard total > budget else { return requests }
    if requests.count > budget {
      var result = Array(repeating: 0, count: requests.count)
      for slot in 0..<budget {
        let position = (Double(slot) + 0.5) * Double(requests.count) / Double(budget)
        let index = min(requests.count - 1, Int(position))
        if requests[index] > 0 { result[index] = 1 }
      }
      return result
    }
    var result = Array(repeating: 0, count: requests.count)
    var remaining = budget
    for index in requests.indices {
      let remainingItems = requests.count - index
      let fairShare = max(1, remaining / remainingItems)
      let allocation = min(requests[index], fairShare)
      result[index] = allocation
      remaining -= allocation
    }
    return result
  }

  private static func seed(
    material: WritingMaterial,
    targetID: String,
    originX: Double,
    originY: Double,
    destination: WritingMaterialRect
  ) -> UInt64 {
    var value = material.seed ^ 0x4D_4154_4552_4941
    value = stableMix(value, targetID)
    value = stableMix(value, originX.bitPattern)
    value = stableMix(value, originY.bitPattern)
    value = stableMix(value, destination.x.bitPattern)
    value = stableMix(value, destination.y.bitPattern)
    value = stableMix(value, destination.width.bitPattern)
    value = stableMix(value, destination.height.bitPattern)
    return value
  }

  private static func stableMix(_ value: UInt64, _ input: UInt64) -> UInt64 {
    var result = value ^ input &* 0x9E37_79B9_7F4A_7C15
    result ^= result >> 30
    result &*= 0xBF58_476D_1CE4_E5B9
    result ^= result >> 27
    result &*= 0x94D0_49BB_1331_11EB
    return result ^ (result >> 31)
  }

  private static func stableMix(_ value: UInt64, _ string: String) -> UInt64 {
    var result = value
    for byte in string.utf8 {
      result ^= UInt64(byte)
      result &*= 0x100_0000_01B3
    }
    return result
  }
}

/// A bounded two-entry material-plan cache shared by both drawing adapters.
/// The caller owns the cache alongside immutable render content, so target
/// geometry cannot leak between documents. Only positive target plans are
/// retained; zero-allocation targets do not occupy an O(document) cache
/// payload. Renderers select visible plans from this immutable sparse store.
public struct WritingMaterialPlanCache {
  public static let capacity = 2

  private struct Entry {
    let material: WritingMaterial
    let targetSignature: UInt64
    let plans: [Int: WritingMaterialPlan]
  }

  private var entries: [Entry] = []
  public private(set) var buildCount = 0

  public init() {}

  public var cachedConfigurationCount: Int { entries.count }

  /// Returns the sparse, immutable plans for one exact material/target-set
  /// pair. The cache owns at most `WritingMaterialPlan.maximumMarks` marks;
  /// entries with zero allocation are omitted entirely.
  public mutating func plans(
    for material: WritingMaterial,
    targetSet: WritingMaterialTargetSet
  ) -> [Int: WritingMaterialPlan] {
    if let index = entries.firstIndex(where: {
      $0.material == material && $0.targetSignature == targetSet.signature
    }) {
      let entry = entries.remove(at: index)
      entries.insert(entry, at: 0)
      return entry.plans
    }

    let requests = targetSet.targets.map {
      WritingMaterialPlan.requestedMarkCount(
        material: material, destination: $0.destination)
    }
    let allocations = WritingMaterialPlan.boundedMarkAllocations(
      requestedCounts: requests,
      maximumMarks: WritingMaterialPlan.maximumMarks
    )
    var plans: [Int: WritingMaterialPlan] = [:]
    plans.reserveCapacity(min(targetSet.targets.count, WritingMaterialPlan.maximumMarks))
    for (index, markCount) in allocations.enumerated() {
      guard markCount > 0, targetSet.targets.indices.contains(index) else { continue }
      let target = targetSet.targets[index]
      plans[index] = WritingMaterialPlan(
        material: material,
        targetID: target.targetID,
        documentOriginX: target.documentOriginX,
        documentOriginY: target.documentOriginY,
        destination: target.destination,
        markCount: markCount
      )
    }
    if entries.count == Self.capacity { entries.removeLast() }
    entries.insert(
      Entry(
        material: material,
        targetSignature: targetSet.signature,
        plans: plans
      ),
      at: 0
    )
    buildCount += 1
    return plans
  }

  public mutating func allocations(
    for material: WritingMaterial,
    targetSet: WritingMaterialTargetSet
  ) -> [Int] {
    let cachedPlans = plans(for: material, targetSet: targetSet)
    var result = Array(repeating: 0, count: targetSet.targets.count)
    for (index, plan) in cachedPlans {
      guard result.indices.contains(index) else { continue }
      result[index] = plan.marks.count
    }
    return result
  }

  /// Convenience for callers without a precomputed target set. Renderer
  /// content should use the target-set overload to avoid recomputing the
  /// signature at every renderer construction.
  public mutating func allocations(
    for material: WritingMaterial,
    targets: [WritingMaterialTarget]
  ) -> [Int] {
    allocations(
      for: material,
      targetSet: WritingMaterialTargetSet(targets: targets)
    )
  }
}

private struct WritingMaterialRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextUnit() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }
}
