import Foundation

func stepPreparedChunkLineGeometry(
  prepared: PreparedText,
  cursor: inout LayoutCursor,
  chunkIndex: Int,
  maxWidth: Double
) -> Double? {
  let chunk = prepared.chunks[chunkIndex]
  if chunk.startSegmentIndex == chunk.endSegmentIndex {
    cursor.segmentIndex = chunk.consumedEndSegmentIndex
    cursor.graphemeIndex = 0
    return 0
  }

  let segments = prepared.segments
  var state = LineGeometryState(cursor: cursor)

  func updatePendingBreakForWholeSegment(
    kind: SegmentBreakKind,
    breakAfter: Bool,
    segmentIndex: Int,
    segmentWidth: Double
  ) {
    guard breakAfter else { return }
    let segment = segments[segmentIndex]
    let fitAdvance = kind == .tab ? 0.0 : segment.lineEndFitAdvance
    let paintAdvance = kind == .tab ? segmentWidth : segment.lineEndPaintAdvance
    state.pendingBreakSegmentIndex = segmentIndex + 1
    state.pendingBreakFitWidth = state.lineWidth - segmentWidth + fitAdvance
    state.pendingBreakPaintWidth = state.lineWidth - segmentWidth + paintAdvance
    state.pendingBreakKind = kind
  }

  func maybeFinishAtSoftHyphen(_ segmentIndex: Int) -> Double? {
    guard state.pendingBreakKind == .softHyphen, state.pendingBreakSegmentIndex >= 0 else {
      return nil
    }

    if let fitWidths = segments[segmentIndex].breakableAdvances {
      let result = fitSoftHyphenBreak(
        graphemeFitAdvances: fitWidths,
        initialWidth: state.lineWidth,
        maxWidth: maxWidth,
        lineFitEpsilon: prepared.profile.lineFitEpsilon,
        discretionaryHyphenWidth: prepared.discretionaryHyphenWidth
      )

      if result.fitCount == fitWidths.count {
        state.lineWidth = result.fittedWidth
        state.lineEndSegmentIndex = segmentIndex + 1
        state.lineEndGraphemeIndex = 0
        state.clearPendingBreak()
        return nil
      }

      if result.fitCount > 0 {
        return state.finishLine(
          cursor: &cursor,
          endSegmentIndex: segmentIndex,
          endGraphemeIndex: result.fitCount,
          width: result.fittedWidth + prepared.discretionaryHyphenWidth
        )
      }
    }

    if LineFitKernel.fitsPrevalidated(
      currentWidth: 0, additionalAdvance: state.pendingBreakFitWidth, maximumWidth: maxWidth,
      tolerance: prepared.profile.lineFitEpsilon)
    {
      return state.finishLine(
        cursor: &cursor,
        endSegmentIndex: state.pendingBreakSegmentIndex,
        endGraphemeIndex: 0,
        width: state.pendingBreakPaintWidth
      )
    }

    return nil
  }

  for segmentIndex in cursor.segmentIndex..<chunk.endSegmentIndex {
    let segment = segments[segmentIndex]
    let kind = segment.kind
    let breakAfter = kind.breaksAfter
    let startGraphemeIndex = segmentIndex == cursor.segmentIndex ? cursor.graphemeIndex : 0
    let width =
      kind == .tab
      ? getTabAdvance(lineWidth: state.lineWidth, tabStopAdvance: prepared.tabStopAdvance)
      : segment.width

    if kind == .softHyphen && startGraphemeIndex == 0 {
      if state.hasContent {
        state.lineEndSegmentIndex = segmentIndex + 1
        state.lineEndGraphemeIndex = 0
        state.pendingBreakSegmentIndex = segmentIndex + 1
        state.pendingBreakFitWidth = state.lineWidth + prepared.discretionaryHyphenWidth
        state.pendingBreakPaintWidth = state.lineWidth + prepared.discretionaryHyphenWidth
        state.pendingBreakKind = kind
      }
      continue
    }

    if state.hasContent == false {
      if startGraphemeIndex > 0 {
        if let fitAdvances = segment.breakableAdvances,
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
      } else if !LineFitKernel.fitsPrevalidated(
        currentWidth: 0, additionalAdvance: width, maximumWidth: maxWidth, tolerance: 0),
        let fitAdvances = segment.breakableAdvances
      {
        if let line = state.appendBreakableSegmentFrom(
          fitAdvances: fitAdvances,
          segmentIndex: segmentIndex,
          startGraphemeIndex: 0,
          maximumWidth: maxWidth,
          tolerance: prepared.profile.lineFitEpsilon,
          cursor: &cursor
        ) {
          return line
        }
      } else {
        state.startLineAtSegment(segmentIndex, width: width)
      }

      updatePendingBreakForWholeSegment(
        kind: kind,
        breakAfter: breakAfter,
        segmentIndex: segmentIndex,
        segmentWidth: width
      )
      continue
    }

    if !LineFitKernel.fitsPrevalidated(
      currentWidth: state.lineWidth,
      additionalAdvance: width,
      maximumWidth: maxWidth,
      tolerance: prepared.profile.lineFitEpsilon
    ) {
      let currentBreakFitWidth = state.lineWidth + (kind == .tab ? 0.0 : segment.lineEndFitAdvance)
      let currentBreakPaintWidth =
        state.lineWidth + (kind == .tab ? width : segment.lineEndPaintAdvance)

      if state.pendingBreakKind == .softHyphen,
        prepared.profile.preferEarlySoftHyphenBreak,
        LineFitKernel.fitsPrevalidated(
          currentWidth: 0, additionalAdvance: state.pendingBreakFitWidth, maximumWidth: maxWidth,
          tolerance: prepared.profile.lineFitEpsilon)
      {
        return state.finishLine(
          cursor: &cursor,
          endSegmentIndex: state.pendingBreakSegmentIndex,
          endGraphemeIndex: 0,
          width: state.pendingBreakPaintWidth
        )
      }

      if let softBreakLine = maybeFinishAtSoftHyphen(segmentIndex) {
        return softBreakLine
      }

      if breakAfter
        && LineFitKernel.fitsPrevalidated(
          currentWidth: 0, additionalAdvance: currentBreakFitWidth, maximumWidth: maxWidth,
          tolerance: prepared.profile.lineFitEpsilon)
      {
        state.appendWholeSegment(segmentIndex, width: width)
        return state.finishLine(
          cursor: &cursor,
          endSegmentIndex: segmentIndex + 1,
          endGraphemeIndex: 0,
          width: currentBreakPaintWidth
        )
      }

      if state.pendingBreakSegmentIndex >= 0
        && LineFitKernel.fitsPrevalidated(
          currentWidth: 0, additionalAdvance: state.pendingBreakFitWidth, maximumWidth: maxWidth,
          tolerance: prepared.profile.lineFitEpsilon)
      {
        if state.lineEndSegmentIndex > state.pendingBreakSegmentIndex
          || (state.lineEndSegmentIndex == state.pendingBreakSegmentIndex
            && state.lineEndGraphemeIndex > 0)
        {
          return state.finishLine(cursor: &cursor)
        }
        return state.finishLine(
          cursor: &cursor,
          endSegmentIndex: state.pendingBreakSegmentIndex,
          endGraphemeIndex: 0,
          width: state.pendingBreakPaintWidth
        )
      }

      if !LineFitKernel.fitsPrevalidated(
        currentWidth: 0, additionalAdvance: width, maximumWidth: maxWidth, tolerance: 0)
        && segment.breakableAdvances != nil
      {
        if let currentLine = state.finishLine(cursor: &cursor) {
          return currentLine
        }
        if let fitAdvances = segment.breakableAdvances,
          let line = state.appendBreakableSegmentFrom(
            fitAdvances: fitAdvances,
            segmentIndex: segmentIndex,
            startGraphemeIndex: 0,
            maximumWidth: maxWidth,
            tolerance: prepared.profile.lineFitEpsilon,
            cursor: &cursor
          )
        {
          return line
        }
      }

      return state.finishLine(cursor: &cursor)
    }

    state.appendWholeSegment(segmentIndex, width: width)
    updatePendingBreakForWholeSegment(
      kind: kind,
      breakAfter: breakAfter,
      segmentIndex: segmentIndex,
      segmentWidth: width
    )
  }

  if state.pendingBreakSegmentIndex == chunk.consumedEndSegmentIndex
    && state.lineEndGraphemeIndex == 0
  {
    return state.finishLine(
      cursor: &cursor,
      endSegmentIndex: chunk.consumedEndSegmentIndex,
      endGraphemeIndex: 0,
      width: state.pendingBreakPaintWidth
    )
  }

  return state.finishLine(
    cursor: &cursor,
    endSegmentIndex: chunk.consumedEndSegmentIndex,
    endGraphemeIndex: 0,
    width: state.lineWidth
  )
}
