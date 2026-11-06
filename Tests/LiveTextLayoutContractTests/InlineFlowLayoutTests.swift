import Foundation
import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineFlowLayoutTests: XCTestCase {
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

  private func prepared(_ text: String = "a b c d e f g h") throws -> PreparedInlineDocument {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
    let atom = try InlineAtom.text(InlineTextAtom(id: "copy", text: text, style: style))
    return try InlinePreparation(shaper: FixedShaper(advance: 5))
      .prepare(document: InlineDocument(atoms: [atom]))
  }

  private func region(
    width: Double = 100,
    exclusions: [InlineFlowExclusion] = [],
    height: Double = 120
  ) throws -> InlineFlowRegion {
    try InlineFlowRegion(
      rect: try InlineFlowRect(x: 0, y: 0, width: width, height: height),
      exclusions: exclusions,
      revision: 1
    )
  }

  func testNoExclusionFlowIsWidthOnlyParity() throws {
    let prepared = try prepared()
    let engine = try InlineLayoutEngine()
    let width = try engine.layout(prepared: prepared, width: 100)
    let flow = try engine.layout(prepared: prepared, flow: region())

    XCTAssertEqual(width.lines, flow.lines)
    XCTAssertEqual(width.width, flow.width, accuracy: 0.0001)
    XCTAssertEqual(width.height, flow.height, accuracy: 0.0001)
  }

  func testLeftMiddleAndRightExclusionCreateSafeFragments() throws {
    let prepared = try prepared("a b c d e f g h i j k l")
    let engine = try InlineLayoutEngine()
    for x in [0.0, 35.0, 70.0] {
      let exclusion = try InlineFlowExclusion(
        id: "object",
        rect: try InlineFlowRect(x: x, y: 0, width: 30, height: 12)
      )
      let layout = try engine.layout(
        prepared: prepared,
        flow: try region(exclusions: [exclusion])
      )
      XCTAssertFalse(layout.lines.isEmpty)
      for line in layout.lines where line.baselineY <= 12.0 + 1.0 / 64.0 {
        let blocked = line.atoms.contains { atom in
          atom.originX < exclusion.rect.maxX && atom.originX + atom.width > exclusion.rect.minX
        }
        XCTAssertFalse(blocked, "line intersects exclusion at x=\(x)")
      }
    }
  }

  func testMultipleExclusionsAndFullRowMoveContentBelowObjects() throws {
    let prepared = try prepared("a b c d e f g h")
    let exclusions = [
      try InlineFlowExclusion(
        id: "photo",
        rect: try InlineFlowRect(x: 10, y: 0, width: 25, height: 12)
      ),
      try InlineFlowExclusion(
        id: "button",
        rect: try InlineFlowRect(x: 60, y: 0, width: 25, height: 12)
      ),
    ]
    let layout = try InlineLayoutEngine().layout(
      prepared: prepared,
      flow: try region(exclusions: exclusions)
    )
    XCTAssertGreaterThanOrEqual(layout.lines.count, 2)
    let firstLineAtoms = layout.lines[0].atoms
    XCTAssertTrue(
      firstLineAtoms.allSatisfy { atom in
        (atom.originX + atom.width <= 10.0 + 1.0 / 64.0)
          || (atom.originX >= 35.0 - 1.0 / 64.0
            && atom.originX + atom.width <= 60.0 + 1.0 / 64.0)
          || atom.originX >= 85.0 - 1.0 / 64.0
      })

    let fullRow = try InlineFlowExclusion(
      id: "full-row",
      rect: try InlineFlowRect(x: 0, y: 0, width: 100, height: 12)
    )
    let moved = try InlineLayoutEngine().layout(
      prepared: prepared,
      flow: try region(exclusions: [fullRow])
    )
    XCTAssertFalse(moved.lines.isEmpty)
    XCTAssertGreaterThanOrEqual(moved.lines[0].baselineY, 22)
  }

  func testMovingExclusionChangesOnlyFlowPlacement() throws {
    let prepared = try prepared("a b c d e f g h i j")
    let engine = try InlineLayoutEngine()
    let left = try engine.layout(
      prepared: prepared,
      flow: try region(exclusions: [
        try InlineFlowExclusion(
          id: "photo",
          rect: try InlineFlowRect(x: 15, y: 0, width: 25, height: 12)
        )
      ])
    )
    let right = try engine.layout(
      prepared: prepared,
      flow: try region(exclusions: [
        try InlineFlowExclusion(
          id: "photo",
          rect: try InlineFlowRect(x: 60, y: 0, width: 25, height: 12)
        )
      ])
    )
    XCTAssertNotEqual(left.lines, right.lines)
    XCTAssertEqual(left.preparationRevision, right.preparationRevision)
  }

  func testZeroWidthRejectsRemainingContentButKeepsEmptyDocumentEmpty() throws {
    let engine = try InlineLayoutEngine()
    let nonempty = try prepared("a")
    XCTAssertThrowsError(
      try engine.layout(prepared: nonempty, flow: try region(width: 0))
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .flowContentExceedsRegion)
    }

    let empty = try prepared("")
    let result = try engine.layout(prepared: empty, flow: try region(width: 0))
    XCTAssertTrue(result.lines.isEmpty)
    XCTAssertNil(result.continuation)
  }

  func testMixedTextVectorImageAtomsAvoidExclusionRectangle() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
    let textBefore = try InlineAtom.text(
      InlineTextAtom(id: "before", text: "a ", style: style))
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "vector",
        assetID: try InlineAssetID(rawValue: "vector"),
        metrics: try InlineMetrics(advance: 20, ascent: 12, descent: 3)
      ))
    let image = try InlineAtom.image(
      InlineImageAtom(
        id: "image",
        assetID: try InlineAssetID(rawValue: "image"),
        digest: InlineAssetDigest(data: Data([1])),
        metrics: try InlineMetrics(advance: 18, ascent: 12, descent: 3),
        accessibilityLabel: "image"
      ))
    let textAfter = try InlineAtom.text(
      InlineTextAtom(id: "after", text: "b c", style: style))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 6)).prepare(
      document: InlineDocument(atoms: [textBefore, vector, image, textAfter])
    )
    let exclusion = try InlineFlowExclusion(
      id: "external-photo",
      rect: try InlineFlowRect(x: 35, y: 0, width: 30, height: 18)
    )
    let layout = try InlineLayoutEngine().layout(
      prepared: prepared,
      flow: try region(exclusions: [exclusion])
    )
    let positioned = layout.lines.flatMap(\.atoms)
    XCTAssertTrue(positioned.contains { $0.kind == .text })
    XCTAssertTrue(positioned.contains { $0.kind == .vector })
    XCTAssertTrue(positioned.contains { $0.kind == .image })
    XCTAssertTrue(
      positioned.allSatisfy { atom in
        let minY = atom.baselineY - atom.metrics.baselineOffset - atom.metrics.ascent
        let maxY = minY + atom.height
        let separatedHorizontally =
          atom.originX + atom.width <= exclusion.rect.minX
          || atom.originX >= exclusion.rect.maxX
        let separatedVertically =
          maxY <= exclusion.rect.minY
          || minY >= exclusion.rect.maxY
        return separatedHorizontally || separatedVertically
      })
  }

  func testLineHeightGrowthRechecksVerticalExclusion() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
    let text = try InlineAtom.text(InlineTextAtom(id: "text", text: "a ", style: style))
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "tall",
        assetID: try InlineAssetID(rawValue: "tall"),
        metrics: try InlineMetrics(advance: 20, ascent: 30, descent: 2)
      )
    )
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 5)).prepare(
      document: InlineDocument(atoms: [text, vector]))
    let exclusion = try InlineFlowExclusion(
      id: "late-row",
      rect: try InlineFlowRect(x: 0, y: 13, width: 100, height: 28)
    )
    let layout = try InlineLayoutEngine().layout(
      prepared: prepared,
      flow: try region(exclusions: [exclusion], height: 120)
    )

    XCTAssertTrue(
      layout.lines.flatMap(\.atoms).allSatisfy { atom in
        let minY = atom.baselineY - atom.metrics.baselineOffset - atom.metrics.ascent
        let maxY = minY + atom.height
        let separatedHorizontally =
          atom.originX + atom.width <= exclusion.rect.minX
          || atom.originX >= exclusion.rect.maxX
        let separatedVertically =
          maxY <= exclusion.rect.minY
          || minY >= exclusion.rect.maxY
        return separatedHorizontally || separatedVertically
      })
  }

  func testContinuationRejectsAStaleFlowRevision() throws {
    let prepared = try prepared("a b c d e f g h i j")
    let engine = try InlineLayoutEngine()
    let firstRegion = try InlineFlowRegion(
      rect: try InlineFlowRect(x: 0, y: 0, width: 40, height: 120), revision: 7)
    let first = try engine.layout(prepared: prepared, flow: firstRegion, maximumLines: 1)
    guard let continuation = first.continuation else {
      return XCTFail("expected a bounded flow continuation")
    }
    let changedRegion = try InlineFlowRegion(
      rect: try InlineFlowRect(x: 0, y: 0, width: 40, height: 120), revision: 8)
    XCTAssertThrowsError(
      try engine.layout(
        prepared: prepared,
        flow: changedRegion,
        continuation: continuation,
        maximumLines: 1
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidContinuation)
    }
  }

  func testInvalidFlowGeometryIsTypedAndDuplicateIDsAreRejected() throws {
    XCTAssertThrowsError(
      try InlineFlowRect(x: 0, y: 0, width: .infinity, height: 10)
    ) { error in
      guard case .invalidFlowRegion = error as? InlineLayoutError else {
        return XCTFail("expected typed invalid flow region")
      }
    }
    XCTAssertThrowsError(
      try InlineFlowInsets(top: -1, leading: 0, bottom: 0, trailing: 0)
    )
    let first = try InlineFlowExclusion(
      id: "same",
      rect: try InlineFlowRect(x: 0, y: 0, width: 10, height: 10)
    )
    XCTAssertThrowsError(try region(exclusions: [first, first]))
  }

  func testFlowCodableRequiresContinuationGeometryFields() throws {
    let continuation = InlineLayoutContinuation(
      cursor: .zero,
      preparationRevision: "revision",
      width: 40,
      oversizedVectorPolicy: .reject,
      flowRevision: 3,
      nextY: 24
    )
    let continuationData = try JSONEncoder().encode(continuation)
    let continuationObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: continuationData) as? [String: Any]
    )
    for key in ["flowRevision", "nextY"] {
      var missingField = continuationObject
      missingField.removeValue(forKey: key)
      let data = try JSONSerialization.data(withJSONObject: missingField)
      XCTAssertThrowsError(
        try JSONDecoder().decode(InlineLayoutContinuation.self, from: data),
        "missing continuation field: \(key)"
      )
    }

    let result = InlineLayoutResult(
      lines: [],
      width: 40,
      height: 0,
      preparationRevision: "revision",
      continuation: nil,
      flowRevision: 3
    )
    let resultData = try JSONEncoder().encode(result)
    var resultObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: resultData) as? [String: Any]
    )
    resultObject.removeValue(forKey: "flowRevision")
    let missingResultField = try JSONSerialization.data(withJSONObject: resultObject)
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineLayoutResult.self, from: missingResultField)
    )
  }

  func testIncrementalUnobstructedRowsMatchCompleteFragmentSolver() throws {
    // An exclusion outside the flow rectangle forces the complete solver without
    // changing its fragments. This compares two real production paths, not a stub.
    let outside = try InlineFlowExclusion(
      id: "outside", rect: InlineFlowRect(x: 10_000, y: 0, width: 1, height: 100_000))
    let behaviors: [InlineBreakBehavior] = [
      .normal, .keepTogether, .breakBefore, .breakAfter, .noBreakAround,
    ]
    let strings = ["a b c d e", "한글 e\u{301} 👨‍👩‍👧‍👦", "a\n\nb", String(repeating: "x", count: 256)]
    let engine = try InlineLayoutEngine()
    for behavior in behaviors {
      for text in strings {
        let style = try InlineTextStyle(
          font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
        let largerStyle = try InlineTextStyle(
          font: FontDescriptor(postScriptName: "Helvetica", pointSize: 24), baselineOffset: 3)
        let atoms: [InlineAtom] = [
          .text(try InlineTextAtom(id: "a", text: text, style: style, breakBehavior: behavior)),
          .text(try InlineTextAtom(id: "b", text: " t a l l ", style: largerStyle)),
          .text(try InlineTextAtom(id: "c", text: "end", style: style)),
        ]
        let document = try InlinePreparation(shaper: FixedShaper(advance: 5))
          .prepare(document: InlineDocument(atoms: atoms))
        for width in [5.0, 10.0 - 1.0 / 128.0, 15.0, 37.0, 2_000.0] {
          let fast = try engine.layout(
            prepared: document,
            flow: region(width: width, height: 100_000), maximumLines: 3)
          let complete = try engine.layout(
            prepared: document,
            flow: region(width: width, exclusions: [outside], height: 100_000), maximumLines: 3)
          XCTAssertEqual(fast, complete, "behavior=\(behavior), width=\(width), text=\(text)")
          if let continuation = fast.continuation {
            let fastRemainder = try engine.layout(
              prepared: document,
              flow: region(width: width, height: 100_000), continuation: continuation)
            let completeRemainder = try engine.layout(
              prepared: document,
              flow: region(width: width, exclusions: [outside], height: 100_000),
              continuation: continuation)
            XCTAssertEqual(fastRemainder, completeRemainder)
          }
        }
      }
    }
  }

  func testExplicitInlineStylePreservesExistingFlowGeometry() throws {
    let rect = try InlineFlowRect(x: 0, y: 0, width: 100, height: 120)
    let exclusion = try InlineFlowExclusion(
      id: "host",
      rect: InlineFlowRect(x: 10, y: 0, width: 20, height: 20))
    let existing = try InlineFlowRegion(
      rect: rect,
      exclusions: [exclusion],
      revision: 7)
    let explicit = try InlineFlowRegion(
      rect: rect,
      exclusions: [exclusion],
      revision: 7,
      layoutStyle: .inline)

    XCTAssertEqual(existing, explicit)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    XCTAssertEqual(try encoder.encode(existing), try encoder.encode(explicit))
  }

  func testMagazineMediaWrapsAcrossRowsThenRecoversFullWidth() throws {
    let document = try prepared(String(repeating: "word ", count: 36))
    let minimumX = try InlineMagazineMedia(
      id: "thumbnail",
      rect: InlineFlowRect(x: 0, y: 0, width: 64, height: 68))
    let maximumX = try InlineMagazineMedia(
      id: "artwork",
      rect: InlineFlowRect(x: 170, y: 0, width: 70, height: 68))
    let style = try InlineMagazineStyle(
      minimumXMedia: [minimumX],
      maximumXMedia: [maximumX],
      mediaGap: 8,
      minimumTextWidth: 72)
    let flow = try InlineFlowRegion(
      rect: InlineFlowRect(x: 0, y: 0, width: 240, height: 240),
      revision: 1,
      layoutStyle: .magazine(style))
    let layout = try InlineLayoutEngine().layout(prepared: document, flow: flow)

    let mediaBottom = 68.0
    let wrapped = layout.lines.filter { $0.baselineY <= mediaBottom + 1.0 / 64.0 }
    XCTAssertGreaterThanOrEqual(wrapped.count, 2)
    XCTAssertTrue(
      wrapped.flatMap(\.atoms).allSatisfy { atom in
        atom.originX >= 72 - 1.0 / 64.0
          && atom.originX + atom.width <= 162 + 1.0 / 64.0
      })

    let recovered = layout.lines.filter { $0.baselineY > mediaBottom + 1.0 / 64.0 }
    XCTAssertFalse(recovered.isEmpty)
    XCTAssertTrue(recovered.flatMap(\.atoms).contains { $0.originX < 72 - 1.0 / 64.0 })
  }

  func testMagazineStyleMergesWithExistingHostExclusions() throws {
    let style = try InlineMagazineStyle(
      minimumXMedia: [
        InlineMagazineMedia(
          id: "thumbnail",
          rect: InlineFlowRect(x: 0, y: 0, width: 20, height: 30))
      ],
      mediaGap: 4,
      minimumTextWidth: 40)
    let host = try InlineFlowExclusion(
      id: "host",
      rect: InlineFlowRect(x: 60, y: 40, width: 20, height: 20))
    let flow = try InlineFlowRegion(
      rect: InlineFlowRect(x: 0, y: 0, width: 100, height: 120),
      exclusions: [host],
      revision: 1,
      layoutStyle: .magazine(style))

    XCTAssertEqual(flow.exclusions.count, 2)
    XCTAssertEqual(
      Set(flow.exclusions.map(\.id)), ["host", "$livetext.magazine.minimum-x.thumbnail"])
  }

  func testMagazineStyleRejectsInvalidEdgeAndTextWidth() throws {
    let notAnchored = try InlineMagazineStyle(
      minimumXMedia: [
        InlineMagazineMedia(
          id: "bad",
          rect: InlineFlowRect(x: 1, y: 0, width: 20, height: 20))
      ],
      minimumTextWidth: 40)
    XCTAssertThrowsError(
      try InlineFlowRegion(
        rect: InlineFlowRect(x: 0, y: 0, width: 100, height: 100),
        layoutStyle: .magazine(notAnchored)))

    let tooNarrow = try InlineMagazineStyle(
      minimumXMedia: [
        InlineMagazineMedia(
          id: "left",
          rect: InlineFlowRect(x: 0, y: 0, width: 45, height: 30))
      ],
      maximumXMedia: [
        InlineMagazineMedia(
          id: "right",
          rect: InlineFlowRect(x: 55, y: 0, width: 45, height: 30))
      ],
      mediaGap: 5,
      minimumTextWidth: 20)
    XCTAssertThrowsError(
      try InlineFlowRegion(
        rect: InlineFlowRect(x: 0, y: 0, width: 100, height: 100),
        layoutStyle: .magazine(tooNarrow)))
  }

  func testMagazineStyleRejectsDuplicateMediaIDsAndZeroSizedMedia() throws {
    let media = try InlineMagazineMedia(
      id: "same",
      rect: InlineFlowRect(x: 0, y: 0, width: 20, height: 20))
    XCTAssertThrowsError(
      try InlineMagazineStyle(minimumXMedia: [media], maximumXMedia: [media]))
    XCTAssertThrowsError(
      try InlineMagazineMedia(
        id: "zero",
        rect: InlineFlowRect(x: 0, y: 0, width: 0, height: 20)))
  }

  func testMagazineContinuationRejectsChangedFlowRevision() throws {
    let document = try prepared(String(repeating: "word ", count: 30))
    let style = try InlineMagazineStyle(
      minimumXMedia: [
        InlineMagazineMedia(
          id: "thumbnail",
          rect: InlineFlowRect(x: 0, y: 0, width: 30, height: 60))
      ],
      mediaGap: 4,
      minimumTextWidth: 50)
    let firstFlow = try InlineFlowRegion(
      rect: InlineFlowRect(x: 0, y: 0, width: 120, height: 240),
      revision: 1,
      layoutStyle: .magazine(style))
    let first = try InlineLayoutEngine().layout(
      prepared: document,
      flow: firstFlow,
      maximumLines: 1)
    let continuation = try XCTUnwrap(first.continuation)
    let changedFlow = try InlineFlowRegion(
      rect: InlineFlowRect(x: 0, y: 0, width: 120, height: 240),
      revision: 2,
      layoutStyle: .magazine(style))

    XCTAssertThrowsError(
      try InlineLayoutEngine().layout(
        prepared: document,
        flow: changedFlow,
        continuation: continuation))
  }

}
