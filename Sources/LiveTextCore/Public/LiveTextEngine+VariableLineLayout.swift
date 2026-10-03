import Foundation

extension LiveTextEngine {
  /// Lays out one fragment per visual line using caller-provided per-line constraints.
  public func layoutWithVariableLineConstraints(
    prepared: PreparedText,
    lineHeight: Double,
    continuation: VariableLayoutContinuation? = nil,
    constraintProvider: (_ lineIndex: Int, _ lineOriginY: Double, _ cursor: LayoutCursor) ->
      VariableLineFragmentConstraint?
  ) throws -> VariableLayoutResult {
    try validate(lineHeight: lineHeight)
    var lines: [VariableLayoutLine] = []
    var materializer = LineTextMaterializer(prepared: prepared)
    let start = try resolveVariableLayoutStart(prepared: prepared, continuation: continuation)
    var cursor = start.cursor
    var chunkIndexHint: Int?
    var lineIndex = start.index
    var maxLineWidth = 0.0

    while cursor.segmentIndex < prepared.segments.count {
      let lineOriginY = try validatedVerticalOrigin(
        index: lineIndex, lineHeight: lineHeight, context: "variable line"
      )
      guard let constraint = constraintProvider(lineIndex, lineOriginY, cursor) else {
        break
      }

      try validate(maxWidth: constraint.maxWidth)
      try validateHorizontalExtent(
        originX: constraint.originX,
        width: constraint.maxWidth,
        context: "variable line"
      )
      guard
        let range = layoutNextFragmentRangeValidatedWithHint(
          prepared: prepared,
          end: &cursor,
          maxWidth: constraint.maxWidth,
          isFirstFragmentInRow: true,
          chunkIndexHint: &chunkIndexHint
        )
      else {
        if consumeOnlyLineStartTrimmableSegments(prepared: prepared, cursor: &cursor) {
          break
        }
        throw LiveTextCoreError.invalidFragmentConfiguration(
          "line \(lineIndex) did not advance while text remains"
        )
      }

      let start = range.start
      let end = range.end
      lines.append(
        VariableLayoutLine(
          text: materializer.build(start: start, end: end),
          width: range.width,
          start: start,
          end: end,
          originX: constraint.originX,
          originY: lineOriginY
        )
      )
      maxLineWidth = max(maxLineWidth, range.width)
      cursor = end
      lineIndex = try incrementedLayoutIndex(lineIndex, context: "variable line")
    }

    let nextContinuation =
      cursor.segmentIndex < prepared.segments.count
      ? VariableLayoutContinuation(cursor: cursor, nextIndex: lineIndex)
      : nil

    return VariableLayoutResult(
      lineCount: lines.count,
      height: try validatedLayoutHeight(
        count: lines.count, lineHeight: lineHeight, context: "variable line layout"
      ),
      maxLineWidth: maxLineWidth,
      lines: lines,
      continuation: nextContinuation
    )
  }
}
