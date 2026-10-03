import Foundation

/// Controls how source whitespace is normalized before segmentation.
public enum WhiteSpaceMode: String, Sendable, Hashable, Codable {
  /// Collapses ordinary whitespace and drops hard line breaks.
  case normal

  /// Preserves ordinary spaces and hard line breaks.
  case preWrap = "pre-wrap"
}

/// Controls whether CJK-sensitive text may break between units.
public enum WordBreakMode: String, Sendable, Hashable, Codable {
  /// Uses the default break policy for each script.
  case normal

  /// Keeps CJK word-like runs together where possible.
  case keepAll = "keep-all"
}

/// Classifies how a prepared segment participates in line breaking.
public enum SegmentBreakKind: String, Sendable, Hashable, Codable {
  case text
  case space
  case preservedSpace = "preserved-space"
  case tab
  case glue
  case zeroWidthBreak = "zero-width-break"
  case softHyphen = "soft-hyphen"
  case hardBreak = "hard-break"
}

/// Selects how breakable segment advances are measured.
public enum BreakableMeasurementPolicy: String, Sendable, Hashable, Codable {
  case browserParity
  case appleBounded
  case exactPrefixWidths
}

/// Describes the concrete measurement mode requested for a segment.
public enum BreakableMeasurementMode: String, Sendable, Hashable, Codable {
  case none
  case sumGraphemes
  case exactPrefix
  case pairContext
}

/// Tunable engine policy values that affect line fitting and breakable measurement.
public struct EngineProfile: Sendable, Hashable, Codable {
  public var lineFitEpsilon: Double
  public var carryCJKAfterClosingQuote: Bool
  public var preferEarlySoftHyphenBreak: Bool
  public var breakableMeasurementPolicy: BreakableMeasurementPolicy

  /// Creates an explicit engine profile.
  public init(
    lineFitEpsilon: Double,
    carryCJKAfterClosingQuote: Bool,
    preferEarlySoftHyphenBreak: Bool,
    breakableMeasurementPolicy: BreakableMeasurementPolicy
  ) {
    self.lineFitEpsilon = lineFitEpsilon
    self.carryCJKAfterClosingQuote = carryCJKAfterClosingQuote
    self.preferEarlySoftHyphenBreak = preferEarlySoftHyphenBreak
    self.breakableMeasurementPolicy = breakableMeasurementPolicy
  }

  /// Profile intended to preserve historical browser line-measurement parity.
  public static let browserParity = EngineProfile(
    lineFitEpsilon: 1.0 / 64.0,
    carryCJKAfterClosingQuote: false,
    preferEarlySoftHyphenBreak: true,
    breakableMeasurementPolicy: .browserParity
  )

  /// Default Apple-platform profile using exact prefix widths for breakable segments.
  public static let appleRecommended = EngineProfile(
    lineFitEpsilon: 1.0 / 64.0,
    carryCJKAfterClosingQuote: false,
    preferEarlySoftHyphenBreak: true,
    breakableMeasurementPolicy: .exactPrefixWidths
  )

  /// Apple-platform profile optimized for latency-sensitive long input.
  public static let appleBounded = EngineProfile(
    lineFitEpsilon: 1.0 / 64.0,
    carryCJKAfterClosingQuote: false,
    preferEarlySoftHyphenBreak: true,
    breakableMeasurementPolicy: .appleBounded
  )
}

/// Options applied while analyzing and preparing a source string.
public struct PrepareOptions: Sendable, Hashable, Codable {
  public var whiteSpace: WhiteSpaceMode
  public var wordBreak: WordBreakMode
  public var localeIdentifier: String?

  /// Creates preparation options.
  public init(
    whiteSpace: WhiteSpaceMode = .normal,
    wordBreak: WordBreakMode = .normal,
    localeIdentifier: String? = nil
  ) {
    self.whiteSpace = whiteSpace
    self.wordBreak = wordBreak
    self.localeIdentifier = localeIdentifier
  }
}

/// Minimal font identity used by measurement backends.
public struct FontDescriptor: Sendable, Hashable, Codable {
  public var postScriptName: String
  public var pointSize: Double
  public var localeIdentifier: String?

  /// Creates a font descriptor.
  public init(
    postScriptName: String,
    pointSize: Double,
    localeIdentifier: String? = nil
  ) {
    self.postScriptName = postScriptName
    self.pointSize = pointSize
    self.localeIdentifier = localeIdentifier
  }
}
