import Foundation

struct WhiteSpaceProfile: Sendable, Hashable {
  var mode: WhiteSpaceMode
  var preserveOrdinarySpaces: Bool
  var preserveHardBreaks: Bool
}

func whiteSpaceProfile(for mode: WhiteSpaceMode) -> WhiteSpaceProfile {
  switch mode {
  case .preWrap:
    return WhiteSpaceProfile(
      mode: .preWrap,
      preserveOrdinarySpaces: true,
      preserveHardBreaks: true
    )
  case .normal:
    return WhiteSpaceProfile(
      mode: .normal,
      preserveOrdinarySpaces: false,
      preserveHardBreaks: false
    )
  }
}

func normalizeWhitespaceNormal(_ text: String) -> String {
  guard text.isEmpty == false else { return text }

  var collapsed = ""
  collapsed.reserveCapacity(text.count)
  var lastWasCollapsibleWhitespace = false
  var hasWrittenVisibleContent = false
  var pendingTrailingSpace = false

  for scalar in text.unicodeScalars {
    let isCollapsibleWhitespace: Bool
    switch scalar.value {
    case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
      isCollapsibleWhitespace = true
    default:
      isCollapsibleWhitespace = false
    }

    if isCollapsibleWhitespace {
      if hasWrittenVisibleContent, lastWasCollapsibleWhitespace == false {
        pendingTrailingSpace = true
      }
      lastWasCollapsibleWhitespace = true
    } else {
      if pendingTrailingSpace {
        collapsed.append(" ")
        pendingTrailingSpace = false
      }
      collapsed.unicodeScalars.append(scalar)
      hasWrittenVisibleContent = true
      lastWasCollapsibleWhitespace = false
    }
  }

  return collapsed
}

func normalizeWhitespacePreWrap(_ text: String) -> String {
  guard text.isEmpty == false else { return text }

  var normalized = ""
  normalized.reserveCapacity(text.count)

  var index = text.unicodeScalars.startIndex
  while index < text.unicodeScalars.endIndex {
    let scalar = text.unicodeScalars[index]
    if scalar == "\r" {
      let next = text.unicodeScalars.index(after: index)
      if next < text.unicodeScalars.endIndex, text.unicodeScalars[next] == "\n" {
        normalized.append("\n")
        index = text.unicodeScalars.index(after: next)
        continue
      }
      normalized.append("\n")
      index = next
      continue
    }

    if scalar == "\u{000C}" {
      normalized.append("\n")
      index = text.unicodeScalars.index(after: index)
      continue
    }

    normalized.unicodeScalars.append(scalar)
    index = text.unicodeScalars.index(after: index)
  }

  return normalized
}
