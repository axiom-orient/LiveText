import Foundation

/// Width-independent break opportunities shared by every inline layout path.
///
/// This kernel is the single renderer-neutral authority for content-based line
/// break opportunities. Shaping may reject an otherwise legal grapheme boundary,
/// but callers must not invent a second content policy.
package enum LineBreakOpportunityKernel {
  package static func breakEnds(
    graphemes: [String],
    sourceStartUTF16: Int
  ) -> [Int] {
    guard !graphemes.isEmpty else { return [] }

    var ends: [Int] = []
    ends.reserveCapacity(graphemes.count)
    var endUTF16 = sourceStartUTF16

    for (index, grapheme) in graphemes.enumerated() {
      endUTF16 += grapheme.utf16.count
      let next = index + 1 < graphemes.count ? graphemes[index + 1] : nil
      if isBreakOpportunity(after: grapheme, before: next)
        || index == graphemes.index(before: graphemes.endIndex)
      {
        ends.append(endUTF16)
      }
    }
    return ends
  }

  package static func isHardBreak(_ grapheme: String) -> Bool {
    switch grapheme {
    case "\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}":
      return true
    default:
      return false
    }
  }

  private static func isBreakOpportunity(after grapheme: String, before next: String?) -> Bool {
    // Unicode glue characters prohibit an ordinary opportunity at this boundary.
    if containsGlue(grapheme) || next.map(containsGlue) == true { return false }

    // Explicit discretionary opportunities.
    if grapheme == "\u{200B}" || grapheme == "\u{00AD}" { return true }

    // Hard line separators always terminate the current line. CRLF is one
    // logical separator, so do not publish an intermediate opportunity after CR.
    if isHardBreak(grapheme) {
      if grapheme == "\r", next == "\n" { return false }
      return true
    }

    // Closing punctuation stays with the preceding source grapheme in every
    // complete/append/flow layout. Explicit hard breaks above remain authored.
    if let next, isLineStartPunctuation(next) { return false }

    // Ordinary breakable spaces/tabs. NBSP/NNBSP are excluded by containsGlue.
    if grapheme.unicodeScalars.allSatisfy({ scalar in
      scalar.value == 0x20 || scalar.value == 0x09
    }) {
      return true
    }

    // Preserve the established East Asian character opportunity policy while
    // keeping it under this single authority.
    return grapheme.unicodeScalars.contains { scalar in
      let value = scalar.value
      return (0x2E80...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value)
    }
  }

  private static func isLineStartPunctuation(_ grapheme: String) -> Bool {
    guard let scalar = grapheme.unicodeScalars.first else { return false }
    return scalar.properties.generalCategory == .closePunctuation
      || scalar.properties.generalCategory == .finalPunctuation
      || ".,!?;:%。．，、！？：；…’”".unicodeScalars.contains(scalar)
  }

  private static func containsGlue(_ grapheme: String) -> Bool {
    grapheme.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x00A0, 0x202F, 0x2060, 0xFEFF:
        return true
      default:
        return false
      }
    }
  }
}
