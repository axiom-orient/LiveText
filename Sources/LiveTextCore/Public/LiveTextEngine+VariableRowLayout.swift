import Foundation

extension LiveTextEngine {
  /// Lays out rows that may contain multiple horizontal fragments, such as obstacle-aware columns.
  ///
  /// Returning `nil` from `fragmentProvider` stops layout. Returning an empty fragment array
  /// stops only when all text has been consumed; otherwise it throws `LiveTextCoreError.invalidFragmentConfiguration`.
  public func layoutWithVariableRowFragments(
    prepared: PreparedText,
    lineHeight: Double,
    continuation: VariableLayoutContinuation? = nil,
    fragmentProvider: (_ rowIndex: Int, _ rowOriginY: Double, _ cursor: LayoutCursor) ->
      [VariableLineFragmentConstraint]?
  ) throws -> VariableLayoutRowsResult {
    try validate(lineHeight: lineHeight)
    var rows: [VariableLayoutRow] = []
    var materializer = LineTextMaterializer(prepared: prepared)
    let start = try resolveVariableLayoutStart(prepared: prepared, continuation: continuation)
    var cursor = start.cursor
    var chunkIndexHint: Int?
    var rowIndex = start.index
    var maxRowWidth = 0.0

    while cursor.segmentIndex < prepared.segments.count
      || (prepared.segments.isEmpty && continuation == nil)
    {
      let rowOriginY = try validatedVerticalOrigin(
        index: rowIndex, lineHeight: lineHeight, context: "variable row"
      )
      guard let fragmentConstraints = fragmentProvider(rowIndex, rowOriginY, cursor) else {
        break
      }

      if fragmentConstraints.isEmpty {
        if cursor.segmentIndex >= prepared.segments.count {
          break
        }
        throw LiveTextCoreError.invalidFragmentConfiguration(
          "row \(rowIndex) must provide at least one fragment while text remains")
      }

      if cursor.segmentIndex >= prepared.segments.count {
        throw LiveTextCoreError.invalidFragmentConfiguration(
          "row \(rowIndex) first fragment does not advance the cursor"
        )
      }

      let rowStart = cursor
      var rowFragments: [VariableLayoutFragment] = []
      var rowVisualWidth = 0.0

      for (fragmentIndex, constraint) in fragmentConstraints.enumerated() {
        if constraint.maxWidth.isFinite == false || constraint.maxWidth <= 0 {
          throw LiveTextCoreError.invalidFragmentConfiguration(
            "row \(rowIndex) fragment \(fragmentIndex) must have positive maxWidth"
          )
        }
        try validateHorizontalExtent(
          originX: constraint.originX,
          width: constraint.maxWidth,
          context: "row \(rowIndex) fragment \(fragmentIndex)"
        )
        let previousCursor = cursor
        guard
          let range = layoutNextFragmentRangeValidatedWithHint(
            prepared: prepared,
            end: &cursor,
            maxWidth: constraint.maxWidth,
            isFirstFragmentInRow: fragmentIndex == 0,
            chunkIndexHint: &chunkIndexHint
          )
        else {
          if fragmentIndex == 0 {
            if consumeOnlyLineStartTrimmableSegments(prepared: prepared, cursor: &cursor) {
              break
            }
            throw LiveTextCoreError.invalidFragmentConfiguration(
              "row \(rowIndex) first fragment does not advance the cursor")
          }
          if cursor.segmentIndex < prepared.segments.count {
            throw LiveTextCoreError.invalidFragmentConfiguration(
              "row \(rowIndex) fragment \(fragmentIndex) did not advance while text remains"
            )
          }
          break
        }

        if range.end == previousCursor {
          throw LiveTextCoreError.invalidFragmentConfiguration(
            "row \(rowIndex) fragment \(fragmentIndex) does not advance the cursor")
        }

        let nextCursor =
          fragmentIndex + 1 < fragmentConstraints.count
          ? continuationFragmentCursor(prepared: prepared, range: range)
          : range.end
        let endsRowAtHardBreak =
          chunkIndexHint.map { chunkIndex in
            let chunk = prepared.chunks[chunkIndex]
            return chunkEndsWithHardBreak(chunk)
              && range.end.segmentIndex >= chunk.consumedEndSegmentIndex
              && range.end.graphemeIndex == 0
          } ?? false

        rowFragments.append(
          VariableLayoutFragment(
            text: materializer.build(start: range.start, end: range.end),
            width: range.width,
            start: range.start,
            end: range.end,
            originX: constraint.originX,
            originY: rowOriginY,
            rowIndex: rowIndex,
            fragmentIndex: fragmentIndex
          )
        )
        rowVisualWidth = max(rowVisualWidth, constraint.originX + range.width)
        cursor = nextCursor

        if endsRowAtHardBreak || cursor.segmentIndex >= prepared.segments.count {
          break
        }
      }

      if rowFragments.isEmpty {
        break
      }

      rows.append(
        VariableLayoutRow(
          originY: rowOriginY,
          start: rowStart,
          end: cursor,
          fragments: rowFragments,
          visualWidth: rowVisualWidth
        )
      )
      maxRowWidth = max(maxRowWidth, rowVisualWidth)
      rowIndex = try incrementedLayoutIndex(rowIndex, context: "variable row")

      if cursor.segmentIndex >= prepared.segments.count {
        break
      }
    }

    let nextContinuation =
      cursor.segmentIndex < prepared.segments.count
      ? VariableLayoutContinuation(cursor: cursor, nextIndex: rowIndex)
      : nil

    return VariableLayoutRowsResult(
      rowCount: rows.count,
      height: try validatedLayoutHeight(
        count: rows.count, lineHeight: lineHeight, context: "variable row layout"
      ),
      maxRowWidth: maxRowWidth,
      rows: rows,
      continuation: nextContinuation
    )
  }
}
