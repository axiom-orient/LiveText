import Foundation

func normalizeLineStart(
  prepared: PreparedText,
  start: LayoutCursor
) throws -> LayoutCursor? {
  guard var cursor = try validatedCursor(prepared: prepared, cursor: start) else {
    return nil
  }
  let chunkIndex = normalizeLineStartChunkIndex(prepared: prepared, cursor: &cursor)
  return chunkIndex < 0 ? nil : cursor
}

func countPreparedLines(
  prepared: PreparedText,
  maxWidth: Double
) -> Int {
  walkPreparedLinesRaw(prepared: prepared, maxWidth: maxWidth)
}

func layoutNextLineRange(
  prepared: PreparedText,
  start: LayoutCursor,
  maxWidth: Double
) throws -> LayoutLineRange? {
  guard var end = try validatedCursor(prepared: prepared, cursor: start) else {
    return nil
  }
  return layoutNextFragmentRangeValidated(
    prepared: prepared,
    end: &end,
    maxWidth: maxWidth,
    isFirstFragmentInRow: true
  )
}

func layoutNextFragmentRangeValidated(
  prepared: PreparedText,
  end: inout LayoutCursor,
  maxWidth: Double,
  isFirstFragmentInRow: Bool
) -> LayoutLineRange? {
  var chunkIndexHint: Int?
  return layoutNextFragmentRangeValidatedWithHint(
    prepared: prepared,
    end: &end,
    maxWidth: maxWidth,
    isFirstFragmentInRow: isFirstFragmentInRow,
    chunkIndexHint: &chunkIndexHint
  )
}

func layoutNextFragmentRangeValidatedWithHint(
  prepared: PreparedText,
  end: inout LayoutCursor,
  maxWidth: Double,
  isFirstFragmentInRow: Bool,
  chunkIndexHint: inout Int?
) -> LayoutLineRange? {
  // Variable layout owns this hint for a sequential cursor walk. The public
  // arbitrary-start entry point uses the wrapper above and retains binary lookup.
  let chunkIndex: Int
  if let hintedChunkIndex = chunkIndexHint {
    if isFirstFragmentInRow {
      chunkIndex = normalizeLineStartChunkIndexFromHint(
        prepared: prepared,
        chunkIndex: hintedChunkIndex,
        cursor: &end
      )
    } else {
      chunkIndex = findChunkIndexForStartFromHint(
        prepared: prepared,
        chunkIndex: hintedChunkIndex,
        segmentIndex: end.segmentIndex
      )
    }
  } else {
    if isFirstFragmentInRow {
      chunkIndex = normalizeLineStartChunkIndex(prepared: prepared, cursor: &end)
    } else {
      if end.segmentIndex >= prepared.segments.count {
        return nil
      }
      chunkIndex = findChunkIndexForStart(prepared: prepared, segmentIndex: end.segmentIndex)
    }
  }

  if chunkIndex < 0 {
    return nil
  }

  let lineStart = end
  let width =
    prepared.simpleLineWalkFastPath
    ? stepPreparedSimpleLineGeometry(prepared: prepared, cursor: &end, maxWidth: maxWidth)
    : stepPreparedChunkLineGeometry(
      prepared: prepared, cursor: &end, chunkIndex: chunkIndex, maxWidth: maxWidth)

  guard let width else { return nil }
  chunkIndexHint = chunkIndex
  return LayoutLineRange(width: width, start: lineStart, end: end)
}

func continuationFragmentCursor(
  prepared: PreparedText,
  range: LayoutLineRange
) -> LayoutCursor {
  guard range.end.graphemeIndex == 0 else {
    return range.end
  }

  var segmentIndex = range.end.segmentIndex
  while segmentIndex > range.start.segmentIndex {
    let previousSegment = prepared.segments[segmentIndex - 1]
    guard previousSegment.kind.trimsAtLineStart else {
      break
    }
    segmentIndex -= 1
  }

  guard segmentIndex < range.end.segmentIndex else {
    return range.end
  }

  return LayoutCursor(segmentIndex: segmentIndex, graphemeIndex: 0)
}

func stepPreparedLineGeometry(
  prepared: PreparedText,
  cursor: inout LayoutCursor,
  maxWidth: Double
) throws -> Double? {
  guard let validatedStart = try validatedCursor(prepared: prepared, cursor: cursor) else {
    cursor = LayoutCursor(segmentIndex: prepared.segments.count, graphemeIndex: 0)
    return nil
  }
  cursor = validatedStart
  return stepPreparedLineGeometryValidated(prepared: prepared, cursor: &cursor, maxWidth: maxWidth)
}

private func stepPreparedLineGeometryValidated(
  prepared: PreparedText,
  cursor: inout LayoutCursor,
  maxWidth: Double
) -> Double? {
  let chunkIndex = normalizeLineStartChunkIndex(prepared: prepared, cursor: &cursor)
  if chunkIndex < 0 {
    return nil
  }

  if prepared.simpleLineWalkFastPath {
    return stepPreparedSimpleLineGeometry(prepared: prepared, cursor: &cursor, maxWidth: maxWidth)
  }

  return stepPreparedChunkLineGeometry(
    prepared: prepared, cursor: &cursor, chunkIndex: chunkIndex, maxWidth: maxWidth)
}

func measurePreparedLineGeometry(
  prepared: PreparedText,
  maxWidth: Double
) -> LineStats {
  guard prepared.segments.isEmpty == false else {
    return LineStats(lineCount: 0, maxLineWidth: 0)
  }

  var cursor = LayoutCursor.zero
  var lineCount = 0
  var maxLineWidth = 0.0

  if prepared.simpleLineWalkFastPath == false {
    var chunkIndex = normalizeLineStartChunkIndex(prepared: prepared, cursor: &cursor)
    while chunkIndex >= 0 {
      guard
        let lineWidth = stepPreparedChunkLineGeometry(
          prepared: prepared,
          cursor: &cursor,
          chunkIndex: chunkIndex,
          maxWidth: maxWidth
        )
      else {
        return LineStats(lineCount: lineCount, maxLineWidth: maxLineWidth)
      }
      lineCount += 1
      maxLineWidth = max(maxLineWidth, lineWidth)
      chunkIndex = normalizeLineStartChunkIndexFromHint(
        prepared: prepared, chunkIndex: chunkIndex, cursor: &cursor)
    }
    return LineStats(lineCount: lineCount, maxLineWidth: maxLineWidth)
  }

  while true {
    guard
      let lineWidth = stepPreparedLineGeometryValidated(
        prepared: prepared, cursor: &cursor, maxWidth: maxWidth)
    else {
      return LineStats(lineCount: lineCount, maxLineWidth: maxLineWidth)
    }
    lineCount += 1
    maxLineWidth = max(maxLineWidth, lineWidth)
  }
}
