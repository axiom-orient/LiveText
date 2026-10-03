import Foundation

private struct WorkingMergedSegment {
  var textParts: [String]
  var isWordLike: Bool
  var kind: SegmentBreakKind
  var startUTF16: Int
  var repeatChar: String?
  var repeatCount: Int
  var containsCJK: Bool
  var containsArabicScript: Bool
  var endsWithClosingQuote: Bool
  var endsWithMyanmarMedialGlue: Bool
  var hasArabicNoSpacePunctuation: Bool

  mutating func materializeDeferredRepeat() {
    guard let repeatChar else { return }
    textParts = [String(repeating: repeatChar, count: repeatCount)]
    self.repeatChar = nil
    self.repeatCount = 0
  }

  func materialized() -> AnalysisSegment {
    if let repeatChar {
      return AnalysisSegment(
        text: String(repeating: repeatChar, count: repeatCount),
        isWordLike: isWordLike,
        kind: kind,
        startUTF16: startUTF16
      )
    }

    return AnalysisSegment(
      text: textParts.count == 1 ? textParts[0] : textParts.joined(),
      isWordLike: isWordLike,
      kind: kind,
      startUTF16: startUTF16
    )
  }
}

private struct MergePieceTraits {
  var hasCJK: Bool
  var hasArabicScript: Bool
  var trailingCodePoint: String?
  var hasClosingQuoteSuffix: Bool
  var hasMyanmarMedialGlueSuffix: Bool

  init(piece: AnalysisSegment) {
    hasCJK = isCJK(piece.text)
    hasArabicScript = containsArabicScript(piece.text)
    trailingCodePoint = lastCodePoint(piece.text)
    hasClosingQuoteSuffix = endsWithClosingQuote(piece.text)
    hasMyanmarMedialGlueSuffix = endsWithMyanmarMedialGlue(piece.text)
  }
}

private func splitLeadingSpaceAndMarks(_ segment: String) -> (space: String, marks: String)? {
  guard segment.count >= 2, segment.first == " " else { return nil }
  let marks = String(segment.dropFirst())
  guard allCombiningMarks(marks) else { return nil }
  return (" ", marks)
}

private func isLeftStickyPunctuationSegment(_ segment: String) -> Bool {
  if isEscapedQuoteClusterSegment(segment) {
    return true
  }

  var sawPunctuation = false
  for character in segment {
    let string = String(character)
    if leftStickyPunctuation.contains(string) {
      sawPunctuation = true
      continue
    }
    if sawPunctuation && isCombiningMark(character) {
      continue
    }
    return false
  }
  return sawPunctuation
}

private func isCJKLineStartProhibitedSegment(_ segment: String) -> Bool {
  guard segment.isEmpty == false else { return false }
  for character in segment {
    let string = String(character)
    if kinsokuStart.contains(string) == false && leftStickyPunctuation.contains(string) == false {
      return false
    }
  }
  return true
}

private func isForwardStickyClusterSegment(_ segment: String) -> Bool {
  if isEscapedQuoteClusterSegment(segment) {
    return true
  }

  guard segment.isEmpty == false else { return false }
  for character in segment {
    let string = String(character)
    if kinsokuEnd.contains(string) || forwardStickyGlue.contains(string)
      || isCombiningMark(character)
    {
      continue
    }
    return false
  }
  return true
}

private func isEscapedQuoteClusterSegment(_ segment: String) -> Bool {
  var sawQuote = false
  for character in segment {
    let string = String(character)
    if string == "\\" || isCombiningMark(character) {
      continue
    }
    if kinsokuEnd.contains(string) || leftStickyPunctuation.contains(string)
      || forwardStickyGlue.contains(string)
    {
      sawQuote = true
      continue
    }
    return false
  }
  return sawQuote
}

