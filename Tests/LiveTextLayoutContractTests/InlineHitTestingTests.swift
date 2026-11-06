import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineHitTestingTests: XCTestCase {
  private struct GlyphSpec {
    let start: Int
    let end: Int
    let positionX: Double
  }

  private struct FixedShaper: InlineTextShaping {
    let advance: Double

    func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
      -> InlineShapedText
    {
      var ranges: [InlineSourceRange] = []
      var offset = sourceRange.startUTF16
      for grapheme in text {
        let length = String(grapheme).utf16.count
        ranges.append(try InlineSourceRange(startUTF16: offset, endUTF16: offset + length))
        offset += length
      }
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: advance, count: ranges.count),
        runs: [],
        metrics: try InlineMetrics(
          advance: advance * Double(ranges.count),
          ascent: style.font.pointSize,
          descent: 2,
          baselineOffset: style.baselineOffset
        )
      )
    }
  }

  private struct GlyphShaper: InlineTextShaping {
    let advance: Double
    let specs: [GlyphSpec]

    func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
      -> InlineShapedText
    {
      var ranges: [InlineSourceRange] = []
      var offset = sourceRange.startUTF16
      for grapheme in text {
        let length = String(grapheme).utf16.count
        ranges.append(try InlineSourceRange(startUTF16: offset, endUTF16: offset + length))
        offset += length
      }
      let glyphs = try specs.enumerated().map { glyphIndex, spec in
        let range = try InlineSourceRange(
          startUTF16: sourceRange.startUTF16 + spec.start,
          endUTF16: sourceRange.startUTF16 + spec.end
        )
        return try InlineGlyph(
          glyphID: UInt16(glyphIndex + 1),
          positionX: spec.positionX,
          positionY: 0,
          sourceUTF16Index: range.startUTF16,
          sourceRange: range
        )
      }
      let run = try InlineShapedRun(
        glyphs: glyphs,
        font: style.font,
        sourceRange: sourceRange,
        advance: advance * Double(ranges.count),
        ascent: style.font.pointSize,
        descent: 2
      )
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: advance, count: ranges.count),
        runs: [run],
        metrics: try InlineMetrics(
          advance: advance * Double(ranges.count),
          ascent: style.font.pointSize,
          descent: 2,
          baselineOffset: style.baselineOffset
        )
      )
    }
  }

  private func style(baselineOffset: Double = 0) throws -> InlineTextStyle {
    try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10),
      baselineOffset: baselineOffset
    )
  }

  private func prepared(_ atoms: [InlineAtom]) throws -> PreparedInlineDocument {
    try InlinePreparation(shaper: FixedShaper(advance: 1))
      .prepare(document: InlineDocument(atoms: atoms))
  }


  private func unicodeWordRanges(in source: String) -> [InlineSourceRange] {
    var result: [InlineSourceRange] = []
#if canImport(Darwin)
    source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: [.byWords]) {
      _, substringRange, _, _ in
      let start = substringRange.lowerBound.utf16Offset(in: source)
      let end = substringRange.upperBound.utf16Offset(in: source)
      if let range = try? InlineSourceRange(startUTF16: start, endUTF16: end) {
        result.append(range)
      }
    }
#else
    var wordStart: Int?
    var offset = 0
    for grapheme in source {
      let value = String(grapheme)
      let length = value.utf16.count
      defer { offset += length }
      let isWordLike = value.unicodeScalars.contains(where: { scalar in
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.value == 0x5F
      })
      if isWordLike {
        if wordStart == nil { wordStart = offset }
        continue
      }
      if let start = wordStart,
        let range = try? InlineSourceRange(startUTF16: start, endUTF16: offset)
      {
        result.append(range)
      }
      wordStart = nil
    }
    if let start = wordStart,
      let range = try? InlineSourceRange(startUTF16: start, endUTF16: offset)
    {
      result.append(range)
    }
