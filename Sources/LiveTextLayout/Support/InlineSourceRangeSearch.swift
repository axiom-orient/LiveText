import Foundation

/// Searches ranges whose starts and ends are nondecreasing, without rescanning text.
/// Repeated identical ranges are allowed for multiple strokes in one grapheme.
/// PreparedInlineText validates that its ranges are the source's exact graphemes.
/// This helper does not own, normalize, or reinterpret source coordinates.
package enum InlineSourceRangeSearch {
  package static func firstEnding(
    after offset: Int, in ranges: [InlineSourceRange]
  ) -> Int {
    var lower = 0
    var upper = ranges.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if ranges[middle].endUTF16 <= offset { lower = middle + 1 } else { upper = middle }
    }
    return lower
  }

  package static func firstEnding(
    atOrAfter offset: Int, in ranges: [InlineSourceRange]
  ) -> Int {
    var lower = 0
    var upper = ranges.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if ranges[middle].endUTF16 < offset { lower = middle + 1 } else { upper = middle }
    }
    return lower
  }

  package static func firstStarting(
    atOrAfter offset: Int, in ranges: [InlineSourceRange]
  ) -> Int {
    var lower = 0
    var upper = ranges.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if ranges[middle].startUTF16 < offset { lower = middle + 1 } else { upper = middle }
    }
    return lower
  }

  package static func overlappingIndices(
    in ranges: [InlineSourceRange], with range: InlineSourceRange
  ) -> Range<Int> {
    guard range.startUTF16 < range.endUTF16, !ranges.isEmpty else { return 0..<0 }
    let lower = firstEnding(after: range.startUTF16, in: ranges)
    let upper = firstStarting(atOrAfter: range.endUTF16, in: ranges)
    return lower..<max(lower, upper)
  }

  package static func exactIndex(
    of range: InlineSourceRange, in ranges: [InlineSourceRange]
  ) -> Int? {
    let index = firstStarting(atOrAfter: range.startUTF16, in: ranges)
    return index < ranges.count && ranges[index] == range ? index : nil
  }
}
