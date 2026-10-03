import Foundation

/// A backend measurement request for one segment.
public struct SegmentMeasurementRequest: Sendable, Hashable, Codable {
  public var text: String
  public var font: FontDescriptor
  public var localeIdentifier: String?
  public var breakableMode: BreakableMeasurementMode

  /// Creates a segment measurement request.
  public init(
    text: String,
    font: FontDescriptor,
    localeIdentifier: String? = nil,
    breakableMode: BreakableMeasurementMode
  ) {
    self.text = text
    self.font = font
    self.localeIdentifier = localeIdentifier
    self.breakableMode = breakableMode
  }
}

/// Width and optional breakable advances returned by a measurement backend.
public struct SegmentMeasurement: Sendable, Hashable, Codable {
  public var width: Double
  public var containsCJK: Bool
  public var breakableAdvances: [Double]?

  /// Creates a segment measurement result.
  public init(width: Double, containsCJK: Bool, breakableAdvances: [Double]?) {
    self.width = width
    self.containsCJK = containsCJK
    self.breakableAdvances = breakableAdvances
  }
}

/// Tokenizes normalized text into word-like and separator ranges.
public protocol WordSegmenting: Sendable {
  /// Returns tokens for normalized text and an optional locale identifier.
  func tokenize(_ text: String, localeIdentifier: String?) -> [WordToken]
}

/// Measures segment widths for a concrete font backend.
public protocol SegmentMeasuring: Sendable {
  /// Measures a segment request.
  func measure(_ request: SegmentMeasurementRequest) throws -> SegmentMeasurement
}

/// A measured segment inside `PreparedText`.
public struct PreparedSegment: Sendable, Hashable, Codable {
  public var text: String
  public var isWordLike: Bool
  public var kind: SegmentBreakKind
  public var startUTF16: Int
  public var width: Double
  public var lineEndFitAdvance: Double
  public var lineEndPaintAdvance: Double
  public var breakableAdvances: [Double]?

  /// Creates a prepared segment.
  public init(
    text: String,
    isWordLike: Bool,
    kind: SegmentBreakKind,
    startUTF16: Int,
    width: Double,
    lineEndFitAdvance: Double,
    lineEndPaintAdvance: Double,
    breakableAdvances: [Double]?
  ) {
    self.text = text
    self.isWordLike = isWordLike
    self.kind = kind
    self.startUTF16 = startUTF16
    self.width = width
    self.lineEndFitAdvance = lineEndFitAdvance
    self.lineEndPaintAdvance = lineEndPaintAdvance
    self.breakableAdvances = breakableAdvances
  }
}

/// A hard-break-delimited prepared-text chunk.
public struct PreparedChunk: Sendable, Hashable, Codable {
  public var startSegmentIndex: Int
  public var endSegmentIndex: Int
  public var consumedEndSegmentIndex: Int

  /// Creates a prepared chunk over segment indices.
  public init(startSegmentIndex: Int, endSegmentIndex: Int, consumedEndSegmentIndex: Int) {
    self.startSegmentIndex = startSegmentIndex
    self.endSegmentIndex = endSegmentIndex
    self.consumedEndSegmentIndex = consumedEndSegmentIndex
  }
}

/// Width-independent prepared text that can be laid out repeatedly at different widths.
public struct PreparedText: Sendable, Hashable, Codable {
  public var source: String
  public var normalized: String
  public var font: FontDescriptor
  public var options: PrepareOptions
  public var profile: EngineProfile
  public var segments: [PreparedSegment]
  public var chunks: [PreparedChunk]
  public var simpleLineWalkFastPath: Bool
  public var discretionaryHyphenWidth: Double
  public var tabStopAdvance: Double

  /// Creates a prepared text value.
  public init(
    source: String,
    normalized: String,
    font: FontDescriptor,
    options: PrepareOptions,
    profile: EngineProfile,
    segments: [PreparedSegment],
    chunks: [PreparedChunk],
    simpleLineWalkFastPath: Bool,
    discretionaryHyphenWidth: Double,
    tabStopAdvance: Double
  ) {
    self.source = source
    self.normalized = normalized
    self.font = font
    self.options = options
    self.profile = profile
    self.segments = segments
    self.chunks = chunks
    self.simpleLineWalkFastPath = simpleLineWalkFastPath
    self.discretionaryHyphenWidth = discretionaryHyphenWidth
    self.tabStopAdvance = tabStopAdvance
  }
}
