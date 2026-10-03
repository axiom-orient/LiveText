import Foundation

/// A tokenizer-produced word or separator range in UTF-16 source coordinates.
public struct WordToken: Sendable, Hashable, Codable {
  public var text: String
  public var startUTF16: Int
  public var isWordLike: Bool

  /// Creates a tokenizer token.
  public init(text: String, startUTF16: Int, isWordLike: Bool) {
    self.text = text
    self.startUTF16 = startUTF16
    self.isWordLike = isWordLike
  }
}

/// A width-independent segment produced by text analysis.
public struct AnalysisSegment: Sendable, Hashable, Codable {
  public var text: String
  public var isWordLike: Bool
  public var kind: SegmentBreakKind
  public var startUTF16: Int

  /// Creates an analysis segment.
  public init(text: String, isWordLike: Bool, kind: SegmentBreakKind, startUTF16: Int) {
    self.text = text
    self.isWordLike = isWordLike
    self.kind = kind
    self.startUTF16 = startUTF16
  }
}

/// A hard-break-delimited analysis chunk.
public struct AnalysisChunk: Sendable, Hashable, Codable {
  public var startSegmentIndex: Int
  public var endSegmentIndex: Int
  public var consumedEndSegmentIndex: Int

  /// Creates an analysis chunk over segment indices.
  public init(startSegmentIndex: Int, endSegmentIndex: Int, consumedEndSegmentIndex: Int) {
    self.startSegmentIndex = startSegmentIndex
    self.endSegmentIndex = endSegmentIndex
    self.consumedEndSegmentIndex = consumedEndSegmentIndex
  }
}

/// The result of width-independent text analysis.
public struct TextAnalysis: Sendable, Hashable, Codable {
  public var normalized: String
  public var segments: [AnalysisSegment]
  public var chunks: [AnalysisChunk]

  /// Creates an analysis result.
  public init(normalized: String, segments: [AnalysisSegment], chunks: [AnalysisChunk]) {
    self.normalized = normalized
    self.segments = segments
    self.chunks = chunks
  }
}
