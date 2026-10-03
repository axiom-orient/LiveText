import Foundation

func lineHasDiscretionaryHyphen(
  prepared: PreparedText,
  start: LayoutCursor,
  end: LayoutCursor
) -> Bool {
  end.segmentIndex > 0 && prepared.segments[end.segmentIndex - 1].kind == .softHyphen
    && !(start.segmentIndex == end.segmentIndex && start.graphemeIndex > 0)
}

func appendSegmentGraphemeRange(
  _ text: inout String,
  graphemes: [String],
  startGraphemeIndex: Int,
  endGraphemeIndex: Int
) {
  guard startGraphemeIndex < endGraphemeIndex else { return }
  for index in startGraphemeIndex..<endGraphemeIndex {
    text += graphemes[index]
  }
}

/// Materializes the text covered by a prepared line cursor range.
public func buildLineText(
  prepared: PreparedText,
  start: LayoutCursor,
  end: LayoutCursor
) throws -> String {
  _ = try validateCursorRange(prepared: prepared, start: start, end: end)
  var materializer = LineTextMaterializer(prepared: prepared)
  return materializer.build(start: start, end: end)
}

private let leadingStickyCharacters: Set<Character> = [
  ".", ",", "!", "?", ":", ";", ")", "]", "}", "%", "\"", "\u{201D}", "'", "\u{00BB}", "\u{203A}",
  "\u{2026}",
]

/// Moves leading sticky punctuation to the previous display line without changing canonical layout metadata.
public func normalizeLeadingStickyPunctuation(
  lines: [VariableLayoutLine]
) -> [VariableLayoutDisplayLine] {
  var displayLines = lines.map {
    VariableLayoutDisplayLine(text: $0.text, originX: $0.originX, originY: $0.originY)
  }
  guard displayLines.count > 1 else { return displayLines }

  for index in 1..<displayLines.count {
    let text = displayLines[index].text
    var stickyEnd = text.startIndex
    while stickyEnd < text.endIndex, leadingStickyCharacters.contains(text[stickyEnd]) {
      stickyEnd = text.index(after: stickyEnd)
    }

    guard stickyEnd > text.startIndex else { continue }

    var remainingStart = stickyEnd
    while remainingStart < text.endIndex, text[remainingStart].isWhitespace {
      remainingStart = text.index(after: remainingStart)
    }

    guard remainingStart < text.endIndex else { continue }

    displayLines[index - 1].text += String(text[..<stickyEnd])
    displayLines[index].text = String(text[remainingStart...])
  }

  return displayLines
}
