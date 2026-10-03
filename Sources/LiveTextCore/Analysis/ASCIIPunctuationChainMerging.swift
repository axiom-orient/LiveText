import Foundation

private func isASCIIAlphaNumericOrUnderscore(_ character: Character) -> Bool {
  ("A"..."Z").contains(character) || ("a"..."z").contains(character)
    || ("0"..."9").contains(character) || character == "_"
}

private func isASCIIPunctuationChainSegment(_ text: String) -> Bool {
  guard text.isEmpty == false else { return false }

  var sawCore = false
  var sawTrailingJoiner = false
  for character in text {
    if isASCIIAlphaNumericOrUnderscore(character) {
      if sawTrailingJoiner { return false }
      sawCore = true
      continue
    }

    if character == "," || character == ":" || character == ";" {
      guard sawCore else { return false }
      sawTrailingJoiner = true
      continue
    }

    return false
  }

  return sawCore
}

private func endsWithASCIITrailingJoiners(_ text: String) -> Bool {
  guard let last = text.last else { return false }
  return last == "," || last == ":" || last == ";"
}

func mergeASCIIPunctuationChains(_ segments: inout [AnalysisSegment]) {
  var result: [AnalysisSegment] = []
  var i = 0

  while i < segments.count {
    let segment = segments[i]

    if segment.kind == .text && segment.isWordLike && isASCIIPunctuationChainSegment(segment.text) {
      var mergedParts = [segment.text]
      var endsWithJoiners = endsWithASCIITrailingJoiners(segment.text)
      var j = i + 1

      while endsWithJoiners,
        j < segments.count,
        segments[j].kind == .text,
        segments[j].isWordLike,
        isASCIIPunctuationChainSegment(segments[j].text)
      {
        let nextText = segments[j].text
        mergedParts.append(nextText)
        endsWithJoiners = endsWithASCIITrailingJoiners(nextText)
        j += 1
      }

      result.append(
        AnalysisSegment(
          text: mergedParts.joined(),
          isWordLike: true,
          kind: .text,
          startUTF16: segment.startUTF16
        )
      )
      i = j
      continue
    }

    result.append(segment)
    i += 1
  }

  segments = result
}
