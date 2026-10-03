import Foundation
import LiveTextCore

/// One glyph extracted during preparation. No Core Text object is retained.
public struct InlineGlyph: Sendable, Hashable, Codable {
  public let glyphID: UInt16
  public let positionX: Double
  public let positionY: Double
  public let sourceUTF16Index: Int
  public let sourceRange: InlineSourceRange

  public init(
    glyphID: UInt16,
    positionX: Double,
    positionY: Double,
    sourceUTF16Index: Int,
    sourceRange: InlineSourceRange
  ) throws {
    guard positionX.isFinite, positionY.isFinite, sourceUTF16Index >= 0 else {
      throw InlineLayoutError.unsupportedShaping("non-finite glyph position or source index")
    }
    self.glyphID = glyphID
    self.positionX = positionX
    self.positionY = positionY
    self.sourceUTF16Index = sourceUTF16Index
    self.sourceRange = sourceRange
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      glyphID: values.decode(UInt16.self, forKey: .glyphID),
      positionX: values.decode(Double.self, forKey: .positionX),
      positionY: values.decode(Double.self, forKey: .positionY),
      sourceUTF16Index: values.decode(Int.self, forKey: .sourceUTF16Index),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case glyphID, positionX, positionY, sourceUTF16Index, sourceRange
  }
}

/// Compact shaped data sufficient for Canvas drawing and reveal mapping.
public struct InlineShapedRun: Sendable, Hashable, Codable {
  public let glyphs: [InlineGlyph]
  public let font: FontDescriptor
  public let sourceRange: InlineSourceRange
  public let advance: Double
  public let ascent: Double
  public let descent: Double

  public init(
    glyphs: [InlineGlyph],
    font: FontDescriptor,
    sourceRange: InlineSourceRange,
    advance: Double,
    ascent: Double,
    descent: Double
  ) throws {
    guard advance.isFinite, advance >= 0,
      ascent.isFinite, ascent >= 0,
      descent.isFinite, descent >= 0
    else {
      throw InlineLayoutError.unsupportedShaping("invalid run metrics")
    }
    guard
      glyphs.allSatisfy({ glyph in
        sourceRange.startUTF16 <= glyph.sourceRange.startUTF16
          && glyph.sourceRange.endUTF16 <= sourceRange.endUTF16
          && glyph.sourceRange.startUTF16 <= glyph.sourceUTF16Index
          && glyph.sourceUTF16Index < glyph.sourceRange.endUTF16
      })
    else {
      throw InlineLayoutError.unsupportedShaping("glyph ownership is outside its run")
    }
    self.glyphs = glyphs
    self.font = font
    self.sourceRange = sourceRange
    self.advance = advance
    self.ascent = ascent
    self.descent = descent
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      glyphs: values.decode([InlineGlyph].self, forKey: .glyphs),
      font: values.decode(FontDescriptor.self, forKey: .font),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange),
      advance: values.decode(Double.self, forKey: .advance),
      ascent: values.decode(Double.self, forKey: .ascent),
      descent: values.decode(Double.self, forKey: .descent)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case glyphs, font, sourceRange, advance, ascent, descent
  }
}

/// Shaping output for one text atom, including grapheme-to-advance mapping.
public struct InlineShapedText: Sendable, Hashable, Codable {
  public let graphemeRanges: [InlineSourceRange]
  public let graphemeAdvances: [Double]
  /// Grapheme boundaries that do not split a shaped glyph cluster.
  public let graphemeCanBreakAfter: [Bool]
  public let runs: [InlineShapedRun]
  public let metrics: InlineMetrics

  public init(
    graphemeRanges: [InlineSourceRange],
    graphemeAdvances: [Double],
    graphemeCanBreakAfter: [Bool]? = nil,
    runs: [InlineShapedRun],
    metrics: InlineMetrics
  ) throws {
    guard graphemeRanges.count == graphemeAdvances.count,
      graphemeAdvances.allSatisfy({ $0.isFinite && $0 >= 0 }),
      graphemeRanges.indices.dropFirst().allSatisfy({ index in
        graphemeRanges[index - 1].endUTF16 <= graphemeRanges[index].startUTF16
      })
    else {
      throw InlineLayoutError.unsupportedShaping("grapheme mapping and advances differ")
    }
    if let firstRange = graphemeRanges.first, let lastRange = graphemeRanges.last {
      guard
        runs.allSatisfy({ run in
          firstRange.startUTF16 <= run.sourceRange.startUTF16
            && run.sourceRange.endUTF16 <= lastRange.endUTF16
        })
      else {
        throw InlineLayoutError.unsupportedShaping("run ownership is outside grapheme mapping")
      }
    } else {
      guard runs.isEmpty else {
        throw InlineLayoutError.unsupportedShaping("runs require grapheme mapping")
      }
    }
    let derivedBreaks = Self.deriveGraphemeBreaks(graphemeRanges: graphemeRanges, runs: runs)
    if let graphemeCanBreakAfter {
      guard graphemeCanBreakAfter == derivedBreaks else {
        throw InlineLayoutError.unsupportedShaping("grapheme cluster boundaries differ")
      }
    }
    self.graphemeRanges = graphemeRanges
    self.graphemeAdvances = graphemeAdvances
    self.graphemeCanBreakAfter = derivedBreaks
    self.runs = runs
    self.metrics = metrics
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      graphemeRanges: values.decode([InlineSourceRange].self, forKey: .graphemeRanges),
      graphemeAdvances: values.decode([Double].self, forKey: .graphemeAdvances),
      graphemeCanBreakAfter: values.decode([Bool].self, forKey: .graphemeCanBreakAfter),
      runs: values.decode([InlineShapedRun].self, forKey: .runs),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case graphemeRanges, graphemeAdvances, graphemeCanBreakAfter, runs, metrics
  }

  private static func deriveGraphemeBreaks(
    graphemeRanges: [InlineSourceRange],
    runs: [InlineShapedRun]
  ) -> [Bool] {
    // A glyph suppresses every grapheme boundary strictly inside its source
    // interval. Mark the interval once instead of scanning every glyph for
    // every grapheme (O(G * N)). Runs and glyphs may be in visual/RTL order.
    var crossings = [Int](repeating: 0, count: graphemeRanges.count + 1)
    for run in runs {
      for glyph in run.glyphs {
        let lower = InlineSourceRangeSearch.firstEnding(
          after: glyph.sourceRange.startUTF16, in: graphemeRanges)
        let upper = InlineSourceRangeSearch.firstEnding(
          atOrAfter: glyph.sourceRange.endUTF16, in: graphemeRanges)
        if lower < upper {
          crossings[lower] += 1
          crossings[upper] -= 1
        }
      }
    }
    var active = 0
    return graphemeRanges.indices.map { index in
      active += crossings[index]
      return active == 0
    }
  }
}

/// Preparation-time text shaping boundary.
public protocol InlineTextShaping: Sendable {
  func shape(
    text: String,
    style: InlineTextStyle,
    sourceRange: InlineSourceRange
  ) throws -> InlineShapedText
}

/// Optional shaping boundary for backends that can observe cancellation while
/// walking expensive glyph data.
public protocol CancellableInlineTextShaping: InlineTextShaping {
  func shape(
    text: String,
    style: InlineTextStyle,
    sourceRange: InlineSourceRange,
    cancellation: InlineCancellationCheck
  ) throws -> InlineShapedText
}
