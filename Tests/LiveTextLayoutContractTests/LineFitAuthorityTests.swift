import Foundation
import XCTest

@testable import LiveTextCore
@testable import LiveTextLayout

final class LineFitAuthorityTests: XCTestCase {
  private struct FixedShaper: CancellableInlineTextShaping {
    let advance: Double

    func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
      -> InlineShapedText
    {
      try shape(text: text, style: style, sourceRange: sourceRange, cancellation: {})
    }

    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange,
      cancellation: InlineCancellationCheck
    ) throws -> InlineShapedText {
      var ranges: [InlineSourceRange] = []
      var offset = sourceRange.startUTF16
      for grapheme in text {
        try cancellation()
        let length = String(grapheme).utf16.count
        ranges.append(try InlineSourceRange(startUTF16: offset, endUTF16: offset + length))
        offset += length
      }
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: advance, count: ranges.count),
        runs: [],
        metrics: InlineMetrics(
          advance: advance * Double(ranges.count),
          ascent: style.font.pointSize,
          descent: 2
        )
      )
    }
  }

  private func style() throws -> InlineTextStyle {
    try InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
  }

  private func text(_ id: String, _ value: String) throws -> InlineAtom {
    .text(try InlineTextAtom(id: id, text: value, style: style()))
  }

  func testPureKernelPlacesAcrossOrderedFragmentsWithoutOverlappingExclusion() throws {
    let decision = try LineFitKernel.fit(
      units: [
        .init(advance: 2, canBreakBefore: true, canBreakAfter: true),
        .init(advance: 2, canBreakBefore: true, canBreakAfter: true),
        .init(advance: 2, canBreakBefore: true, canBreakAfter: true),
      ],
      fragments: [
        .init(originX: 0, maxWidth: 3),
        .init(originX: 7, maxWidth: 5),
      ],
      tolerance: 1.0 / 64.0,
      allowUnbreakableOverflow: false
    )
    guard case .placed(let placements) = decision else {
      return XCTFail("expected placement")
    }
    XCTAssertEqual(placements.map(\.unitIndex), [0, 1, 2])
    XCTAssertEqual(placements.map(\.originX), [0, 7, 9])
  }

  func testPureKernelRewindsOnlyAtLegalBreak() throws {
    let decision = try LineFitKernel.fit(
      units: [
        .init(advance: 2, canBreakBefore: false, canBreakAfter: false),
        .init(advance: 1, canBreakBefore: false, canBreakAfter: true),
        .init(advance: 1, canBreakBefore: true, canBreakAfter: false),
        .init(advance: 3, canBreakBefore: false, canBreakAfter: true),
      ],
      fragments: [.init(originX: 0, maxWidth: 5)],
      tolerance: 0,
      allowUnbreakableOverflow: false
    )
    guard case .rewind(let prefixCount, let placements) = decision else {
      return XCTFail("expected legal rewind")
    }
    XCTAssertEqual(prefixCount, 2)
    XCTAssertEqual(placements.count, 2)
  }

  func testCanonicalBreakOpportunityPolicyLivesInCore() {
    XCTAssertEqual(
      LineBreakOpportunityKernel.breakEnds(
        graphemes: ["a", " ", "漢", "b"], sourceStartUTF16: 10
      ),
      [12, 13, 14]
    )
  }


  func testCanonicalBreakPolicyDistinguishesGlueAndDiscretionaryBreaks() {
    XCTAssertEqual(
      LineBreakOpportunityKernel.breakEnds(
        graphemes: ["a", "\u{00A0}", "b"], sourceStartUTF16: 0
      ),
      [3]
    )
    XCTAssertEqual(
      LineBreakOpportunityKernel.breakEnds(
        graphemes: ["a", "\u{200B}", "b"], sourceStartUTF16: 0
      ),
      [2, 3]
    )
    XCTAssertEqual(
      LineBreakOpportunityKernel.breakEnds(
        graphemes: ["a", "\u{00AD}", "b"], sourceStartUTF16: 0
      ),
      [2, 3]
    )
  }

  func testCanonicalHardBreakPolicyCoversUnicodeSeparatorsAndCRLF() {
    for separator in ["\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
      XCTAssertTrue(LineBreakOpportunityKernel.isHardBreak(separator))
    }
    XCTAssertEqual(
      LineBreakOpportunityKernel.breakEnds(
        graphemes: ["a", "\r", "\n", "b"], sourceStartUTF16: 0
      ),
      [3, 4]
    )
  }

  func testStaticFlowAndContinuationUseIdenticalGeometryAuthority() throws {
    let preparation = InlinePreparation(shaper: FixedShaper(advance: 1))
    let document = try InlineDocument(atoms: [try text("copy", "a b 漢字 c d")])
    let prepared = try preparation.prepare(document: document, cancellation: {})
    let engine = try InlineLayoutEngine()
    let staticResult = try engine.layout(prepared: prepared, width: 4)
    let flow = try InlineFlowRegion(
      rect: InlineFlowRect(x: 0, y: 0, width: 4, height: 10_000), revision: 7
    )
    let flowResult = try engine.layout(prepared: prepared, flow: flow)
    XCTAssertEqual(staticResult.lines, flowResult.lines)

    var continuation: InlineLayoutContinuation?
    var pages: [InlineLayoutLine] = []
    repeat {
      let page = try engine.layout(
        prepared: prepared,
        flow: flow,
        continuation: continuation,
        maximumLines: 1
      )
      pages.append(contentsOf: page.lines)
      continuation = page.continuation
    } while continuation != nil
    XCTAssertEqual(pages.count, staticResult.lines.count)
    for (page, line) in zip(pages, staticResult.lines) {
      XCTAssertEqual(page.baselineY, line.baselineY)
      XCTAssertEqual(page.ascent, line.ascent)
      XCTAssertEqual(page.descent, line.descent)
      XCTAssertEqual(page.leading, line.leading)
      XCTAssertEqual(page.width, line.width)
      XCTAssertEqual(page.start, line.start)
      XCTAssertEqual(page.end, line.end)
      XCTAssertEqual(page.atoms.count, line.atoms.count)
      for (actual, expected) in zip(page.atoms, line.atoms) {
        XCTAssertEqual(actual.atomID, expected.atomID)
        XCTAssertEqual(actual.kind, expected.kind)
        XCTAssertEqual(actual.originX, expected.originX)
        XCTAssertEqual(actual.baselineY, expected.baselineY)
        XCTAssertEqual(actual.width, expected.width)
        XCTAssertEqual(actual.height, expected.height)
        XCTAssertEqual(actual.metrics, expected.metrics)
        XCTAssertEqual(actual.scale, expected.scale)
        XCTAssertEqual(actual.sourceRange, expected.sourceRange)
      }
    }
  }

  func testExclusionFlowAndPagedContinuationShareOneFitAuthority() throws {
    let preparation = InlinePreparation(shaper: FixedShaper(advance: 1))
    let document = try InlineDocument(atoms: [try text("copy", "a b c d e f g h")])
    let prepared = try preparation.prepare(document: document, cancellation: {})
    let exclusion = try InlineFlowExclusion(
      id: "middle",
      rect: InlineFlowRect(x: 3, y: 0, width: 2, height: 12)
    )
    let flow = try InlineFlowRegion(
      rect: InlineFlowRect(x: 0, y: 0, width: 8, height: 10_000),
      exclusions: [exclusion],
      revision: 11
    )
    let engine = try InlineLayoutEngine()
    let full = try engine.layout(prepared: prepared, flow: flow)
    XCTAssertFalse(full.lines.isEmpty)
    for line in full.lines {
      for atom in line.atoms {
        let minY = atom.baselineY - atom.metrics.baselineOffset - atom.metrics.ascent
        let maxY = minY + atom.height
        let separatedHorizontally =
          atom.originX + atom.width <= exclusion.rect.minX
          || atom.originX >= exclusion.rect.maxX
        let separatedVertically =
          maxY <= exclusion.rect.minY
          || minY >= exclusion.rect.maxY
        XCTAssertTrue(separatedHorizontally || separatedVertically)
      }
    }

    var continuation: InlineLayoutContinuation?
    var pagedLines: [InlineLayoutLine] = []
    repeat {
      let page = try engine.layout(
        prepared: prepared,
        flow: flow,
        continuation: continuation,
        maximumLines: 1
      )
      pagedLines.append(contentsOf: page.lines)
      continuation = page.continuation
    } while continuation != nil

    XCTAssertEqual(pagedLines.count, full.lines.count)
    for (actual, expected) in zip(pagedLines, full.lines) {
      XCTAssertEqual(actual.baselineY, expected.baselineY)
      XCTAssertEqual(actual.ascent, expected.ascent)
      XCTAssertEqual(actual.descent, expected.descent)
      XCTAssertEqual(actual.leading, expected.leading)
      XCTAssertEqual(actual.width, expected.width)
      XCTAssertEqual(actual.start, expected.start)
      XCTAssertEqual(actual.end, expected.end)
      XCTAssertEqual(actual.atoms.count, expected.atoms.count)
      for (actualAtom, expectedAtom) in zip(actual.atoms, expected.atoms) {
        XCTAssertEqual(actualAtom.atomID, expectedAtom.atomID)
        XCTAssertEqual(actualAtom.kind, expectedAtom.kind)
        XCTAssertEqual(actualAtom.originX, expectedAtom.originX)
        XCTAssertEqual(actualAtom.baselineY, expectedAtom.baselineY)
        XCTAssertEqual(actualAtom.width, expectedAtom.width)
        XCTAssertEqual(actualAtom.height, expectedAtom.height)
        XCTAssertEqual(actualAtom.metrics, expectedAtom.metrics)
        XCTAssertEqual(actualAtom.scale, expectedAtom.scale)
        XCTAssertEqual(actualAtom.sourceRange, expectedAtom.sourceRange)
      }
    }
  }

  func testAppendDifferentialMatrixMatchesCancellationAwareStaticLayout() throws {
    let fixtures = [
      "a b c d",
      "漢字かな",
      "abcdef",
      "a  b",
      "a\nb",
      "e\u{301} a",
    ]
    for (index, source) in fixtures.enumerated() {
      let preparation = InlinePreparation(shaper: FixedShaper(advance: 1))
      let engine = try InlineLayoutEngine()
      let atom = try text("text-\(index)", source)
      let document = try InlineDocument(atoms: [atom])
      let expectedPrepared = try preparation.prepare(document: document, cancellation: {})
      let expectedLayout = try engine.layout(prepared: expectedPrepared, width: 3)

      var reducer = try InlineAppendReducer(
        streamID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        preparation: preparation,
        engine: engine,
        width: 3
      )
      let append = InlineAppendEvent.append(
        InlineAppendBatch(
          streamID: reducer.streamID,
          sequence: reducer.nextSequence,
          baseRevision: reducer.revision,
          atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)]
        )
      )
      _ = try reducer.apply(append)
      _ = try reducer.apply(
        .finish(
          streamID: reducer.streamID,
          sequence: reducer.nextSequence,
          baseRevision: reducer.revision
        )
      )
      let actual = try reducer.finalizedResult()
      XCTAssertEqual(actual.prepared.atoms, expectedPrepared.atoms, "fixture \(source)")
      XCTAssertEqual(actual.layout.lines, expectedLayout.lines, "fixture \(source)")
    }
  }
}
