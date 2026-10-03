import Foundation

func normalizeSimpleLineStartSegmentIndex(
  prepared: PreparedText,
  segmentIndex: Int
) -> Int {
  var segmentIndex = segmentIndex
  while segmentIndex < prepared.segments.count {
    let kind = prepared.segments[segmentIndex].kind
    if kind.trimsAtLineStart == false {
      break
    }
    segmentIndex += 1
  }
  return segmentIndex
}

func consumeOnlyLineStartTrimmableSegments(
  prepared: PreparedText,
  cursor: inout LayoutCursor
) -> Bool {
  guard cursor.graphemeIndex == 0 else { return false }

  var segmentIndex = cursor.segmentIndex
  while segmentIndex < prepared.segments.count {
    guard prepared.segments[segmentIndex].kind.trimsAtLineStart else {
      return false
    }
    segmentIndex += 1
  }

  guard segmentIndex > cursor.segmentIndex else { return false }
  cursor = LayoutCursor(segmentIndex: segmentIndex, graphemeIndex: 0)
  return true
}

func getTabAdvance(lineWidth: Double, tabStopAdvance: Double) -> Double {
  guard tabStopAdvance > 0 else { return 0 }
  let remainder = lineWidth.truncatingRemainder(dividingBy: tabStopAdvance)
  if abs(remainder) <= 1e-6 {
    return tabStopAdvance
  }
  return tabStopAdvance - remainder
}

func fitSoftHyphenBreak(
  graphemeFitAdvances: [Double],
  initialWidth: Double,
  maxWidth: Double,
  lineFitEpsilon: Double,
  discretionaryHyphenWidth: Double
) -> (fitCount: Int, fittedWidth: Double) {
  var fitCount = 0
  var fittedWidth = initialWidth

  while fitCount < graphemeFitAdvances.count {
    let nextWidth = fittedWidth + graphemeFitAdvances[fitCount]
    let nextLineWidth =
      fitCount + 1 < graphemeFitAdvances.count
      ? nextWidth + discretionaryHyphenWidth
      : nextWidth
    if !LineFitKernel.fitsPrevalidated(
      currentWidth: 0,
      additionalAdvance: nextLineWidth,
      maximumWidth: maxWidth,
      tolerance: lineFitEpsilon
    ) {
      break
    }
    fittedWidth = nextWidth
    fitCount += 1
  }

  return (fitCount, fittedWidth)
}