func splitTrailingForwardStickyCluster(_ text: String) -> (head: String, tail: String)? {
  let characters = Array(text)
  var splitIndex = characters.count

  while splitIndex > 0 {
    let character = characters[splitIndex - 1]
    if isCombiningMark(character) {
      splitIndex -= 1
      continue
    }

    let string = String(character)
    if kinsokuEnd.contains(string) || forwardStickyGlue.contains(string) {
      splitIndex -= 1
      continue
    }
    break
  }

  if splitIndex <= 0 || splitIndex == characters.count {
    return nil
  }

  let head = String(characters[..<splitIndex])
  let tail = String(characters[splitIndex...])
  return (head, tail)
}

private func getRepeatableSingleCharRunChar(
  text: String,
  isWordLike: Bool,
  kind: SegmentBreakKind
) -> String? {
  return kind == .text && isWordLike == false && text.utf16Length == 1 && text != "-" && text != "—"
    ? text
    : nil
}

private func appendPiece(
  _ piece: AnalysisSegment,
  traits: MergePieceTraits,
  to previous: inout WorkingMergedSegment
) {
  previous.materializeDeferredRepeat()
  previous.textParts.append(piece.text)
  previous.isWordLike = previous.isWordLike || piece.isWordLike
  previous.containsCJK = previous.containsCJK || traits.hasCJK
  previous.containsArabicScript = previous.containsArabicScript || traits.hasArabicScript
  previous.endsWithClosingQuote = traits.hasClosingQuoteSuffix
  previous.endsWithMyanmarMedialGlue = traits.hasMyanmarMedialGlueSuffix
  previous.hasArabicNoSpacePunctuation = hasArabicNoSpacePunctuation(
    containsArabic: previous.containsArabicScript,
    lastCodePoint: traits.trailingCodePoint
  )
}

