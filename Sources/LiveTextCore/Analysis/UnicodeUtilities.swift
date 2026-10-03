import Foundation

func containsArabicScript(_ text: String) -> Bool {
  for scalar in text.unicodeScalars {
    let v = scalar.value
    if (v >= 0x0600 && v <= 0x06FF) || (v >= 0x0750 && v <= 0x077F) || (v >= 0x08A0 && v <= 0x08FF)
      || (v >= 0xFB50 && v <= 0xFDFF) || (v >= 0xFE70 && v <= 0xFEFF)
    {
      return true
    }
  }
  return false
}

func isCombiningMark(_ character: Character) -> Bool {
  for scalar in character.unicodeScalars {
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
      return true
    default:
      break
    }
  }
  return false
}

func isDecimalDigit(_ character: Character) -> Bool {
  for scalar in character.unicodeScalars {
    if scalar.properties.numericType == .decimal {
      return true
    }
  }
  return false
}

func containsDecimalDigit(_ text: String) -> Bool {
  text.contains(where: isDecimalDigit)
}

func allCombiningMarks(_ text: String) -> Bool {
  guard text.isEmpty == false else { return false }
  return text.allSatisfy(isCombiningMark)
}


package func isCJKCodePoint(_ codePoint: UInt32) -> Bool {
  switch codePoint {
  case 0x4E00...0x9FFF,
    0x3400...0x4DBF,
    0x20000...0x2A6DF,
    0x2A700...0x2B73F,
    0x2B740...0x2B81F,
    0x2B820...0x2CEAF,
    0x2CEB0...0x2EBEF,
    0x2EBF0...0x2EE5D,
    0x2F800...0x2FA1F,
    0x30000...0x3134F,
    0x31350...0x323AF,
    0x323B0...0x33479,
    0xF900...0xFAFF,
    0x3000...0x303F,
    0x3040...0x309F,
    0x30A0...0x30FF,
    0xAC00...0xD7AF,
    0xFF00...0xFFEF:
    return true
  default:
    return false
  }
}

/// Returns whether text contains at least one CJK code point recognized by the engine.
public func isCJK(_ text: String) -> Bool {
  for scalar in text.unicodeScalars {
    if isCJKCodePoint(scalar.value) {
      return true
    }
  }
  return false
}
