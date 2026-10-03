import Foundation

func findChunkIndexForStart(
  prepared: PreparedText,
  segmentIndex: Int
) -> Int {
  var lowerBound = 0
  var upperBound = prepared.chunks.count

  while lowerBound < upperBound {
    let middle = (lowerBound + upperBound) / 2
    if segmentIndex < prepared.chunks[middle].consumedEndSegmentIndex {
      upperBound = middle
    } else {
      lowerBound = middle + 1
    }
  }

  return lowerBound < prepared.chunks.count ? lowerBound : -1
}

func normalizeLineStartInChunk(
  prepared: PreparedText,
  chunkIndex: Int,
  cursor: inout LayoutCursor
) -> Int {
  var segmentIndex = cursor.segmentIndex
  if cursor.graphemeIndex > 0 {
    return chunkIndex
  }

  let chunk = prepared.chunks[chunkIndex]
  if chunk.startSegmentIndex == chunk.endSegmentIndex,
    segmentIndex == chunk.startSegmentIndex
  {
    cursor.segmentIndex = segmentIndex
    cursor.graphemeIndex = 0
    return chunkIndex
  }

  if segmentIndex < chunk.startSegmentIndex {
    segmentIndex = chunk.startSegmentIndex
  }

  while segmentIndex < chunk.endSegmentIndex {
    if prepared.segments[segmentIndex].kind.trimsAtLineStart == false {
      cursor.segmentIndex = segmentIndex
      cursor.graphemeIndex = 0
      return chunkIndex
    }
    segmentIndex += 1
  }

  if chunk.consumedEndSegmentIndex >= prepared.segments.count {
    return -1
  }

  cursor.segmentIndex = chunk.consumedEndSegmentIndex
  cursor.graphemeIndex = 0
  return chunkIndex + 1
}

func normalizeLineStartChunkIndex(
  prepared: PreparedText,
  cursor: inout LayoutCursor
) -> Int {
  if cursor.segmentIndex >= prepared.segments.count {
    return -1
  }

  let chunkIndex = findChunkIndexForStart(prepared: prepared, segmentIndex: cursor.segmentIndex)
  if chunkIndex < 0 {
    return -1
  }
  return normalizeLineStartInChunk(prepared: prepared, chunkIndex: chunkIndex, cursor: &cursor)
}

func normalizeLineStartChunkIndexFromHint(
  prepared: PreparedText,
  chunkIndex: Int,
  cursor: inout LayoutCursor
) -> Int {
  if cursor.segmentIndex >= prepared.segments.count {
    return -1
  }
  guard chunkIndex >= 0, chunkIndex < prepared.chunks.count else {
    return normalizeLineStartChunkIndex(prepared: prepared, cursor: &cursor)
  }
  if cursor.segmentIndex < prepared.chunks[chunkIndex].startSegmentIndex {
    return normalizeLineStartChunkIndex(prepared: prepared, cursor: &cursor)
  }

  var nextChunkIndex = chunkIndex
  while nextChunkIndex < prepared.chunks.count
    && cursor.segmentIndex >= prepared.chunks[nextChunkIndex].consumedEndSegmentIndex
  {
    nextChunkIndex += 1
  }

  if nextChunkIndex >= prepared.chunks.count {
    return -1
  }

  return normalizeLineStartInChunk(prepared: prepared, chunkIndex: nextChunkIndex, cursor: &cursor)
}

func findChunkIndexForStartFromHint(
  prepared: PreparedText,
  chunkIndex: Int,
  segmentIndex: Int
) -> Int {
  // Continuation fragments intentionally skip line-start normalization so their
  // leading whitespace remains materialized. The caller supplies a nondecreasing
  // chunk hint, so this walk only advances through already-consumed chunks.
  guard segmentIndex >= 0, segmentIndex < prepared.segments.count else {
    return -1
  }
  guard chunkIndex >= 0, chunkIndex < prepared.chunks.count else {
    return findChunkIndexForStart(prepared: prepared, segmentIndex: segmentIndex)
  }
  if segmentIndex < prepared.chunks[chunkIndex].startSegmentIndex {
    return findChunkIndexForStart(prepared: prepared, segmentIndex: segmentIndex)
  }

  var nextChunkIndex = chunkIndex
  while nextChunkIndex < prepared.chunks.count
    && segmentIndex >= prepared.chunks[nextChunkIndex].consumedEndSegmentIndex
  {
    nextChunkIndex += 1
  }

  return nextChunkIndex < prepared.chunks.count ? nextChunkIndex : -1
}

func chunkEndsWithHardBreak(_ chunk: PreparedChunk) -> Bool {
  chunk.endSegmentIndex < chunk.consumedEndSegmentIndex
}
