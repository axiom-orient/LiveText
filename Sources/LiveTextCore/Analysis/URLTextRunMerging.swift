import Foundation

private func isTextRunBoundary(_ kind: SegmentBreakKind) -> Bool {
  switch kind {
  case .space, .preservedSpace, .zeroWidthBreak, .hardBreak:
    return true
  default:
    return false
  }
}

private func isURLSchemeSegment(_ text: String) -> Bool {
  guard text.hasSuffix(":"), let first = text.first else { return false }
  guard ("A"..."Z").contains(first) || ("a"..."z").contains(first) else { return false }

  for character in text.dropLast() {
    if ("A"..."Z").contains(character) || ("a"..."z").contains(character)
      || ("0"..."9").contains(character)
    {
      continue
    }
    if character == "+" || character == "." || character == "-" {
      continue
    }
    return false
  }

  return true
}

private func isURLLikeRunStart(_ segments: [AnalysisSegment], index: Int) -> Bool {
  let text = segments[index].text
  if text.hasPrefix("www.") {
    return true
  }
  return isURLSchemeSegment(text)
    && index + 1 < segments.count
    && segments[index + 1].kind == .text
    && segments[index + 1].text == "//"
}

private func isURLQueryBoundarySegment(_ text: String) -> Bool {
  text.contains("?") && (text.contains("://") || text.hasPrefix("www."))
}

func mergeURLLikeRuns(_ segments: inout [AnalysisSegment]) {
  var result = segments
  var i = 0

  while i < result.count {
    guard result[i].kind == .text, isURLLikeRunStart(result, index: i) else {
      i += 1
      continue
    }

    var merged = result[i].text
    var j = i + 1

    while j < result.count && isTextRunBoundary(result[j].kind) == false {
      merged += result[j].text
      result[i].isWordLike = true
      let endsQueryPrefix = result[j].text.contains("?")
      result[j].text = ""
      result[j].kind = .text
      j += 1
      if endsQueryPrefix {
        break
      }
    }

    result[i].text = merged
    i += 1
  }

  segments = result.filter { $0.text.isEmpty == false }
}

func mergeURLQueryRuns(_ segments: inout [AnalysisSegment]) {
  var result: [AnalysisSegment] = []
  var i = 0

  while i < segments.count {
    let segment = segments[i]
    result.append(segment)

    if isURLQueryBoundarySegment(segment.text) == false {
      i += 1
      continue
    }

    let nextIndex = i + 1
    if nextIndex >= segments.count || isTextRunBoundary(segments[nextIndex].kind) {
      i += 1
      continue
    }

    var queryParts: [String] = []
    let queryStart = segments[nextIndex].startUTF16
    var j = nextIndex
    while j < segments.count && isTextRunBoundary(segments[j].kind) == false {
      queryParts.append(segments[j].text)
      j += 1
    }

    if queryParts.isEmpty == false {
      result.append(
        AnalysisSegment(
          text: queryParts.joined(),
          isWordLike: true,
          kind: .text,
          startUTF16: queryStart
        )
      )
      i = j
      continue
    }

    i += 1
  }

  segments = result
}
