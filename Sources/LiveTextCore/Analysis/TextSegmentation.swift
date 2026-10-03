import Foundation

private func classifySegmentBreakChar(
  _ character: Character,
  whiteSpaceProfile: WhiteSpaceProfile
) -> SegmentBreakKind {
  let string = String(character)

  if whiteSpaceProfile.preserveOrdinarySpaces || whiteSpaceProfile.preserveHardBreaks {
    if string == " " { return .preservedSpace }
    if string == "\t" { return .tab }
    if whiteSpaceProfile.preserveHardBreaks && string == "\n" {
      return .hardBreak
    }
  }

  if string == " " { return .space }
  if string == "\u{00A0}" || string == "\u{202F}" || string == "\u{2060}" || string == "\u{FEFF}" {
    return .glue
  }
  if string == "\u{200B}" { return .zeroWidthBreak }
  if string == "\u{00AD}" { return .softHyphen }
  return .text
}

private func containsBreakCharacter(_ segment: String) -> Bool {
  for character in segment {
    switch String(character) {
    case " ", "\t", "\n", "\u{00A0}", "\u{00AD}", "\u{200B}", "\u{202F}", "\u{2060}", "\u{FEFF}":
      return true
    default:
      break
    }
  }
  return false
}

func splitSegmentByBreakKind(
  segment: String,
  isWordLike: Bool,
  startUTF16: Int,
  whiteSpaceProfile: WhiteSpaceProfile
) -> [AnalysisSegment] {
  guard containsBreakCharacter(segment) else {
    return [
      AnalysisSegment(text: segment, isWordLike: isWordLike, kind: .text, startUTF16: startUTF16)
    ]
  }

  var pieces: [AnalysisSegment] = []
  pieces.reserveCapacity(max(2, min(segment.utf16Length, 16)))
  var currentKind: SegmentBreakKind?
  var currentTextParts: [String] = []
  var currentStartUTF16 = startUTF16
  var currentWordLike = false
  var offset = 0

  for character in segment {
    let string = String(character)
    let kind = classifySegmentBreakChar(character, whiteSpaceProfile: whiteSpaceProfile)
    let wordLike = kind == .text && isWordLike

    if let currentKind, currentKind == kind, currentWordLike == wordLike {
      currentTextParts.append(string)
      offset += string.utf16Length
      continue
    }

    if let currentKind {
      pieces.append(
        AnalysisSegment(
          text: currentTextParts.count == 1 ? currentTextParts[0] : currentTextParts.joined(),
          isWordLike: currentWordLike,
          kind: currentKind,
          startUTF16: currentStartUTF16
        )
      )
    }

    currentKind = kind
    currentTextParts = [string]
    currentStartUTF16 = startUTF16 + offset
    currentWordLike = wordLike
    offset += string.utf16Length
  }

  if let currentKind {
    pieces.append(
      AnalysisSegment(
        text: currentTextParts.count == 1 ? currentTextParts[0] : currentTextParts.joined(),
        isWordLike: currentWordLike,
        kind: currentKind,
        startUTF16: currentStartUTF16
      )
    )
  }

  return pieces
}
