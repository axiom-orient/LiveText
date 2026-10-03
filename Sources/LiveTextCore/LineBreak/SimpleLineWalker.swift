import Foundation

func walkPreparedLinesSimple(
  prepared: PreparedText,
  maxWidth: Double,
  onLine: ((Double, Int, Int, Int, Int) -> Void)? = nil
) -> Int {
  let segments = prepared.segments
  guard segments.isEmpty == false else { return 0 }

  var state = RawLineWalkState(startSegmentIndex: 0)

  var segmentIndex = 0
  while segmentIndex < segments.count {
    if state.hasContent == false {
      segmentIndex = normalizeSimpleLineStartSegmentIndex(
        prepared: prepared, segmentIndex: segmentIndex)
      if segmentIndex >= segments.count {
        break
      }
    }

    let segment = segments[segmentIndex]
    let width = segment.width
    let breakAfter = segment.kind.breaksAfter

    if state.hasContent == false {
      if !LineFitKernel.fitsPrevalidated(
        currentWidth: 0, additionalAdvance: width, maximumWidth: maxWidth, tolerance: 0)
        && segment.breakableAdvances != nil
      {
        state.appendBreakableSegmentFrom(
          fitAdvances: segment.breakableAdvances ?? [],
          segmentIndex: segmentIndex,
          startGraphemeIndex: 0,
          maximumWidth: maxWidth,
          tolerance: prepared.profile.lineFitEpsilon,
          onLine: onLine
        )
      } else {
        state.startLineAtSegment(segmentIndex, width: width)
      }

      if breakAfter {
        state.pendingBreakSegmentIndex = segmentIndex + 1
        state.pendingBreakPaintWidth = state.lineWidth - width
      }

      segmentIndex += 1
      continue
    }

    if !LineFitKernel.fitsPrevalidated(
      currentWidth: state.lineWidth,
      additionalAdvance: width,
      maximumWidth: maxWidth,
      tolerance: prepared.profile.lineFitEpsilon
    ) {
      if breakAfter {
        state.appendWholeSegment(segmentIndex, width: width)
        state.emitCurrentLine(
          onLine: onLine,
          endSegmentIndex: segmentIndex + 1,
          endGraphemeIndex: 0,
          width: state.lineWidth - width
        )
        segmentIndex += 1
        continue
      }

      if state.pendingBreakSegmentIndex >= 0 {
        if state.lineEndSegmentIndex > state.pendingBreakSegmentIndex
          || (state.lineEndSegmentIndex == state.pendingBreakSegmentIndex
            && state.lineEndGraphemeIndex > 0)
        {
          state.emitCurrentLine(onLine: onLine)
          continue
        }

        state.emitCurrentLine(
          onLine: onLine,
          endSegmentIndex: state.pendingBreakSegmentIndex,
          endGraphemeIndex: 0,
          width: state.pendingBreakPaintWidth
        )
        continue
      }

      if !LineFitKernel.fitsPrevalidated(
        currentWidth: 0, additionalAdvance: width, maximumWidth: maxWidth, tolerance: 0)
        && segment.breakableAdvances != nil
      {
        state.emitCurrentLine(onLine: onLine)
        state.appendBreakableSegmentFrom(
          fitAdvances: segment.breakableAdvances ?? [],
          segmentIndex: segmentIndex,
          startGraphemeIndex: 0,
          maximumWidth: maxWidth,
          tolerance: prepared.profile.lineFitEpsilon,
          onLine: onLine
        )
        segmentIndex += 1
        continue
      }

      state.emitCurrentLine(onLine: onLine)
      continue
    }

    state.appendWholeSegment(segmentIndex, width: width)
    if breakAfter {
      state.pendingBreakSegmentIndex = segmentIndex + 1
      state.pendingBreakPaintWidth = state.lineWidth - width
    }
    segmentIndex += 1
  }

  if state.hasContent {
    state.emitCurrentLine(onLine: onLine)
  }

  return state.lineCount
}

func stepPreparedSimpleLineGeometry(
  prepared: PreparedText,
  cursor: inout LayoutCursor,
  maxWidth: Double
) -> Double? {
  let segments = prepared.segments

  var state = LineGeometryState(cursor: cursor)

  for segmentIndex in cursor.segmentIndex..<segments.count {
    let segment = segments[segmentIndex]
    let width = segment.width
    let kind = segment.kind
    let breakAfter = kind.breaksAfter
    let startGraphemeIndex = segmentIndex == cursor.segmentIndex ? cursor.graphemeIndex : 0
    let breakableAdvances = segment.breakableAdvances

    if state.hasContent == false {
      if startGraphemeIndex > 0
        || (!LineFitKernel.fitsPrevalidated(
          currentWidth: 0, additionalAdvance: width, maximumWidth: maxWidth, tolerance: 0)
          && breakableAdvances != nil)
      {
        if let fitAdvances = breakableAdvances,
          let line = state.appendBreakableSegmentFrom(
            fitAdvances: fitAdvances,
            segmentIndex: segmentIndex,
            startGraphemeIndex: startGraphemeIndex,
            maximumWidth: maxWidth,
            tolerance: prepared.profile.lineFitEpsilon,
            cursor: &cursor
          )
        {
          return line
        }
      } else {
        state.startLineAtSegment(segmentIndex, width: width)
      }

      if breakAfter {
        state.pendingBreakSegmentIndex = segmentIndex + 1
        state.pendingBreakPaintWidth = state.lineWidth - width
      }
      continue
    }

    if !LineFitKernel.fitsPrevalidated(
      currentWidth: state.lineWidth,
      additionalAdvance: width,
      maximumWidth: maxWidth,
      tolerance: prepared.profile.lineFitEpsilon
    ) {
      if breakAfter {
        cursor.segmentIndex = segmentIndex + 1
        cursor.graphemeIndex = 0
        return state.lineWidth
      }

      if state.pendingBreakSegmentIndex >= 0 {
        if state.lineEndSegmentIndex > state.pendingBreakSegmentIndex
          || (state.lineEndSegmentIndex == state.pendingBreakSegmentIndex
            && state.lineEndGraphemeIndex > 0)
        {
          return state.finishLine(cursor: &cursor)
        }

        cursor.segmentIndex = state.pendingBreakSegmentIndex
        cursor.graphemeIndex = 0
        return state.pendingBreakPaintWidth
      }

      return state.finishLine(cursor: &cursor)
    }

    state.appendWholeSegment(segmentIndex, width: width)
    if breakAfter {
      state.pendingBreakSegmentIndex = segmentIndex + 1
      state.pendingBreakPaintWidth = state.lineWidth - width
    }
  }

  return state.finishLine(cursor: &cursor)
}
