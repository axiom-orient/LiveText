import Foundation

func mergeNumericRuns(_ segments: inout [AnalysisSegment]) {
  var result: [AnalysisSegment] = []
  var i = 0

  while i < segments.count {
    let segment = segments[i]

    if segment.kind == .text && isNumericRunSegment(segment.text)
      && containsDecimalDigit(segment.text)
    {
      var mergedParts = [segment.text]
      var j = i + 1

      while j < segments.count && segments[j].kind == .text && isNumericRunSegment(segments[j].text)
      {
        mergedParts.append(segments[j].text)
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

func splitHyphenatedNumericRuns(_ segments: inout [AnalysisSegment]) {
  var result: [AnalysisSegment] = []

  for segment in segments {
    if segment.kind == .text && segment.text.contains("-") {
      let parts = segment.text.split(separator: "-", omittingEmptySubsequences: false).map(
        String.init)
      var shouldSplit = parts.count > 1
      for part in parts where shouldSplit {
        if part.isEmpty || containsDecimalDigit(part) == false || isNumericRunSegment(part) == false
        {
          shouldSplit = false
        }
      }

      if shouldSplit {
        var offset = 0
        for index in parts.indices {
          let part = parts[index]
          let splitText = index < parts.count - 1 ? part + "-" : part
          result.append(
            AnalysisSegment(
              text: splitText,
              isWordLike: true,
              kind: .text,
              startUTF16: segment.startUTF16 + offset
            )
          )
          offset += splitText.utf16Length
        }
        continue
      }
    }

    result.append(segment)
  }

  segments = result
}