#endif
    return result
  }

  private func forgedTextLayout(
    prepared: PreparedInlineDocument,
    ranges: [InlineSourceRange]
  ) throws -> InlineLayoutResult {
    guard case .text(let text) = prepared.atoms[0] else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let metrics = text.metrics
    let lineHeight = metrics.ascent + metrics.descent
    let lines = try ranges.enumerated().map { index, range in
      let positioned = try PositionedInlineAtom(
        atomID: text.atom.id,
        kind: .text,
        lineIndex: index,
        originX: 0,
        baselineY: metrics.ascent + Double(index) * lineHeight,
        width: Double(range.lengthUTF16),
        height: lineHeight,
        metrics: metrics,
        sourceRange: range
      )
      return try InlineLayoutLine(
        index: index,
        baselineY: positioned.baselineY,
        ascent: metrics.ascent,
        descent: metrics.descent,
        leading: 0,
        width: positioned.width,
        start: InlineCursor(atomIndex: 0, graphemeIndex: range.startUTF16),
        end: InlineCursor(atomIndex: 0, graphemeIndex: range.endUTF16),
        atoms: [positioned]
      )
    }
    return InlineLayoutResult(
      lines: lines,
      width: lines.map(\.width).max() ?? 0,
      height: lines.reduce(0) { $0 + $1.height },
      preparationRevision: prepared.revision,
      continuation: nil
    )
  }

  func testDefaultProfileSelectsTextWordsButNotPunctuationOrWhitespace() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "alpha, beta", style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 50)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .textUnit(let alpha) = index.hitTest(try InlineHitPoint(x: 1.5, y: 5)) else {
      return XCTFail("expected alpha word hit")
    }
    XCTAssertEqual(alpha.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 5))
    if case .none = index.hitTest(try InlineHitPoint(x: 5.5, y: 5)) {
      // Punctuation is intentionally not selectable.
    } else {
      XCTFail("punctuation must not be a word hit")
    }
    if case .none = index.hitTest(try InlineHitPoint(x: 6.5, y: 5)) {
      // Whitespace is intentionally not selectable.
    } else {
      XCTFail("whitespace must not be a word hit")
    }

    guard case .textUnit(let beta) = index.hitTest(try InlineHitPoint(x: 8.5, y: 5)) else {
      return XCTFail("expected beta word hit")
    }
    XCTAssertEqual(beta.sourceRange, try InlineSourceRange(startUTF16: 7, endUTF16: 11))
  }

  func testCJKDefaultsToOneGraphemePerTarget() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "한글", style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 50)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .textUnit(let first) = index.hitTest(try InlineHitPoint(x: 0.5, y: 5)) else {
      return XCTFail("expected first CJK grapheme hit")
    }
    XCTAssertEqual(first.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 1))
    guard case .textUnit(let second) = index.hitTest(try InlineHitPoint(x: 1.5, y: 5)) else {
      return XCTFail("expected second CJK grapheme hit")
    }
    XCTAssertEqual(second.sourceRange, try InlineSourceRange(startUTF16: 1, endUTF16: 2))
  }

  func testSentenceModeProducesDeterministicLogicalUnits() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "First sentence. Next!", style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 50)
    let index = try InlineHitTestIndex.build(
      prepared: prepared,
      layout: layout,
      profile: InlineTextUnitHitProfile(unitKind: .sentence))

    XCTAssertEqual(index.allTextUnitHits.map(\.unitKind), [.sentence, .sentence])
    XCTAssertEqual(index.allTextUnitHits.map(\.sourceRange), [
      try InlineSourceRange(startUTF16: 0, endUTF16: 15),
      try InlineSourceRange(startUTF16: 16, endUTF16: 21),
    ])
  }

  func testSentenceModeUsesCoreBoundaryAuthorityAndTrimsWhitespace() throws {
    let source = "첫 문장입니다。\u{00A0}다음 문장입니다！\n\n第三文。 Final?"
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: source, style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 200)
    let index = try InlineHitTestIndex.build(
      prepared: prepared,
      layout: layout,
      profile: InlineTextUnitHitProfile(unitKind: .sentence))

    // LiveTextCore is the single sentence-boundary authority. The expected
    // ranges prove CJK punctuation, a non-breaking space, and line-break
    // whitespace are retained only as separators.
    XCTAssertEqual(index.allTextUnitHits.map(\.sourceRange), [
      try InlineSourceRange(startUTF16: 0, endUTF16: 8),
      try InlineSourceRange(startUTF16: 9, endUTF16: 18),
      try InlineSourceRange(startUTF16: 20, endUTF16: 24),
      try InlineSourceRange(startUTF16: 25, endUTF16: 31),
    ])
    XCTAssertTrue(index.allTextUnitHits.allSatisfy { $0.unitKind == .sentence })
  }

  func testCustomModeUsesAtomLocalStableIDsAcrossWrappedFragments() throws {
    let first = try InlineCustomTextUnit(
      id: "greeting", sourceRange: try InlineSourceRange(startUTF16: 0, endUTF16: 5))
    let second = try InlineCustomTextUnit(
      id: "subject", sourceRange: try InlineSourceRange(startUTF16: 6, endUTF16: 11))
    let text = try InlineAtom.text(
      InlineTextAtom(
        id: "text", text: "hello world", style: style(),
        customTextUnits: [first, second]))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 6)
    let profile = InlineTextUnitHitProfile(unitKind: .custom)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout, profile: profile)

    XCTAssertEqual(Set(index.allTextUnitHits.compactMap(\.customID)), Set(["greeting", "subject"]))
    let greeting = try XCTUnwrap(index.allTextUnitHits.first { $0.customID == "greeting" })
    XCTAssertEqual(greeting.unitKind, .custom)
    let state = try InlineTextUnitSelectionState(
      preparationRevision: prepared.revision, hitProfile: profile)
    let selected = try state.applying(try state.activationEvent(for: greeting)).selected
    XCTAssertEqual(selected?.customID, "greeting")
    XCTAssertEqual(selected?.unitKind, .custom)
  }

  func testCustomRangeMustBeGraphemeAlignedAndNonOverlapping() throws {
    let invalid = try InlineCustomTextUnit(
      id: "emoji", sourceRange: try InlineSourceRange(startUTF16: 1, endUTF16: 2))
    XCTAssertThrowsError(
      try InlineTextAtom(
        id: "text", text: "👋", style: style(), customTextUnits: [invalid]))
    let first = try InlineCustomTextUnit(
      id: "a", sourceRange: try InlineSourceRange(startUTF16: 0, endUTF16: 2))
    let overlap = try InlineCustomTextUnit(
      id: "b", sourceRange: try InlineSourceRange(startUTF16: 1, endUTF16: 3))
    XCTAssertThrowsError(
      try InlineTextAtom(
        id: "text", text: "abc", style: style(), customTextUnits: [first, overlap]))
  }

  func testIncludeWhitespaceAddsOnlyWhitespaceTargets() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "a b", style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 3)
    let profile = InlineTextUnitHitProfile(includeWhitespace: true)
    let index = try InlineHitTestIndex.build(
      prepared: prepared, layout: layout, profile: profile)

    guard case .textUnit(let whitespace) = index.hitTest(try InlineHitPoint(x: 1.5, y: 5)) else {
      return XCTFail("whitespace must be selectable when requested")
    }
    XCTAssertEqual(whitespace.sourceRange, try InlineSourceRange(startUTF16: 1, endUTF16: 2))
    guard case .textUnit(let word) = index.hitTest(try InlineHitPoint(x: 0.5, y: 5)) else {
      return XCTFail("text must remain selectable with whitespace enabled")
    }
    XCTAssertEqual(word.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 1))
  }

  func testLigatureGlyphMapsToEveryCoveredGrapheme() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "ligature", text: "fi", style: style()))
    let prepared = try InlinePreparation(
      shaper: GlyphShaper(
        advance: 1,
        specs: [GlyphSpec(start: 0, end: 2, positionX: 0)]
      )
    ).prepare(document: InlineDocument(atoms: [text]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 2)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 1.5, y: 5)) else {
      return XCTFail("ligature word must remain hittable")
    }
    XCTAssertEqual(hit.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 2))
  }

  func testLongSpanningGlyphIsAvailableAcrossManyFragments() throws {
    let source = (0..<24).map { "word\($0)" }.joined(separator: " ")
    let graphemeCount = source.count
    var specs = [GlyphSpec(start: 0, end: source.utf16.count, positionX: 0)]
    specs.append(contentsOf: (0..<graphemeCount).map {
      GlyphSpec(start: $0, end: $0 + 1, positionX: Double($0))
    })
    let atom = try InlineAtom.text(InlineTextAtom(id: "long", text: source, style: style()))
    let prepared = try InlinePreparation(
      shaper: GlyphShaper(advance: 1, specs: specs)
    ).prepare(document: InlineDocument(atoms: [atom]))
    guard case .text(let preparedText) = prepared.atoms[0] else {
      return XCTFail("expected prepared text")
    }

    let textUnitRanges = unicodeWordRanges(in: source)
    let lines = try textUnitRanges.enumerated().map { index, range in
      let metrics = preparedText.metrics
      let positioned = try PositionedInlineAtom(
        atomID: "long",
        kind: .text,
        lineIndex: index,
        originX: 0,
        baselineY: metrics.ascent + Double(index) * (metrics.ascent + metrics.descent),
        width: Double(range.lengthUTF16),
        height: metrics.ascent + metrics.descent,
        metrics: metrics,
        sourceRange: range
      )
      return try InlineLayoutLine(
        index: index,
        baselineY: positioned.baselineY,
        ascent: metrics.ascent,
        descent: metrics.descent,
        leading: 0,
        width: positioned.width,
        start: InlineCursor(atomIndex: 0, graphemeIndex: range.startUTF16),
        end: InlineCursor(atomIndex: 0, graphemeIndex: range.endUTF16),
        atoms: [positioned]
      )
    }
    let layout = InlineLayoutResult(
      lines: lines,
      width: 8,
      height: lines.reduce(0) { $0 + $1.height },
      preparationRevision: prepared.revision,
      continuation: nil
    )
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    for (line, expected) in zip(lines, textUnitRanges) {
      let positioned = line.atoms[0]
      let y = positioned.baselineY - positioned.metrics.ascent + positioned.height / 2
      guard case .textUnit(let hit) = index.hitTest(
        try InlineHitPoint(x: positioned.width / 2, y: y)
      ) else {
        return XCTFail("expected a hit in fragment \(line.index)")
      }
      XCTAssertEqual(hit.sourceRange, expected)
    }
  }

  func testLongSingleWordAcrossAdjacentFragmentsRetainsCompleteClusters() throws {
    let source = String(repeating: "a", count: 256)
    let atom = try InlineAtom.text(InlineTextAtom(id: "long", text: source, style: style()))
    let prepared = try prepared([atom])
    guard case .text(_) = prepared.atoms[0] else {
      return XCTFail("expected prepared text")
    }
    let ranges = try (0..<source.count).map {
      try InlineSourceRange(startUTF16: $0, endUTF16: $0 + 1)
    }
    let layout = try forgedTextLayout(prepared: prepared, ranges: ranges)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)
    let expectedRange = try InlineSourceRange(startUTF16: 0, endUTF16: source.count)
    for line in layout.lines {
      let positioned = line.atoms[0]
      let y = positioned.baselineY - positioned.metrics.ascent + positioned.height / 2
      guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 0.5, y: y)) else {
        return XCTFail("expected a hit in fragment \(line.index)")
      }
      XCTAssertEqual(hit.sourceRange, expectedRange)
    }
  }

  func testFullRangeGlyphsAcrossAdjacentFragmentsRetainHits() throws {
    let graphemeCount = 256
    let source = String(repeating: "a", count: graphemeCount)
    let atom = try InlineAtom.text(InlineTextAtom(id: "glyph-heavy", text: source, style: style()))
    let prepared = try InlinePreparation(
      shaper: GlyphShaper(
        advance: 1,
        specs: (0..<graphemeCount).map { index in
          GlyphSpec(
            start: 0,
            end: graphemeCount,
            positionX: Double(graphemeCount - index)
          )
        }
      )
    ).prepare(document: InlineDocument(atoms: [atom]))
    guard case .text(_) = prepared.atoms[0] else {
      return XCTFail("expected prepared text")
    }
    let ranges = try (0..<graphemeCount).map {
      try InlineSourceRange(startUTF16: $0, endUTF16: $0 + 1)
    }
    let layout = try forgedTextLayout(prepared: prepared, ranges: ranges)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)
    let expectedRange = try InlineSourceRange(startUTF16: 0, endUTF16: graphemeCount)

    for line in layout.lines {
      let positioned = line.atoms[0]
      let y = positioned.baselineY - positioned.metrics.ascent + positioned.height / 2
      guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 0.5, y: y)) else {
        return XCTFail("expected a hit in fragment \(line.index)")
      }
      XCTAssertEqual(hit.sourceRange, expectedRange)
      XCTAssertEqual(hit.rect.minX, positioned.originX, accuracy: 0.0001)
      XCTAssertEqual(hit.rect.width, positioned.width, accuracy: 0.0001)
    }
  }

  func testExpiredNonMinimumGlyphEventIsRemovedWhenItBecomesMinimum() throws {
    let source = "a b c"
    let atom = try InlineAtom.text(InlineTextAtom(id: "staggered", text: source, style: style()))
    let prepared = try InlinePreparation(
      shaper: GlyphShaper(
        advance: 1,
        specs: [
          // At index 1, the first event is expired and the second is the minimum.
          GlyphSpec(start: 0, end: 1, positionX: 0),
          // At index 3, the third event is expired but hidden behind this active event.
          GlyphSpec(start: 0, end: 4, positionX: 10),
          GlyphSpec(start: 0, end: 3, positionX: 20),
        ]
      )
    ).prepare(document: InlineDocument(atoms: [atom]))
    let layout = try forgedTextLayout(
      prepared: prepared,
      ranges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
        try InlineSourceRange(startUTF16: 2, endUTF16: 3),
        // Keep the final whitespace and word together so stale raw X would alter the word rect.
        try InlineSourceRange(startUTF16: 3, endUTF16: 5),
      ]
    )
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)
    let positioned = layout.lines[3].atoms[0]
    let y = positioned.baselineY - positioned.metrics.ascent + positioned.height / 2

    guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 1.5, y: y)) else {
      return XCTFail("the final word must use only active glyph events")
    }
    XCTAssertEqual(hit.sourceRange, try InlineSourceRange(startUTF16: 4, endUTF16: 5))
    XCTAssertEqual(hit.rect.minX, 1, accuracy: 0.0001)
    XCTAssertEqual(hit.rect.width, 1, accuracy: 0.0001)
  }

  func testShuffledBidiGlyphPositionsPreserveVisualWordHits() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "a b", style: style()))
    let prepared = try InlinePreparation(
      shaper: GlyphShaper(
        advance: 1,
        specs: [
          GlyphSpec(start: 2, end: 3, positionX: 0),
          GlyphSpec(start: 1, end: 2, positionX: 1),
          GlyphSpec(start: 0, end: 1, positionX: 2),
        ]
      )
    ).prepare(document: InlineDocument(atoms: [text]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 3)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .textUnit(let first) = index.hitTest(try InlineHitPoint(x: 0.5, y: 5)) else {
      return XCTFail("visually first word must remain hittable")
    }
    XCTAssertEqual(first.sourceRange, try InlineSourceRange(startUTF16: 2, endUTF16: 3))
    guard case .textUnit(let second) = index.hitTest(try InlineHitPoint(x: 2.5, y: 5)) else {
      return XCTFail("visually last word must remain hittable")
    }
    XCTAssertEqual(second.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 1))
  }

  func testWordHitUsesStrictHalfOpenBoundaries() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "a,b", style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 3)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    if case .none = index.hitTest(try InlineHitPoint(x: 1, y: 5)) {
      // The point at the end of the first word is not punctuation or text.
    } else {
      XCTFail("word rectangles must use strict right boundaries")
    }
    guard case .textUnit(let last) = index.hitTest(try InlineHitPoint(x: 2, y: 5)) else {
      return XCTFail("the second word must start at its exact left boundary")
    }
    XCTAssertEqual(last.sourceRange, try InlineSourceRange(startUTF16: 2, endUTF16: 3))
  }

  func testOverlappingSameAtomFragmentsAreRejectedBeforeIndexing() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "alpha beta", style: style()))
    let prepared = try prepared([atom])
    let layout = try forgedTextLayout(
      prepared: prepared,
      ranges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 10),
        try InlineSourceRange(startUTF16: 1, endUTF16: 5),
      ]
    )
    XCTAssertNoThrow(try layout.validate(for: prepared))
    XCTAssertThrowsError(try InlineHitTestIndex.build(prepared: prepared, layout: layout)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testAdjacentSameAtomFragmentsRemainValid() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "alpha beta", style: style()))
    let prepared = try prepared([atom])
    let layout = try forgedTextLayout(
      prepared: prepared,
      ranges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 6),
        try InlineSourceRange(startUTF16: 6, endUTF16: 10),
      ]
    )
    XCTAssertNoThrow(try layout.validate(for: prepared))
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)
    guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 1, y: 17)) else {
      return XCTFail("adjacent fragments must remain hittable")
    }
    XCTAssertEqual(hit.sourceRange, try InlineSourceRange(startUTF16: 6, endUTF16: 10))
  }

  func testLongWrappedAtomMatchesUnicodeWordOracle() throws {
    let source = String(repeating: "alpha beta gamma ", count: 96)
    let text = try InlineAtom.text(InlineTextAtom(id: "long", text: source, style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 17)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    let expectedRanges = unicodeWordRanges(in: source)

    for expected in expectedRanges {
      guard let match = layout.lines.lazy.compactMap({ line in
        line.atoms.first { positioned in
          positioned.kind == .text
            && positioned.sourceRange.map {
              $0.startUTF16 < expected.endUTF16 && expected.startUTF16 < $0.endUTF16
            } ?? false
        }.map { (line, $0) }
      }).first else {
        return XCTFail("word must belong to a wrapped fragment: \(expected)")
      }
      let (_, positioned) = match
      guard let fragmentRange = positioned.sourceRange else {
        return XCTFail("expected text fragment range")
      }
      let x = positioned.originX + Double(expected.startUTF16 - fragmentRange.startUTF16) + 0.5
      let y = positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent + positioned.height / 2
      guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: x, y: y)) else {
        return XCTFail("expected word hit for \(expected)")
      }
      XCTAssertEqual(hit.sourceRange, expected)
    }
  }

  func testVectorIsASeparateSelectableTarget() throws {
    let text = try InlineAtom.text(InlineTextAtom(id: "text", text: "a", style: style()))
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "marker",
        assetID: try InlineAssetID(rawValue: "marker-asset"),
        metrics: try InlineMetrics(advance: 2, ascent: 8, descent: 2)
      ))
    let prepared = try prepared([text, vector])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 50)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .vector(let hit) = index.hitTest(try InlineHitPoint(x: 1.5, y: 5)) else {
      return XCTFail("expected vector hit")
    }
    XCTAssertEqual(hit.atomID, "marker")
    XCTAssertEqual(hit.assetID, try InlineAssetID(rawValue: "marker-asset"))
  }

  func testWordRangesKeepDocumentUTF16OffsetsAcrossTextAtoms() throws {
    let first = try InlineAtom.text(InlineTextAtom(id: "first", text: "one ", style: style()))
    let second = try InlineAtom.text(InlineTextAtom(id: "second", text: "two", style: style()))
    let prepared = try prepared([first, second])
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 50)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 5.5, y: 5)) else {
      return XCTFail("expected the second text atom to remain hittable")
    }
    XCTAssertEqual(hit.atomID, "second")
    XCTAssertEqual(hit.sourceRange, try InlineSourceRange(startUTF16: 4, endUTF16: 7))
  }

  #if canImport(CoreText)
    func testCoreTextShapingProducesVisualWordHit() throws {
      let text = try InlineAtom.text(
        InlineTextAtom(
          id: "text",
          text: "alpha beta",
          style: style()
        ))
      let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [text]))
      let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 200)
      let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

      guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 2, y: 5)) else {
        return XCTFail("expected a Core Text word hit")
      }
      XCTAssertEqual(hit.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 5))
    }
  #endif

  func testLeadingGapAndOutsideLayoutReturnNone() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "a\nb", style: style()))
    let prepared = try prepared([text])
    let layout = try InlineLayoutEngine(leading: 4).layout(prepared: prepared, width: 50)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    if case .none = index.hitTest(try InlineHitPoint(x: 0.5, y: 14)) {
      // Four points of leading separate the two twelve-point text boxes.
    } else {
      XCTFail("line leading must not select a word")
    }
    if case .none = index.hitTest(try InlineHitPoint(x: 100, y: 5)) {
      // Outside the layout is not snapped to the nearest line.
    } else {
      XCTFail("outside layout must not select a word")
    }
  }

  func testHitRectsTrackSignedBaselineOffset() throws {
    let raised = try InlineAtom.text(
      InlineTextAtom(id: "raised", text: "a", style: style(baselineOffset: 3)))
    let raisedPrepared = try prepared([raised])
    let raisedLayout = try InlineLayoutEngine().layout(prepared: raisedPrepared, width: 50)
    let raisedIndex = try InlineHitTestIndex.build(prepared: raisedPrepared, layout: raisedLayout)
    guard case .textUnit(let raisedHit) = raisedIndex.hitTest(try InlineHitPoint(x: 0.5, y: 1)) else {
      return XCTFail("raised text must be hittable at its rendered top")
    }
    XCTAssertEqual(raisedHit.rect.minY, 0, accuracy: 0.0001)

    let lowered = try InlineAtom.text(
      InlineTextAtom(id: "lowered", text: "a", style: style(baselineOffset: -3)))
    let loweredPrepared = try prepared([lowered])
    let loweredLayout = try InlineLayoutEngine().layout(prepared: loweredPrepared, width: 50)
    let loweredIndex = try InlineHitTestIndex.build(
      prepared: loweredPrepared, layout: loweredLayout)
    guard case .textUnit(let loweredHit) = loweredIndex.hitTest(try InlineHitPoint(x: 0.5, y: 10))
    else {
      return XCTFail("lowered text must be hittable at its rendered bottom")
    }
    XCTAssertEqual(loweredHit.rect.minY, 0, accuracy: 0.0001)

    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "lowered-vector",
        assetID: try InlineAssetID(rawValue: "lowered-asset"),
        metrics: try InlineMetrics(advance: 2, ascent: 10, descent: 2, baselineOffset: -3)
      ))
    let vectorPrepared = try prepared([vector])
    let vectorLayout = try InlineLayoutEngine().layout(prepared: vectorPrepared, width: 50)
    let vectorIndex = try InlineHitTestIndex.build(prepared: vectorPrepared, layout: vectorLayout)
    guard case .vector(let vectorHit) = vectorIndex.hitTest(try InlineHitPoint(x: 0.5, y: 10))
    else {
      return XCTFail("lowered vector must be hittable at its rendered bottom")
    }
    XCTAssertEqual(vectorHit.rect.minY, 0, accuracy: 0.0001)
  }
}
