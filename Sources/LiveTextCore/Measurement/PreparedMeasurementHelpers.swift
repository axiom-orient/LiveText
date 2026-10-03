import Foundation

struct MeasuredTextUnit {
  var text: String
  var startUTF16: Int
}

private let maximumExactPrefixGraphemes = 96

func breakableMeasurementMode(
  for text: String,
  isWordLike: Bool,
  allowOverflowBreaks: Bool,
  profile: EngineProfile
) -> BreakableMeasurementMode {
  guard allowOverflowBreaks, isWordLike, text.utf16Length > 1 else {
    return .none
  }

  switch profile.breakableMeasurementPolicy {
  case .exactPrefixWidths:
    return .exactPrefix
  case .appleBounded:
    return graphemeClustersWithUTF16Offsets(text).count > maximumExactPrefixGraphemes
      ? .sumGraphemes
      : .exactPrefix
  case .browserParity:
    return isNumericRunSegment(text) ? .pairContext : .exactPrefix
  }
}

func buildBaseCJKUnits(
  _ segmentText: String,
  profile: EngineProfile
) -> [MeasuredTextUnit] {
  var units: [MeasuredTextUnit] = []
  var unitParts: [String] = []
  var unitStartUTF16 = 0
  var unitContainsCJK = false
  var unitEndsWithClosingQuote = false
  var unitIsSingleKinsokuEnd = false

  func pushUnit() {
    guard unitParts.isEmpty == false else { return }
    let text = unitParts.count == 1 ? unitParts[0] : unitParts.joined()
    units.append(
      MeasuredTextUnit(
        text: text,
        startUTF16: unitStartUTF16
      )
    )
    unitParts.removeAll(keepingCapacity: true)
    unitContainsCJK = false
    unitEndsWithClosingQuote = false
    unitIsSingleKinsokuEnd = false
  }

  func startUnit(_ grapheme: String, startUTF16: Int, containsCJK: Bool) {
    unitParts = [grapheme]
    unitStartUTF16 = startUTF16
    unitContainsCJK = containsCJK
    unitEndsWithClosingQuote = endsWithClosingQuote(grapheme)
    unitIsSingleKinsokuEnd = kinsokuEnd.contains(grapheme)
  }

  func appendToUnit(_ grapheme: String, containsCJK: Bool) {
    unitParts.append(grapheme)
    unitContainsCJK = unitContainsCJK || containsCJK
    let graphemeEndsWithClosingQuote = endsWithClosingQuote(grapheme)
    if leftStickyPunctuation.contains(grapheme) {
      unitEndsWithClosingQuote = unitEndsWithClosingQuote || graphemeEndsWithClosingQuote
    } else {
      unitEndsWithClosingQuote = graphemeEndsWithClosingQuote
    }
    unitIsSingleKinsokuEnd = false
  }

  for cluster in graphemeClustersWithUTF16Offsets(segmentText) {
    let grapheme = cluster.text
    let graphemeContainsCJK = isCJK(grapheme)

    if unitParts.isEmpty {
      startUnit(grapheme, startUTF16: cluster.startUTF16, containsCJK: graphemeContainsCJK)
      continue
    }

    if unitIsSingleKinsokuEnd || kinsokuStart.contains(grapheme)
      || leftStickyPunctuation.contains(grapheme)
      || (profile.carryCJKAfterClosingQuote && graphemeContainsCJK && unitEndsWithClosingQuote)
    {
      appendToUnit(grapheme, containsCJK: graphemeContainsCJK)
      continue
    }

    if unitContainsCJK == false && graphemeContainsCJK == false {
      appendToUnit(grapheme, containsCJK: graphemeContainsCJK)
      continue
    }

    pushUnit()
    startUnit(grapheme, startUTF16: cluster.startUTF16, containsCJK: graphemeContainsCJK)
  }

  pushUnit()
  return units
}

func mergeKeepAllTextUnits(_ units: [MeasuredTextUnit]) -> [MeasuredTextUnit] {
  guard units.count > 1 else { return units }

  var merged: [MeasuredTextUnit] = []
  var currentTextParts = [units[0].text]
  var currentStartUTF16 = units[0].startUTF16
  var currentContainsCJK = isCJK(units[0].text)
  var currentCanContinue = canContinueKeepAllTextRun(units[0].text)

  func flushCurrent() {
    let text = currentTextParts.count == 1 ? currentTextParts[0] : currentTextParts.joined()
    merged.append(
      MeasuredTextUnit(
        text: text,
        startUTF16: currentStartUTF16
      )
    )
  }

  for unit in units.dropFirst() {
    let nextContainsCJK = isCJK(unit.text)
    let nextCanContinue = canContinueKeepAllTextRun(unit.text)

    if currentContainsCJK && currentCanContinue {
      currentTextParts.append(unit.text)
      currentContainsCJK = currentContainsCJK || nextContainsCJK
      currentCanContinue = nextCanContinue
      continue
    }

    flushCurrent()
    currentTextParts = [unit.text]
    currentStartUTF16 = unit.startUTF16
    currentContainsCJK = nextContainsCJK
    currentCanContinue = nextCanContinue
  }

  flushCurrent()
  return merged
}
