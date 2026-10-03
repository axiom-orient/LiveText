import Foundation

/// Package-scoped text-unit boundary authority shared by higher-level LiveText
/// modules. Renderer/layout modules consume these UTF-16 ranges and must not
/// invoke platform tokenizers directly.
package struct TextUnitBoundaryRange: Sendable, Hashable {
  package let startUTF16: Int
  package let endUTF16: Int

  package init(startUTF16: Int, endUTF16: Int) {
    precondition(startUTF16 >= 0 && endUTF16 >= startUTF16)
    self.startUTF16 = startUTF16
    self.endUTF16 = endUTF16
  }
}

package enum TextUnitBoundaryAnalyzer {
  package static func wordRanges(in text: String) -> [TextUnitBoundaryRange] {
    guard !text.isEmpty else { return [] }
    #if canImport(Darwin)
      var result: [TextUnitBoundaryRange] = []
      text.enumerateSubstrings(
        in: text.startIndex..<text.endIndex,
        options: [.byWords]
      ) { _, range, _, _ in
        result.append(
          TextUnitBoundaryRange(
            startUTF16: range.lowerBound.utf16Offset(in: text),
            endUTF16: range.upperBound.utf16Offset(in: text)
          ))
      }
      return result
    #else
      return portableWordRanges(in: text)
    #endif
  }

  package static func sentenceRanges(in text: String) -> [TextUnitBoundaryRange] {
    guard !text.isEmpty else { return [] }
    #if canImport(Darwin)
      var result: [TextUnitBoundaryRange] = []
      text.enumerateSubstrings(
        in: text.startIndex..<text.endIndex,
        options: [.bySentences]
      ) { _, range, _, _ in
        if let trimmed = trimmedRange(in: text, range: range) {
          result.append(trimmed)
        }
      }
      return result
    #else
      return portableSentenceRanges(in: text)
    #endif
  }

  package static func isWhitespace(_ grapheme: String) -> Bool {
    grapheme.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
  }

  package static func isWordLike(_ grapheme: String) -> Bool {
    grapheme.unicodeScalars.contains { scalar in
      scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.value == 0x5F
    }
  }

  package static func isCJK(_ grapheme: String) -> Bool {
    grapheme.unicodeScalars.contains { scalar in
      let value = scalar.value
      return (0x3400...0x4DBF).contains(value)
        || (0x4E00...0x9FFF).contains(value)
        || (0xAC00...0xD7AF).contains(value)
        || (0x3040...0x30FF).contains(value)
    }
  }

  private static func portableWordRanges(in text: String) -> [TextUnitBoundaryRange] {
    var result: [TextUnitBoundaryRange] = []
    var wordStart: Int?
    var offset = 0
    for character in text {
      let grapheme = String(character)
      let length = grapheme.utf16.count
      defer { offset += length }
      if isWordLike(grapheme) {
        if wordStart == nil { wordStart = offset }
      } else if let start = wordStart {
        result.append(TextUnitBoundaryRange(startUTF16: start, endUTF16: offset))
        wordStart = nil
      }
    }
    if let start = wordStart {
      result.append(TextUnitBoundaryRange(startUTF16: start, endUTF16: offset))
    }
    return result
  }

  /// Portable deterministic fallback used where Foundation does not expose
  /// sentence enumeration. It recognizes paragraph breaks and the common
  /// Unicode terminal punctuation needed by the package's declared baseline.
  /// Darwin keeps Foundation's Unicode sentence iterator behind this same
  /// package authority.
  private static func portableSentenceRanges(in text: String) -> [TextUnitBoundaryRange] {
    var result: [TextUnitBoundaryRange] = []
    var sentenceStart: Int?
    var lastContentEnd = 0
    var terminalEnd: Int?
    var offset = 0

    func appendSentence(end: Int) {
      guard let start = sentenceStart, end > start else { return }
      result.append(TextUnitBoundaryRange(startUTF16: start, endUTF16: end))
    }

    for character in text {
      let grapheme = String(character)
      let length = grapheme.utf16.count
      let nextOffset = offset + length
      let whitespace = isWhitespace(grapheme)
      let hardBreak = grapheme.unicodeScalars.contains { scalar in
        scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x2028
          || scalar.value == 0x2029
      }

      if hardBreak {
        appendSentence(end: terminalEnd ?? lastContentEnd)
        sentenceStart = nil
        terminalEnd = nil
        offset = nextOffset
        continue
      }

      if whitespace {
        if let endedAt = terminalEnd {
          appendSentence(end: endedAt)
          sentenceStart = nil
          terminalEnd = nil
        }
        offset = nextOffset
        continue
      }

      if let endedAt = terminalEnd, !isSentenceClose(grapheme) {
        appendSentence(end: endedAt)
        sentenceStart = nil
        terminalEnd = nil
      }

      if sentenceStart == nil { sentenceStart = offset }
      lastContentEnd = nextOffset
      if containsSentenceTerminal(grapheme) || (terminalEnd != nil && isSentenceClose(grapheme)) {
        terminalEnd = nextOffset
      }
      offset = nextOffset
    }

    appendSentence(end: terminalEnd ?? lastContentEnd)
    return result
  }

  private static func containsSentenceTerminal(_ grapheme: String) -> Bool {
    grapheme.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x0021, 0x002E, 0x003F,  // ! . ?
        0x0589, 0x061F, 0x06D4,  // Armenian/Arabic
        0x0964, 0x0965,  // danda/double danda
        0x104A, 0x104B,  // Myanmar
        0x1362, 0x1367, 0x1368,  // Ethiopic
        0x166E, 0x1803, 0x1809,
        0x203C, 0x2047, 0x2048, 0x2049,
        0x3002, 0xFE52, 0xFE57, 0xFF01, 0xFF0E, 0xFF1F:
        return true
      default:
        return false
      }
    }
  }

  private static func isSentenceClose(_ grapheme: String) -> Bool {
    grapheme.unicodeScalars.allSatisfy { scalar in
      switch scalar.properties.generalCategory {
      case .closePunctuation, .finalPunctuation:
        return true
      default:
        return scalar.value == 0x0022 || scalar.value == 0x0027
      }
    }
  }

  private static func trimmedRange(
    in text: String,
    range: Range<String.Index>
  ) -> TextUnitBoundaryRange? {
    var lower = range.lowerBound
    var upper = range.upperBound
    while lower < upper, text[lower].isWhitespace {
      lower = text.index(after: lower)
    }
    while lower < upper {
      let previous = text.index(before: upper)
      guard text[previous].isWhitespace else { break }
      upper = previous
    }
    guard lower < upper else { return nil }
    return TextUnitBoundaryRange(
      startUTF16: lower.utf16Offset(in: text),
      endUTF16: upper.utf16Offset(in: text)
    )
  }
}
