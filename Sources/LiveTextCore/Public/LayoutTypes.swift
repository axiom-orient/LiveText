import Foundation

/// A cursor into prepared text, identified by segment and grapheme index.
public struct LayoutCursor: Sendable, Hashable, Codable {
  public var segmentIndex: Int
  public var graphemeIndex: Int

  /// Creates a layout cursor.
  public init(segmentIndex: Int = 0, graphemeIndex: Int = 0) {
    self.segmentIndex = segmentIndex
    self.graphemeIndex = graphemeIndex
  }

  /// The beginning of prepared text.
  public static let zero = LayoutCursor()
}

/// The position at which a provider-driven variable layout can be resumed.
public struct VariableLayoutContinuation: Sendable, Hashable, Codable {
  public var cursor: LayoutCursor
  public var nextIndex: Int

  /// Creates a variable-layout continuation.
  public init(cursor: LayoutCursor, nextIndex: Int) {
    self.cursor = cursor
    self.nextIndex = nextIndex
  }
}

/// A non-materialized line range and its measured width.
public struct LayoutLineRange: Sendable, Hashable, Codable {
  public var width: Double
  public var start: LayoutCursor
  public var end: LayoutCursor

  /// Creates a line range.
  public init(width: Double, start: LayoutCursor, end: LayoutCursor) {
    self.width = width
    self.start = start
    self.end = end
  }
}

/// A materialized fixed-width layout line.
public struct LayoutLine: Sendable, Hashable, Codable {
  public var text: String
  public var width: Double
  public var start: LayoutCursor
  public var end: LayoutCursor

  /// Creates a materialized layout line.
  public init(text: String, width: Double, start: LayoutCursor, end: LayoutCursor) {
    self.text = text
    self.width = width
    self.start = start
    self.end = end
  }
}

/// Summary result for fixed-width layout without materialized lines.
public struct LayoutResult: Sendable, Hashable, Codable {
  public var lineCount: Int
  public var height: Double

  /// Creates a fixed-width layout summary.
  public init(lineCount: Int, height: Double) {
    self.lineCount = lineCount
    self.height = height
  }
}

/// Fixed-width layout result with materialized lines.
public struct LayoutLinesResult: Sendable, Hashable, Codable {
  public var lineCount: Int
  public var height: Double
  public var lines: [LayoutLine]

  /// Creates a fixed-width line result.
  public init(lineCount: Int, height: Double, lines: [LayoutLine]) {
    self.lineCount = lineCount
    self.height = height
    self.lines = lines
  }
}

/// Horizontal constraint for one variable-width line or row fragment.
public struct VariableLineFragmentConstraint: Sendable, Hashable, Codable {
  public var originX: Double
  public var maxWidth: Double

  /// Creates a fragment constraint.
  public init(originX: Double, maxWidth: Double) {
    self.originX = originX
    self.maxWidth = maxWidth
  }
}

/// A materialized line produced by variable-width single-fragment layout.
public struct VariableLayoutLine: Sendable, Hashable, Codable {
  public var text: String
  public var width: Double
  public var start: LayoutCursor
  public var end: LayoutCursor
  public var originX: Double
  public var originY: Double

  /// Creates a variable-width layout line.
  public init(
    text: String,
    width: Double,
    start: LayoutCursor,
    end: LayoutCursor,
    originX: Double,
    originY: Double
  ) {
    self.text = text
    self.width = width
    self.start = start
    self.end = end
    self.originX = originX
    self.originY = originY
  }
}

/// Display-only line text after sticky punctuation normalization.
public struct VariableLayoutDisplayLine: Sendable, Hashable, Codable {
  public var text: String
  public var originX: Double
  public var originY: Double

  /// Creates a display-only variable layout line.
  public init(
    text: String,
    originX: Double,
    originY: Double
  ) {
    self.text = text
    self.originX = originX
    self.originY = originY
  }
}

/// A materialized fragment inside an obstacle-aware variable layout row.
public struct VariableLayoutFragment: Sendable, Hashable, Codable {
  public var text: String
  public var width: Double
  public var start: LayoutCursor
  public var end: LayoutCursor
  public var originX: Double
  public var originY: Double
  public var rowIndex: Int
  public var fragmentIndex: Int

