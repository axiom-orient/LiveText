import Foundation
import LiveTextCore

/// Stable identity for a renderer-side inline asset.
public struct InlineAssetID: Sendable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) throws {
    guard !rawValue.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    try self.init(rawValue: value)
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(rawValue)
  }

  public var description: String { rawValue }
}

/// Metrics supplied by the asset owner or text shaper.
public struct InlineMetrics: Sendable, Hashable, Codable {
  public let advance: Double
  public let ascent: Double
  public let descent: Double
  public let baselineOffset: Double

  public init(
    advance: Double,
    ascent: Double,
    descent: Double,
    baselineOffset: Double = 0
  ) throws {
    try Self.validate(advance, name: "advance", nonNegative: true)
    try Self.validate(ascent, name: "ascent", nonNegative: true)
    try Self.validate(descent, name: "descent", nonNegative: true)
    try Self.validate(baselineOffset, name: "baselineOffset", nonNegative: false)
    self.advance = advance
    self.ascent = ascent
    self.descent = descent
    self.baselineOffset = baselineOffset
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      advance: values.decode(Double.self, forKey: .advance),
      ascent: values.decode(Double.self, forKey: .ascent),
      descent: values.decode(Double.self, forKey: .descent),
      baselineOffset: values.decode(Double.self, forKey: .baselineOffset)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case advance, ascent, descent, baselineOffset
  }

  private static func validate(_ value: Double, name: String, nonNegative: Bool) throws {
    guard value.isFinite, !nonNegative || value >= 0 else {
      throw InlineLayoutError.invalidMetric(name: name, value: value)
    }
  }
}

/// Renderer-neutral text styling tokens.
public struct InlineTextStyle: Sendable, Hashable, Codable {
  public let font: FontDescriptor
  public let tracking: Double
  public let baselineOffset: Double
  public let presentationID: String?
  public let revealMode: InlineTextRevealMode

  public init(
    font: FontDescriptor,
    tracking: Double = 0,
    baselineOffset: Double = 0,
    presentationID: String? = nil,
    revealMode: InlineTextRevealMode = .native
  ) throws {
    guard !font.postScriptName.isEmpty else { throw InlineLayoutError.emptyFontName }
    guard font.pointSize.isFinite, font.pointSize > 0 else {
      throw InlineLayoutError.invalidFontSize(font.pointSize)
    }
    guard tracking.isFinite else { throw InlineLayoutError.invalidTracking(tracking) }
    guard baselineOffset.isFinite else {
      throw InlineLayoutError.invalidBaselineOffset(baselineOffset)
    }
    self.font = font
    self.tracking = tracking
    self.baselineOffset = baselineOffset
    self.presentationID = presentationID
    self.revealMode = revealMode
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      font: values.decode(FontDescriptor.self, forKey: .font),
      tracking: values.decode(Double.self, forKey: .tracking),
      baselineOffset: values.decode(Double.self, forKey: .baselineOffset),
      presentationID: values.decodeIfPresent(String.self, forKey: .presentationID),
      revealMode: values.decode(InlineTextRevealMode.self, forKey: .revealMode)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case font, tracking, baselineOffset, presentationID, revealMode
  }
}

/// Atom-boundary policy. Hard breaks are represented by a newline in a text atom.
public enum InlineBreakBehavior: String, Sendable, Hashable, Codable {
  case normal
  case keepTogether
  case breakBefore
  case breakAfter
  case noBreakAround
}

/// Policy for an atomic vector whose advance exceeds the line width.
public enum InlineOversizedVectorPolicy: Sendable, Hashable, Codable {
  case reject
  case scaleToFit(minimumScale: Double)
  case overflow

  public func validate() throws {
    if case .scaleToFit(let minimumScale) = self,
      !minimumScale.isFinite || minimumScale <= 0 || minimumScale > 1
    {
      throw InlineLayoutError.invalidOversizedVectorPolicy
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try values.decode(String.self, forKey: .kind)
    switch kind {
    case "reject": self = .reject
    case "overflow": self = .overflow
    case "scaleToFit":
      let scale = try values.decode(Double.self, forKey: .minimumScale)
      guard scale.isFinite, scale > 0, scale <= 1 else {
        throw InlineLayoutError.invalidOversizedVectorPolicy
      }
      self = .scaleToFit(minimumScale: scale)
    default:
      throw InlineLayoutError.invalidOversizedVectorPolicy
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .reject:
      try values.encode("reject", forKey: .kind)
    case .overflow:
      try values.encode("overflow", forKey: .kind)
    case .scaleToFit(let scale):
      guard scale.isFinite, scale > 0, scale <= 1 else {
        throw InlineLayoutError.invalidOversizedVectorPolicy
      }
      try values.encode("scaleToFit", forKey: .kind)
      try values.encode(scale, forKey: .minimumScale)
    }
  }

  private enum CodingKeys: String, CodingKey { case kind, minimumScale }
}
