import Foundation
import LiveTextCore
import XCTest

@testable import LiveTextLayout

final class SourceMappingRegressionTests: XCTestCase {
  private func ranges(_ text: String, offset: Int = 0) throws -> [InlineSourceRange] {
    var start = offset
    return try text.map { character in
      let end = start + String(character).utf16.count
      defer { start = end }
      return try InlineSourceRange(startUTF16: start, endUTF16: end)
    }
  }

  private func prepared(_ text: String, offset: Int = 0) throws -> PreparedInlineText {
    let sourceRanges = try ranges(text, offset: offset)
    let atom = try InlineTextAtom(
      id: "text", text: text,
      style: InlineTextStyle(font: FontDescriptor(postScriptName: "Fixture", pointSize: 12)))
    return try PreparedInlineText(
      atom: atom,
      sourceRange: InlineSourceRange(startUTF16: offset, endUTF16: offset + text.utf16.count),
      graphemes: text.map(String.init),
      shaped: InlineShapedText(
        graphemeRanges: sourceRanges,
        graphemeAdvances: Array(repeating: 1, count: sourceRanges.count),
        runs: [],
        metrics: InlineMetrics(advance: Double(sourceRanges.count), ascent: 12, descent: 2)),
      textBreakEnds: LineBreakOpportunityKernel.breakEnds(
        graphemes: text.map(String.init), sourceStartUTF16: offset))
  }