  /// Creates a variable layout fragment.
  public init(
    text: String,
    width: Double,
    start: LayoutCursor,
    end: LayoutCursor,
    originX: Double,
    originY: Double,
    rowIndex: Int,
    fragmentIndex: Int
  ) {
    self.text = text
    self.width = width
    self.start = start
    self.end = end
    self.originX = originX
    self.originY = originY
    self.rowIndex = rowIndex
    self.fragmentIndex = fragmentIndex
  }
}

/// A row containing one or more variable layout fragments.
public struct VariableLayoutRow: Sendable, Hashable, Codable {
  public var originY: Double
  public var start: LayoutCursor
  public var end: LayoutCursor
  public var fragments: [VariableLayoutFragment]
  public var visualWidth: Double

  /// Creates a variable layout row.
  public init(
    originY: Double,
    start: LayoutCursor,
    end: LayoutCursor,
    fragments: [VariableLayoutFragment],
    visualWidth: Double
  ) {
    self.originY = originY
    self.start = start
    self.end = end
    self.fragments = fragments
    self.visualWidth = visualWidth
  }
}

/// Obstacle-aware row layout result.
public struct VariableLayoutRowsResult: Sendable, Hashable, Codable {
  public var rowCount: Int
  public var height: Double
  public var maxRowWidth: Double
  public var rows: [VariableLayoutRow]
  /// The next batch position, or `nil` when all prepared text was consumed.
  public var continuation: VariableLayoutContinuation?

  /// Whether this batch consumed all prepared text.
  public var isComplete: Bool { continuation == nil }

  /// Creates a row layout result.
  public init(
    rowCount: Int,
    height: Double,
    maxRowWidth: Double,
    rows: [VariableLayoutRow],
    continuation: VariableLayoutContinuation? = nil
  ) {
    self.rowCount = rowCount
    self.height = height
    self.maxRowWidth = maxRowWidth
    self.rows = rows
    self.continuation = continuation
  }
}

/// Variable-width single-fragment layout result.
public struct VariableLayoutResult: Sendable, Hashable, Codable {
  public var lineCount: Int
  public var height: Double
  public var maxLineWidth: Double
  public var lines: [VariableLayoutLine]
  /// The next batch position, or `nil` when all prepared text was consumed.
  public var continuation: VariableLayoutContinuation?

  /// Whether this batch consumed all prepared text.
  public var isComplete: Bool { continuation == nil }

  /// Creates a variable-width layout result.
  public init(
    lineCount: Int,
    height: Double,
    maxLineWidth: Double,
    lines: [VariableLayoutLine],
    continuation: VariableLayoutContinuation? = nil
  ) {
    self.lineCount = lineCount
    self.height = height
    self.maxLineWidth = maxLineWidth
    self.lines = lines
    self.continuation = continuation
  }
}

/// Aggregate line statistics for prepared text at one width.
public struct LineStats: Sendable, Hashable, Codable {
  public var lineCount: Int
  public var maxLineWidth: Double

  /// Creates line statistics.
  public init(lineCount: Int, maxLineWidth: Double) {
    self.lineCount = lineCount
    self.maxLineWidth = maxLineWidth
  }
}

/// Errors thrown by public LiveTextCore entry points.
public enum LiveTextCoreError: Error, Sendable, LocalizedError {
  case invalidWidth(Double)
  case invalidCursor(LayoutCursor, reason: String)
  case invalidFragmentConfiguration(String)
  case backendUnavailable(String)
  case measurementFailure(String)

  /// A localized error summary.
  public var errorDescription: String? {
    switch self {
    case .invalidWidth(let width):
      return "Invalid maxWidth: \(width)"
    case .invalidCursor(let cursor, let reason):
      return "Invalid layout cursor \(cursor): \(reason)"
    case .invalidFragmentConfiguration(let reason):
      return "Invalid fragment configuration: \(reason)"
    case .backendUnavailable(let message):
      return message
    case .measurementFailure(let message):
      return message
    }
  }
}

extension SegmentBreakKind {
  var trimsAtLineStart: Bool {
    switch self {
    case .space, .zeroWidthBreak, .softHyphen:
      return true
    default:
      return false
    }
  }

  var breaksAfter: Bool {
    switch self {
    case .space, .preservedSpace, .tab, .zeroWidthBreak, .softHyphen:
      return true
    default:
      return false
    }
  }
}
