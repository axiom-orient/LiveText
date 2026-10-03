import Foundation

struct RawLineWalkState {
  var lineCount: Int
  var lineWidth: Double
  var hasContent: Bool
  var lineStartSegmentIndex: Int
  var lineStartGraphemeIndex: Int
  var lineEndSegmentIndex: Int
  var lineEndGraphemeIndex: Int
  var pendingBreakSegmentIndex: Int
  var pendingBreakFitWidth: Double
  var pendingBreakPaintWidth: Double
  var pendingBreakKind: SegmentBreakKind?

  init(startSegmentIndex: Int, startGraphemeIndex: Int = 0) {
    lineCount = 0
    lineWidth = 0
    hasContent = false
    lineStartSegmentIndex = startSegmentIndex
    lineStartGraphemeIndex = startGraphemeIndex
    lineEndSegmentIndex = startSegmentIndex
    lineEndGraphemeIndex = startGraphemeIndex
    pendingBreakSegmentIndex = -1
    pendingBreakFitWidth = 0
    pendingBreakPaintWidth = 0
    pendingBreakKind = nil
  }

  mutating func clearPendingBreak() {
    pendingBreakSegmentIndex = -1
    pendingBreakFitWidth = 0
    pendingBreakPaintWidth = 0
    pendingBreakKind = nil
  }

  mutating func emitCurrentLine(
    onLine: ((Double, Int, Int, Int, Int) -> Void)?,
    endSegmentIndex: Int? = nil,
    endGraphemeIndex: Int? = nil,
    width: Double? = nil
  ) {
    lineCount += 1
    onLine?(
      width ?? lineWidth,
      lineStartSegmentIndex,
      lineStartGraphemeIndex,
      endSegmentIndex ?? lineEndSegmentIndex,
      endGraphemeIndex ?? lineEndGraphemeIndex
    )
    lineWidth = 0
    hasContent = false
    clearPendingBreak()
  }

  mutating func startLineAtSegment(_ segmentIndex: Int, width: Double) {
    hasContent = true
    lineStartSegmentIndex = segmentIndex
    lineStartGraphemeIndex = 0
    lineEndSegmentIndex = segmentIndex + 1
    lineEndGraphemeIndex = 0
    lineWidth = width
  }

  mutating func startLineAtGrapheme(_ segmentIndex: Int, graphemeIndex: Int, width: Double) {
    hasContent = true
    lineStartSegmentIndex = segmentIndex
    lineStartGraphemeIndex = graphemeIndex
    lineEndSegmentIndex = segmentIndex
    lineEndGraphemeIndex = graphemeIndex + 1
    lineWidth = width
  }

  mutating func appendWholeSegment(_ segmentIndex: Int, width: Double) {
    if hasContent == false {
      startLineAtSegment(segmentIndex, width: width)
      return
    }
    lineWidth += width
    lineEndSegmentIndex = segmentIndex + 1
    lineEndGraphemeIndex = 0
  }

  mutating func appendBreakableSegmentFrom(
    fitAdvances: [Double],
    segmentIndex: Int,
    startGraphemeIndex: Int,
    maximumWidth: Double,
    tolerance: Double,
    onLine: ((Double, Int, Int, Int, Int) -> Void)?
  ) {
    for graphemeIndex in startGraphemeIndex..<fitAdvances.count {
      let graphemeWidth = fitAdvances[graphemeIndex]
      if hasContent == false {
        startLineAtGrapheme(segmentIndex, graphemeIndex: graphemeIndex, width: graphemeWidth)
      } else if !LineFitKernel.fitsPrevalidated(
        currentWidth: lineWidth,
        additionalAdvance: graphemeWidth,
        maximumWidth: maximumWidth,
        tolerance: tolerance
      ) {
        emitCurrentLine(onLine: onLine)
        startLineAtGrapheme(segmentIndex, graphemeIndex: graphemeIndex, width: graphemeWidth)
      } else {
        lineWidth += graphemeWidth
        lineEndSegmentIndex = segmentIndex
        lineEndGraphemeIndex = graphemeIndex + 1
      }
    }

    if hasContent && lineEndSegmentIndex == segmentIndex
      && lineEndGraphemeIndex == fitAdvances.count
    {
      lineEndSegmentIndex = segmentIndex + 1
      lineEndGraphemeIndex = 0
    }
  }
}
