import Foundation

/// Reuses per-segment grapheme materialization while building line text repeatedly.
public struct LineTextMaterializer: Sendable {
  /// The prepared text this materializer reads from.
  public let prepared: PreparedText
  private var graphemeCache: [Int: [String]] = [:]

  /// Creates a line text materializer.
  public init(prepared: PreparedText) {
    self.prepared = prepared
  }

  /// Builds the text for a prepared cursor range.
  public mutating func build(start: LayoutCursor, end: LayoutCursor) -> String {
    precondition(start.segmentIndex >= 0 && start.segmentIndex <= prepared.segments.count)
    precondition(end.segmentIndex >= 0 && end.segmentIndex <= prepared.segments.count)
    precondition((start.segmentIndex, start.graphemeIndex) <= (end.segmentIndex, end.graphemeIndex))
    var text = ""
    let endsWithDiscretionaryHyphen = lineHasDiscretionaryHyphen(
      prepared: prepared, start: start, end: end)

    if start.segmentIndex < end.segmentIndex {
      for segmentIndex in start.segmentIndex..<end.segmentIndex {
        let segment = prepared.segments[segmentIndex]
        if segment.kind == .softHyphen || segment.kind == .hardBreak {
          continue
        }

        if segmentIndex == start.segmentIndex && start.graphemeIndex > 0 {
          let graphemes = graphemes(for: segmentIndex)
          precondition(start.graphemeIndex < graphemes.count)
          appendSegmentGraphemeRange(
            &text,
            graphemes: graphemes,
            startGraphemeIndex: start.graphemeIndex,
            endGraphemeIndex: graphemes.count
          )
        } else {
          text += segment.text
        }
      }
    }

    if end.graphemeIndex > 0, end.segmentIndex < prepared.segments.count {
      if endsWithDiscretionaryHyphen {
        text += "-"
      }
      let graphemes = graphemes(for: end.segmentIndex)
      precondition(end.graphemeIndex <= graphemes.count)
      appendSegmentGraphemeRange(
        &text,
        graphemes: graphemes,
        startGraphemeIndex: start.segmentIndex == end.segmentIndex ? start.graphemeIndex : 0,
        endGraphemeIndex: end.graphemeIndex
      )
    } else if endsWithDiscretionaryHyphen {
      text += "-"
    }

    return text
  }

  private mutating func graphemes(for segmentIndex: Int) -> [String] {
    if let cached = graphemeCache[segmentIndex] {
      return cached
    }
    let computed = composedCharacterClusters(prepared.segments[segmentIndex].text)
    graphemeCache[segmentIndex] = computed
    return computed
  }
}
