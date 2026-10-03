import Foundation

struct LineGeometryState {
  var lineWidth: Double
  var hasContent: Bool
  var lineEndSegmentIndex: Int
  var lineEndGraphemeIndex: Int
  var pendingBreakSegmentIndex: Int
  var pendingBreakFitWidth: Double
  var pendingBreakPaintWidth: Double
  var pendingBreakKind: SegmentBreakKind?

  init(cursor: LayoutCursor) {
    lineWidth = 0
    hasContent = false
    lineEndSegmentIndex = cursor.segmentIndex
    lineEndGraphemeIndex = cursor.graphemeIndex
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

  mutating func finishLine(
    cursor: inout LayoutCursor,
    endSegmentIndex: Int? = nil,
    endGraphemeIndex: Int? = nil,
    width: Double? = nil
  ) -> Double? {
    guard hasContent else { return nil }
    cursor.segmentIndex = endSegmentIndex ?? lineEndSegmentIndex
    cursor.graphemeIndex = endGraphemeIndex ?? lineEndGraphemeIndex
    return width ?? lineWidth
  }

  mutating func startLineAtSegment(_ segmentIndex: Int, width: Double) {
    hasContent = true
    lineEndSegmentIndex = segmentIndex + 1
    lineEndGraphemeIndex = 0
    lineWidth = width
  }

  mutating func startLineAtGrapheme(_ segmentIndex: Int, graphemeIndex: Int, width: Double) {
    hasContent = true
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
    cursor: inout LayoutCursor
  ) -> Double? {
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
        return finishLine(cursor: &cursor)
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

    return nil
  }
}