  func testTruncatedPreparationThrowsInsteadOfIndexingPastArray() throws {
    let valid = try prepared("ab")
    let one = try prepared("a")
    XCTAssertThrowsError(
      try PreparedInlineText(
        atom: valid.atom, sourceRange: valid.sourceRange, graphemes: one.graphemes,
        shaped: one.shaped, textBreakEnds: [2])
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .unsupportedShaping("grapheme source mapping does not match the text"))
    }
  }

  func testEmptyTextCannotCarryPhantomGraphemes() throws {
    let empty = try prepared("")
    let shaped = try InlineShapedText(
      graphemeRanges: [InlineSourceRange(startUTF16: 0, endUTF16: 0)],
      graphemeAdvances: [0], runs: [], metrics: InlineMetrics(advance: 0, ascent: 0, descent: 0))
    XCTAssertThrowsError(
      try PreparedInlineText(
        atom: empty.atom, sourceRange: empty.sourceRange, graphemes: [""], shaped: shaped,
        textBreakEnds: [0]))
  }

  func testValidatedBoundaryIndexMatchesPublicStringBoundaryValidation() throws {
    for text in ["", "ascii", "한글", "e\u{301}😀x", "👨‍👩‍👧‍👦🇰🇷a", "a\r\nb"] {
      for offset in [0, 19] {
        let value = try prepared(text, offset: offset)
        for start in 0...text.utf16.count {
          for end in start...text.utf16.count {
            let local = try InlineSourceRange(startUTF16: start, endUTF16: end)
            let global = try InlineSourceRange(startUTF16: start + offset, endUTF16: end + offset)
            let expected = Result { try local.validateGraphemeBoundaries(in: text) }
            let actual = Result { try value.validateSourceRangeBoundaries(global) }
            switch (expected, actual) {
            case (.success, .success): break
            case (.failure(let lhs), .failure(let rhs)):
              XCTAssertEqual(lhs as? InlineLayoutError, rhs as? InlineLayoutError)
            default: XCTFail("boundary mismatch: \(text.debugDescription), \(local)")
            }
          }
        }
      }
    }
  }

  func testCustomUnitBoundariesMatchTheSameUTF16Contract() throws {
    let text = "a😀e\u{301}한"
    let style = try InlineTextStyle(font: FontDescriptor(postScriptName: "Fixture", pointSize: 12))
    for start in 0..<text.utf16.count {
      for end in (start + 1)...text.utf16.count {
        let range = try InlineSourceRange(startUTF16: start, endUTF16: end)
        let unit = try InlineCustomTextUnit(id: "unit", sourceRange: range)
        let expected = Result { try range.validateGraphemeBoundaries(in: text) }
        let actual = Result {
          try InlineTextAtom(id: "text", text: text, style: style, customTextUnits: [unit])
        }
        switch (expected, actual) {
        case (.success, .success): break
        case (.failure(let lhs), .failure(let rhs)):
          XCTAssertEqual(lhs as? InlineLayoutError, rhs as? InlineLayoutError)
        default: XCTFail("custom boundary mismatch \(range)")
        }
      }
    }
  }

  func testSearchMatchesLinearOracleIncludingRepeatedStrokeRanges() throws {
    let base = try ranges("a😀e\u{301}한x", offset: 7)
    for values in [base, base.flatMap { [$0, $0] }, []] {
      for start in 0...18 {
        for end in start...18 {
          let query = try InlineSourceRange(startUTF16: start, endUTF16: end)
          let expected = values.indices.filter {
            start < end && values[$0].startUTF16 < end && start < values[$0].endUTF16
          }
          XCTAssertEqual(
            Array(InlineSourceRangeSearch.overlappingIndices(in: values, with: query)), expected)
        }
      }
    }
  }

  func testClusterBreaksMatchExhaustiveOracleForUnsortedAndSpanningGlyphs() throws {
    // Deterministic generator; no stochastic failures and no timing assertion.
    var seed: UInt64 = 0x517c_c1b7_2722_0a95
    func next(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 32) % UInt64(bound))
    }
    for _ in 0..<180 {
      let count = 1 + next(64)
      let ranges = try (0..<count).map {
        try InlineSourceRange(startUTF16: 2 * $0, endUTF16: 2 * $0 + 2)
      }
      var glyphs: [InlineGlyph] = []
      for index in 0..<next(96) {
        let start = next(count * 2)
        let end = start + 1 + next(count * 2 - start)
        glyphs.append(
          try InlineGlyph(
            glyphID: UInt16(index), positionX: Double(next(100)), positionY: 0,
            sourceUTF16Index: start,
            sourceRange: InlineSourceRange(startUTF16: start, endUTF16: end)))
      }
      let run = try InlineShapedRun(
        glyphs: glyphs, font: FontDescriptor(postScriptName: "Fixture", pointSize: 12),
        sourceRange: InlineSourceRange(startUTF16: 0, endUTF16: count * 2), advance: Double(count),
        ascent: 12, descent: 2)
      let shaped = try InlineShapedText(
        graphemeRanges: ranges, graphemeAdvances: Array(repeating: 1, count: count),
        runs: [run], metrics: InlineMetrics(advance: Double(count), ascent: 12, descent: 2))
      let expected = ranges.map { range in
        !glyphs.contains {
          $0.sourceRange.startUTF16 < range.endUTF16 && range.endUTF16 < $0.sourceRange.endUTF16
        }
      }
      XCTAssertEqual(shaped.graphemeCanBreakAfter, expected)
    }
  }

  func testRevealIDLookupKeepsIndependentProgressForSharedRanges() throws {
    let range = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let units = try (0..<30).map { index in
      try InlineRenderRevealTextUnit(
        id: InlineRevealUnitID(rawValue: "stroke-\(index)"), kind: .semanticStroke,
        sourceRange: range, startTime: Double(index) * 0.25, duration: 1)
    }
    let activation = try InlineRenderRevealTextActivation(atomID: "text", units: units)
    for time in [-2, 0, 0.1, 1, 4, 100, 0.25] {
      for unit in units.reversed() {
        let expected = min(
          1, max(0, (min(max(time, 0), activation.duration) - unit.startTime) / unit.duration))
        XCTAssertEqual(activation.progress(at: time, unitID: unit.id), expected)
      }
    }
    XCTAssertEqual(
      activation.progress(at: 100, unitID: try InlineRevealUnitID(rawValue: "missing")), 0)
    XCTAssertThrowsError(
      try InlineRenderRevealTextActivation(atomID: "text", units: [units[0], units[0]]))
  }

  func testStreamingDecodeRechecksPreparationRevision() throws {
    let text = try prepared("a")
    let document = try PreparedInlineDocument(
      document: InlineDocument(atoms: [.text(text.atom)]),
      atoms: [.text(text)],
      totalTextUTF16Units: 1,
      totalGraphemes: 1,
      totalGlyphs: 0,
      totalRuns: 0
    )
    let layout = try InlineLayoutEngine().layout(prepared: document, width: 10)
    let valid = try InlineStreamingResult(prepared: document, layout: layout)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    var altered = try XCTUnwrap(object["layout"] as? [String: Any])
    altered["preparationRevision"] = "stale"
    object["layout"] = altered
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineStreamingResult.self, from: JSONSerialization.data(withJSONObject: object)))
  }
}