func buildMergedSegmentation(
  normalized: String,
  profile: EngineProfile,
  whiteSpaceProfile: WhiteSpaceProfile,
  tokens: [WordToken]
) -> [AnalysisSegment] {
  var merged: [WorkingMergedSegment] = []
  merged.reserveCapacity(max(tokens.count, 8))

  for token in tokens {
    for piece in splitSegmentByBreakKind(
      segment: token.text,
      isWordLike: token.isWordLike,
      startUTF16: token.startUTF16,
      whiteSpaceProfile: whiteSpaceProfile
    ) {
      let isText = piece.kind == .text
      let repeatableSingleCharRunChar = getRepeatableSingleCharRunChar(
        text: piece.text,
        isWordLike: piece.isWordLike,
        kind: piece.kind
      )
      let traits = MergePieceTraits(piece: piece)

      if merged.isEmpty == false {
        let previousIndex = merged.count - 1
        if profile.carryCJKAfterClosingQuote && isText && merged[previousIndex].kind == .text
          && traits.hasCJK && merged[previousIndex].containsCJK
          && merged[previousIndex].endsWithClosingQuote
        {
          appendPiece(
            piece,
            traits: traits,
            to: &merged[previousIndex]
          )
          continue
        }

        if isText && merged[previousIndex].kind == .text
          && isCJKLineStartProhibitedSegment(piece.text) && merged[previousIndex].containsCJK
        {
          appendPiece(
            piece,
            traits: traits,
            to: &merged[previousIndex]
          )
          continue
        }

        if isText && merged[previousIndex].kind == .text
          && merged[previousIndex].endsWithMyanmarMedialGlue
        {
          appendPiece(
            piece,
            traits: traits,
            to: &merged[previousIndex]
          )
          continue
        }

        if isText && merged[previousIndex].kind == .text && piece.isWordLike
          && traits.hasArabicScript && merged[previousIndex].hasArabicNoSpacePunctuation
        {
          appendPiece(
            piece,
            traits: traits,
            to: &merged[previousIndex]
          )
          merged[previousIndex].isWordLike = true
          continue
        }

        if let repeatableSingleCharRunChar,
          merged[previousIndex].kind == .text,
          merged[previousIndex].repeatChar == repeatableSingleCharRunChar
        {
          merged[previousIndex].repeatCount += 1
          continue
        }

        if isText,
          piece.isWordLike == false,
          merged[previousIndex].kind == .text,
          isLeftStickyPunctuationSegment(piece.text)
            || (piece.text == "-" && merged[previousIndex].isWordLike)
        {
          appendPiece(
            piece,
            traits: traits,
            to: &merged[previousIndex]
          )
          continue
        }
      }

      merged.append(
        WorkingMergedSegment(
          textParts: [piece.text],
          isWordLike: piece.isWordLike,
          kind: piece.kind,
          startUTF16: piece.startUTF16,
          repeatChar: repeatableSingleCharRunChar,
          repeatCount: repeatableSingleCharRunChar == nil ? 0 : 1,
          containsCJK: traits.hasCJK,
          containsArabicScript: traits.hasArabicScript,
          endsWithClosingQuote: traits.hasClosingQuoteSuffix,
          endsWithMyanmarMedialGlue: traits.hasMyanmarMedialGlueSuffix,
          hasArabicNoSpacePunctuation: hasArabicNoSpacePunctuation(
            containsArabic: traits.hasArabicScript,
            lastCodePoint: traits.trailingCodePoint
          )
        )
      )
    }
  }

  var materialized = merged.map { $0.materialized() }

  if materialized.count > 1 {
    for index in 1..<materialized.count {
      if materialized[index].kind == .text,
        materialized[index].isWordLike == false,
        isEscapedQuoteClusterSegment(materialized[index].text),
        materialized[index - 1].kind == .text
      {
        materialized[index - 1].text += materialized[index].text
        materialized[index - 1].isWordLike =
          materialized[index - 1].isWordLike || materialized[index].isWordLike
        materialized[index].text = ""
      }
    }
  }

  var forwardStickyPrefixParts: [[String]?] = Array(repeating: nil, count: materialized.count)
  var nextLiveIndex = -1

  if materialized.isEmpty == false {
    for index in stride(from: materialized.count - 1, through: 0, by: -1) {
      let text = materialized[index].text
      guard text.isEmpty == false else { continue }

      if materialized[index].kind == .text,
        materialized[index].isWordLike == false,
        isForwardStickyClusterSegment(text),
        nextLiveIndex >= 0,
        materialized[nextLiveIndex].kind == .text
      {
        var prefixParts = forwardStickyPrefixParts[nextLiveIndex] ?? []
        prefixParts.append(text)
        forwardStickyPrefixParts[nextLiveIndex] = prefixParts
        materialized[nextLiveIndex].startUTF16 = materialized[index].startUTF16
        materialized[index].text = ""
        continue
      }

      nextLiveIndex = index
    }
  }

  for index in materialized.indices {
    guard let prefixParts = forwardStickyPrefixParts[index] else { continue }
    materialized[index].text = prefixParts.reversed().joined() + materialized[index].text
  }

  materialized = materialized.filter { $0.text.isEmpty == false }
  mergeGlueConnectedTextRuns(&materialized)
  mergeURLLikeRuns(&materialized)
  mergeURLQueryRuns(&materialized)
  mergeNumericRuns(&materialized)
  splitHyphenatedNumericRuns(&materialized)
  mergeASCIIPunctuationChains(&materialized)
  carryTrailingForwardStickyAcrossCJKBoundary(&materialized)

  if materialized.count > 1 {
    for index in 0..<(materialized.count - 1) {
      guard let split = splitLeadingSpaceAndMarks(materialized[index].text) else { continue }
      let currentKind = materialized[index].kind
      if (currentKind != .space && currentKind != .preservedSpace)
        || materialized[index + 1].kind != .text
        || containsArabicScript(materialized[index + 1].text) == false
      {
        continue
      }

      materialized[index].text = split.space
      materialized[index].isWordLike = false
      materialized[index].kind = currentKind == .preservedSpace ? .preservedSpace : .space
      materialized[index + 1].text = split.marks + materialized[index + 1].text
      materialized[index + 1].startUTF16 = materialized[index].startUTF16 + split.space.utf16Length
    }
  }

  return materialized
}
