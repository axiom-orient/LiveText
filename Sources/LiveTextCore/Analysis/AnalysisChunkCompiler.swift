import Foundation

func mergeKeepAllTextSegments(_ segments: [AnalysisSegment]) -> [AnalysisSegment] {
  guard segments.count > 1 else { return segments }

  var result: [AnalysisSegment] = []
  result.reserveCapacity(segments.count)
  var pendingTextParts: [String]?
  var pendingWordLike = false
  var pendingStartUTF16 = 0
  var pendingContainsCJK = false
  var pendingCanContinue = false

  func flushPending() {
    guard let pendingTextParts else { return }
    result.append(
      AnalysisSegment(
        text: pendingTextParts.count == 1 ? pendingTextParts[0] : pendingTextParts.joined(),
        isWordLike: pendingWordLike,
        kind: .text,
        startUTF16: pendingStartUTF16
      )
    )
  }

  for segment in segments {
    if segment.kind == .text {
      let textContainsCJK = isCJK(segment.text)
      let textCanContinue = canContinueKeepAllTextRun(segment.text)

      if pendingContainsCJK, pendingCanContinue, pendingTextParts != nil {
        pendingTextParts?.append(segment.text)
        pendingWordLike = pendingWordLike || segment.isWordLike
        pendingContainsCJK = pendingContainsCJK || textContainsCJK
        pendingCanContinue = textCanContinue
        continue
      }

      flushPending()
      pendingTextParts = [segment.text]
      pendingWordLike = segment.isWordLike
      pendingStartUTF16 = segment.startUTF16
      pendingContainsCJK = textContainsCJK
      pendingCanContinue = textCanContinue
      continue
    }

    flushPending()
    pendingTextParts = nil
    result.append(segment)
  }

  flushPending()
  return result
}
func compileAnalysisChunks(
  _ segments: [AnalysisSegment],
  whiteSpaceProfile: WhiteSpaceProfile
) -> [AnalysisChunk] {
  guard segments.isEmpty == false else { return [] }

  if whiteSpaceProfile.preserveHardBreaks == false {
    return [
      AnalysisChunk(
        startSegmentIndex: 0,
        endSegmentIndex: segments.count,
        consumedEndSegmentIndex: segments.count
      )
    ]
  }

  var chunks: [AnalysisChunk] = []
  chunks.reserveCapacity(max(1, segments.count / 8))
  var startSegmentIndex = 0

  for index in segments.indices where segments[index].kind == .hardBreak {
    chunks.append(
      AnalysisChunk(
        startSegmentIndex: startSegmentIndex,
        endSegmentIndex: index,
        consumedEndSegmentIndex: index + 1
      )
    )
    startSegmentIndex = index + 1
  }

  if startSegmentIndex < segments.count {
    chunks.append(
      AnalysisChunk(
        startSegmentIndex: startSegmentIndex,
        endSegmentIndex: segments.count,
        consumedEndSegmentIndex: segments.count
      )
    )
  }

  return chunks
}
