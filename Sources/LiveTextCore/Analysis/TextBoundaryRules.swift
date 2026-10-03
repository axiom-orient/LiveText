import Foundation

let kinsokuStart: Set<String> = [
  "\u{FF0C}",
  "\u{FF0E}",
  "\u{FF01}",
  "\u{FF1A}",
  "\u{FF1B}",
  "\u{FF1F}",
  "\u{3001}",
  "\u{3002}",
  "\u{30FB}",
  "\u{FF09}",
  "\u{3015}",
  "\u{3009}",
  "\u{300B}",
  "\u{300D}",
  "\u{300F}",
  "\u{3011}",
  "\u{3017}",
  "\u{3019}",
  "\u{301B}",
  "\u{30FC}",
  "\u{3005}",
  "\u{303B}",
  "\u{309D}",
  "\u{309E}",
  "\u{30FD}",
  "\u{30FE}",
]

let kinsokuEnd: Set<String> = [
  "\"",
  "(",
  "[",
  "{",
  "“",
  "‘",
  "«",
  "‹",
  "\u{FF08}",
  "\u{3014}",
  "\u{3008}",
  "\u{300A}",
  "\u{300C}",
  "\u{300E}",
  "\u{3010}",
  "\u{3016}",
  "\u{3018}",
  "\u{301A}",
]

let leftStickyPunctuation: Set<String> = [
  ".",
  ",",
  "!",
  "?",
  ":",
  ";",
  "\u{060C}",
  "\u{061B}",
  "\u{061F}",
  "\u{0964}",
  "\u{0965}",
  "\u{104A}",
  "\u{104B}",
  "\u{104C}",
  "\u{104D}",
  "\u{104F}",
  ")",
  "]",
  "}",
  "%",
  "\"",
  "”",
  "’",
  "»",
  "›",
  "…",
]

let forwardStickyGlue: Set<String> = ["'", "’"]
private let arabicNoSpaceTrailingPunctuation: Set<String> = [":", ".", "\u{060C}", "\u{061B}"]
private let myanmarMedialGlue: Set<String> = ["\u{104F}"]
private let closingQuoteChars: Set<String> = [
  "”", "’", "»", "›",
  "\u{300D}",
  "\u{300F}",
  "\u{3011}",
  "\u{300B}",
  "\u{3009}",
  "\u{3015}",
  "\u{FF09}",
]
private let keepAllGlueChars: Set<String> = [
  "\u{00A0}",
  "\u{202F}",
  "\u{2060}",
  "\u{FEFF}",
]
private let numericJoinerChars: Set<String> = [
  ":", "-", "/", "×", ",", ".", "+", "\u{2013}", "\u{2014}",
]

func endsWithClosingQuote(_ text: String) -> Bool {
  var end = text.utf16Length
  while end > 0 {
    let start = previousCodePointStart(text, endUTF16: end)
    let character = text.substringUTF16(start..<end)
    if closingQuoteChars.contains(character) {
      return true
    }
    if leftStickyPunctuation.contains(character) == false {
      return false
    }
    end = start
  }
  return false
}

func canContinueKeepAllTextRun(_ previousText: String) -> Bool {
  return !endsWithLineStartProhibitedText(previousText) && !endsWithKeepAllGlueText(previousText)
}

func isNumericRunSegment(_ text: String) -> Bool {
  guard text.isEmpty == false else { return false }
  for character in text {
    if isDecimalDigit(character) || numericJoinerChars.contains(String(character)) {
      continue
    }
    return false
  }
  return true
}

private func endsWithLineStartProhibitedText(_ text: String) -> Bool {
  guard let last = lastCodePoint(text) else { return false }
  return kinsokuStart.contains(last) || leftStickyPunctuation.contains(last)
}

private func endsWithKeepAllGlueText(_ text: String) -> Bool {
  guard let last = lastCodePoint(text) else { return false }
  return keepAllGlueChars.contains(last)
}

func hasArabicNoSpacePunctuation(containsArabic: Bool, lastCodePoint: String?) -> Bool {
  guard containsArabic, let lastCodePoint else { return false }
  return arabicNoSpaceTrailingPunctuation.contains(lastCodePoint)
}

func endsWithMyanmarMedialGlue(_ segment: String) -> Bool {
  guard let last = lastCodePoint(segment) else { return false }
  return myanmarMedialGlue.contains(last)
}
