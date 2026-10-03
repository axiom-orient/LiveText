import Foundation

func walkPreparedLinesRaw(
  prepared: PreparedText,
  maxWidth: Double,
  onLine: ((Double, Int, Int, Int, Int) -> Void)? = nil
) -> Int {
  if prepared.simpleLineWalkFastPath {
    return walkPreparedLinesSimple(prepared: prepared, maxWidth: maxWidth, onLine: onLine)
  }

  let segments = prepared.segments
  guard segments.isEmpty == false, prepared.chunks.isEmpty == false else { return 0 }

  var totalLineCount = 0
  var state = RawLineWalkState(startSegmentIndex: 0)

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

  func continueSoftHyphenBreakableSegment(_ segmentIndex: Int) -> Bool {
    guard state.pendingBreakKind == .softHyphen,
      let fitWidths = segments[segmentIndex].breakableAdvances
    else {
      return false
    }

    let result = fitSoftHyphenBreak(
      graphemeFitAdvances: fitWidths,
      initialWidth: state.lineWidth,
      maxWidth: maxWidth,
      lineFitEpsilon: prepared.profile.lineFitEpsilon,
      discretionaryHyphenWidth: prepared.discretionaryHyphenWidth
    )

    if result.fitCount == 0 {
      return false
    }

    state.lineWidth = result.fittedWidth
    state.lineEndSegmentIndex = segmentIndex
    state.lineEndGraphemeIndex = result.fitCount
    state.clearPendingBreak()

    if result.fitCount == fitWidths.count {
      state.lineEndSegmentIndex = segmentIndex + 1
      state.lineEndGraphemeIndex = 0
      return true
    }

    state.emitCurrentLine(
      onLine: onLine,
      endSegmentIndex: segmentIndex,
      endGraphemeIndex: result.fitCount,
      width: result.fittedWidth + prepared.discretionaryHyphenWidth
    )
    state.appendBreakableSegmentFrom(
      fitAdvances: fitWidths,
      segmentIndex: segmentIndex,
      startGraphemeIndex: result.fitCount,
      maximumWidth: maxWidth,
      tolerance: prepared.profile.lineFitEpsilon,
      onLine: onLine
    )
    return true
  }

  func emitEmptyChunk(_ chunk: PreparedChunk) {
    totalLineCount += 1
    onLine?(0, chunk.startSegmentIndex, 0, chunk.consumedEndSegmentIndex, 0)
    state.clearPendingBreak()
  }

  for chunk in prepared.chunks {
    if chunk.startSegmentIndex == chunk.endSegmentIndex {
      emitEmptyChunk(chunk)
      continue
    }

    state = RawLineWalkState(startSegmentIndex: chunk.startSegmentIndex)

    var segmentIndex = chunk.startSegmentIndex
    while segmentIndex < chunk.endSegmentIndex {
      let segment = segments[segmentIndex]
      let kind = segment.kind
      let breakAfter = kind.breaksAfter
      let width =
        kind == .tab
        ? getTabAdvance(lineWidth: state.lineWidth, tabStopAdvance: prepared.tabStopAdvance)
        : segment.width

      if kind == .softHyphen {
        if state.hasContent {
          state.lineEndSegmentIndex = segmentIndex + 1
          state.lineEndGraphemeIndex = 0
          state.pendingBreakSegmentIndex = segmentIndex + 1
          state.pendingBreakFitWidth = state.lineWidth + prepared.discretionaryHyphenWidth
          state.pendingBreakPaintWidth = state.lineWidth + prepared.discretionaryHyphenWidth
          state.pendingBreakKind = kind
        }
        segmentIndex += 1
        continue
      }

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
        updatePendingBreakForWholeSegment(
          kind: kind,
          breakAfter: breakAfter,
          segmentIndex: segmentIndex,
          segmentWidth: width
        )
        segmentIndex += 1
        continue
      }

      if !LineFitKernel.fitsPrevalidated(
        currentWidth: state.lineWidth,
        additionalAdvance: width,
        maximumWidth: maxWidth,
        tolerance: prepared.profile.lineFitEpsilon
      ) {
        let currentBreakFitWidth =
          state.lineWidth + (kind == .tab ? 0.0 : segment.lineEndFitAdvance)
        let currentBreakPaintWidth =
          state.lineWidth + (kind == .tab ? width : segment.lineEndPaintAdvance)

        if state.pendingBreakKind == .softHyphen,
          prepared.profile.preferEarlySoftHyphenBreak,
          LineFitKernel.fitsPrevalidated(
            currentWidth: 0, additionalAdvance: state.pendingBreakFitWidth, maximumWidth: maxWidth,
            tolerance: prepared.profile.lineFitEpsilon)
        {
          state.emitCurrentLine(
            onLine: onLine,
            endSegmentIndex: state.pendingBreakSegmentIndex,
            endGraphemeIndex: 0,
            width: state.pendingBreakPaintWidth
          )
          continue
        }

        if state.pendingBreakKind == .softHyphen && continueSoftHyphenBreakableSegment(segmentIndex)
        {
          segmentIndex += 1
          continue
        }

        if breakAfter
          && LineFitKernel.fitsPrevalidated(
            currentWidth: 0, additionalAdvance: currentBreakFitWidth, maximumWidth: maxWidth,
            tolerance: prepared.profile.lineFitEpsilon)
        {
          state.appendWholeSegment(segmentIndex, width: width)
          state.emitCurrentLine(
            onLine: onLine,
            endSegmentIndex: segmentIndex + 1,
            endGraphemeIndex: 0,
            width: currentBreakPaintWidth
          )
          segmentIndex += 1
          continue
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
            state.emitCurrentLine(onLine: onLine)
            continue
          }

          let nextSegmentIndex = state.pendingBreakSegmentIndex
          state.emitCurrentLine(
            onLine: onLine,
            endSegmentIndex: nextSegmentIndex,
            endGraphemeIndex: 0,
            width: state.pendingBreakPaintWidth
          )
          segmentIndex = nextSegmentIndex
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
      updatePendingBreakForWholeSegment(
        kind: kind,
        breakAfter: breakAfter,
        segmentIndex: segmentIndex,
        segmentWidth: width
      )
      segmentIndex += 1
    }

    if state.hasContent {
      let finalPaintWidth =
        state.pendingBreakSegmentIndex == chunk.consumedEndSegmentIndex
        ? state.pendingBreakPaintWidth
        : state.lineWidth
      state.emitCurrentLine(
        onLine: onLine,
        endSegmentIndex: chunk.consumedEndSegmentIndex,
        endGraphemeIndex: 0,
        width: finalPaintWidth
      )
      totalLineCount += state.lineCount
    }
  }

  return totalLineCount
}
