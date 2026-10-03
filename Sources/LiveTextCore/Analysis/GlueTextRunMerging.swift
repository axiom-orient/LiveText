import Foundation

func mergeGlueConnectedTextRuns(_ segments: inout [AnalysisSegment]) {
  var result: [AnalysisSegment] = []
  var read = 0

  while read < segments.count {
    var textParts = [segments[read].text]
    var isWordLike = segments[read].isWordLike
    var kind = segments[read].kind
    var startUTF16 = segments[read].startUTF16

    if kind == .glue {
      var glueParts = [textParts[0]]
      let glueStart = startUTF16
      read += 1

      while read < segments.count && segments[read].kind == .glue {
        glueParts.append(segments[read].text)
        read += 1
      }

      let glueText = glueParts.joined()
      if read < segments.count && segments[read].kind == .text {
        textParts = [glueText, segments[read].text]
        isWordLike = segments[read].isWordLike
        kind = .text
        startUTF16 = glueStart
        read += 1
      } else {
        result.append(
          AnalysisSegment(text: glueText, isWordLike: false, kind: .glue, startUTF16: glueStart)
        )
        continue
      }
    } else {
      read += 1
    }

    if kind == .text {
      while read < segments.count && segments[read].kind == .glue {
        var glueParts: [String] = []
        while read < segments.count && segments[read].kind == .glue {
          glueParts.append(segments[read].text)
          read += 1
        }

        let glueText = glueParts.joined()
        if read < segments.count && segments[read].kind == .text {
          textParts.append(glueText)
          textParts.append(segments[read].text)
          isWordLike = isWordLike || segments[read].isWordLike
          read += 1
          continue
        }

        textParts.append(glueText)
      }
    }

    result.append(
      AnalysisSegment(
        text: textParts.count == 1 ? textParts[0] : textParts.joined(),
        isWordLike: isWordLike,
        kind: kind,
        startUTF16: startUTF16
      )
    )
  }

  segments = result
}

func carryTrailingForwardStickyAcrossCJKBoundary(_ segments: inout [AnalysisSegment]) {
  var result = segments
  guard result.count >= 2 else { return }

  for index in 0..<(result.count - 1) {
    if result[index].kind != .text || result[index + 1].kind != .text {
      continue
    }
    if isCJK(result[index].text) == false || isCJK(result[index + 1].text) == false {
      continue
    }

    guard let split = splitTrailingForwardStickyCluster(result[index].text) else { continue }
    result[index].text = split.head
    result[index + 1].text = split.tail + result[index + 1].text
    result[index + 1].startUTF16 = result[index].startUTF16 + split.head.utf16Length
  }

  segments = result
}
