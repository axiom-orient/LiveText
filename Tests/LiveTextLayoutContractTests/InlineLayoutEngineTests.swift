import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineLayoutEngineTests: XCTestCase {
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
      let metrics = try InlineMetrics(
        advance: advance * Double(ranges.count),
        ascent: style.font.pointSize,
        descent: 2,
        baselineOffset: style.baselineOffset
      )
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: advance, count: ranges.count),
        runs: [],
        metrics: metrics
      )
    }
  }

  private struct LigatureShaper: InlineTextShaping {
    func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
      -> InlineShapedText
    {
      guard text == "fi" else { throw InlineLayoutError.unsupportedShaping("fixture") }
      let clusterRange = try InlineSourceRange(
        startUTF16: sourceRange.startUTF16,
        endUTF16: sourceRange.endUTF16
      )
      let glyph = try InlineGlyph(
        glyphID: 1,
        positionX: 0,
        positionY: 0,
        sourceUTF16Index: sourceRange.startUTF16,
        sourceRange: clusterRange
      )
      let run = try InlineShapedRun(
        glyphs: [glyph],
        font: style.font,
        sourceRange: clusterRange,
        advance: 2,
        ascent: style.font.pointSize,
        descent: 2
      )
      return try InlineShapedText(
        graphemeRanges: [
          try InlineSourceRange(
            startUTF16: sourceRange.startUTF16, endUTF16: sourceRange.startUTF16 + 1),
          try InlineSourceRange(
            startUTF16: sourceRange.endUTF16 - 1, endUTF16: sourceRange.endUTF16),
        ],
        graphemeAdvances: [2, 0],
        runs: [run],
        metrics: try InlineMetrics(
          advance: 2,
          ascent: style.font.pointSize,
          descent: 2,
          baselineOffset: style.baselineOffset
        )
      )
    }
  }

  private func style(size: Double = 10) throws -> InlineTextStyle {
    try InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: size))
  }

  func testTextVectorTextSharesOneGreedyLayout() throws {
    let textStyle = try style()
    let text1 = try InlineAtom.text(InlineTextAtom(id: "left", text: "ab", style: textStyle))
    let assetID = try InlineAssetID(rawValue: "dot")
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "dot-atom",
        assetID: assetID,
        metrics: try InlineMetrics(advance: 3, ascent: 8, descent: 2)
      ))
    let text2 = try InlineAtom.text(InlineTextAtom(id: "right", text: "cd", style: textStyle))
    let document = try InlineDocument(atoms: [text1, vector, text2])
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 4)).prepare(
      document: document)
    let engine = try InlineLayoutEngine()
    let result = try engine.layout(prepared: prepared, width: 11)

    XCTAssertEqual(result.lines.count, 2)
    XCTAssertEqual(result.lines[0].atoms.map(\.atomID), ["left", "dot-atom"])
    XCTAssertEqual(result.lines[1].atoms.map(\.atomID), ["right"])
    XCTAssertEqual(
      result.lines[0].atoms[0].sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 2))
    XCTAssertEqual(result.lines[0].atoms[1].originX, 8, accuracy: 0.0001)
  }

  func testLayoutKeepsLigatureClusterOnOneLine() throws {
    let atom = try InlineAtom.text(InlineTextAtom(id: "ligature", text: "fi", style: try style()))
    let prepared = try InlinePreparation(shaper: LigatureShaper()).prepare(
      document: InlineDocument(atoms: [atom]))

    let result = try InlineLayoutEngine().layout(prepared: prepared, width: 1)

    XCTAssertEqual(result.lines.count, 1)
    XCTAssertEqual(result.lines[0].atoms.count, 1)
    XCTAssertEqual(result.lines[0].width, 2, accuracy: 0.0001)
    XCTAssertEqual(
      result.lines[0].atoms[0].sourceRange,
      try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    )
  }

  func testZeroAdvanceClusterTailPreservesContinuationBoundary() throws {
    let atom = try InlineAtom.text(InlineTextAtom(id: "ligature", text: "fi x", style: try style()))
    let prepared = try InlinePreparation(shaper: LigatureAndTailShaper()).prepare(
      document: InlineDocument(atoms: [atom]))
    let engine = try InlineLayoutEngine()

    let first = try engine.layout(prepared: prepared, width: 2, maximumLines: 1)
    XCTAssertEqual(first.lines[0].width, 2, accuracy: 0.0001)
    XCTAssertEqual(first.lines[0].end, InlineCursor(atomIndex: 0, graphemeIndex: 3))
    guard let continuation = first.continuation else {
      return XCTFail("expected continuation after the zero-advance cluster")
    }

    let tail = try engine.layoutTail(
      prepared: prepared, from: continuation, width: 2, maximumLines: 1)
    XCTAssertEqual(tail.lines[0].start, InlineCursor(atomIndex: 0, graphemeIndex: 3))
    XCTAssertEqual(tail.lines[0].end, InlineCursor(atomIndex: 1, graphemeIndex: 0))
  }

  func testHardBreakDoesNotCreateFakePlacedAtom() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(
        id: "text",
        text: "a\nb",
        style: try style()
      ))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 4))
      .prepare(document: InlineDocument(atoms: [atom]))
    let result = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertEqual(result.lines.count, 2)
    XCTAssertEqual(
      result.lines.flatMap(\.atoms).map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 2, endUTF16: 3),
      ])
  }

  func testHardBreakSkipsEmptyAtomBeforeFollowingContent() throws {
    let first = try InlineAtom.text(
      InlineTextAtom(id: "first", text: "a\n", style: try style()))
    let empty = try InlineAtom.text(
      InlineTextAtom(id: "empty", text: "", style: try style()))
    let last = try InlineAtom.text(
      InlineTextAtom(id: "last", text: "b", style: try style()))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 4)).prepare(
      document: InlineDocument(atoms: [first, empty, last]))

    let result = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertEqual(result.lines.count, 2)
    XCTAssertNil(result.continuation)
    XCTAssertEqual(result.lines[0].start, InlineCursor(atomIndex: 0, graphemeIndex: 0))
    XCTAssertEqual(result.lines[0].end, InlineCursor(atomIndex: 0, graphemeIndex: 1))
    XCTAssertEqual(result.lines[0].atoms.map(\.atomID), ["first"])
    XCTAssertEqual(
      result.lines[0].atoms.map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1)
      ])
    XCTAssertEqual(result.lines[1].start, InlineCursor(atomIndex: 2, graphemeIndex: 0))
    XCTAssertEqual(result.lines[1].end, InlineCursor(atomIndex: 3, graphemeIndex: 0))
    XCTAssertEqual(result.lines[1].atoms.map(\.atomID), ["last"])
    XCTAssertEqual(
      result.lines[1].atoms.map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 2, endUTF16: 3)
      ])
  }

  func testTerminalHardBreakResumesAsOneEmptyTailLine() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "a\n", style: try style()))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 4)).prepare(
      document: InlineDocument(atoms: [atom]))
    let engine = try InlineLayoutEngine()

    let first = try engine.layout(prepared: prepared, width: 20, maximumLines: 1)

    XCTAssertEqual(first.lines.count, 1)
    XCTAssertEqual(first.lines[0].start, InlineCursor(atomIndex: 0, graphemeIndex: 0))
    XCTAssertEqual(first.lines[0].end, InlineCursor(atomIndex: 0, graphemeIndex: 1))
    XCTAssertEqual(
      first.lines[0].atoms.map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1)
      ])
    let continuation = try XCTUnwrap(first.continuation)
    XCTAssertEqual(continuation.cursor, InlineCursor(atomIndex: 0, graphemeIndex: 1))

    let tail = try engine.layoutTail(
      prepared: prepared, from: continuation, width: 20, maximumLines: 1)

    XCTAssertEqual(tail.lines.count, 1)
    XCTAssertEqual(tail.lines[0].start, InlineCursor(atomIndex: 0, graphemeIndex: 1))
    XCTAssertEqual(tail.lines[0].end, InlineCursor(atomIndex: 1, graphemeIndex: 0))
    XCTAssertTrue(tail.lines[0].atoms.isEmpty)
    XCTAssertNil(tail.continuation)
  }

  func testOversizedVectorPolicyIsExplicit() throws {
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "wide",
        assetID: try InlineAssetID(rawValue: "wide-asset"),
        metrics: try InlineMetrics(advance: 20, ascent: 4, descent: 1)
      ))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 1))
      .prepare(document: InlineDocument(atoms: [vector]))

    XCTAssertThrowsError(try InlineLayoutEngine().layout(prepared: prepared, width: 10))
    let scaled = try InlineLayoutEngine(oversizedVectorPolicy: .scaleToFit(minimumScale: 0.25))
      .layout(prepared: prepared, width: 10)
    XCTAssertEqual(scaled.lines[0].atoms[0].scale, 0.5, accuracy: 0.0001)
    XCTAssertEqual(scaled.lines[0].atoms[0].width, 10, accuracy: 0.0001)
  }

  func testOneAssetCanBeReusedByMultipleVectorAtoms() throws {
    let assetID = try InlineAssetID(rawValue: "dot")
    let metrics = try InlineMetrics(advance: 3, ascent: 2, descent: 1)
    let first = try InlineAtom.vector(
      InlineVectorAtom(id: "first", assetID: assetID, metrics: metrics))
    let second = try InlineAtom.vector(
      InlineVectorAtom(id: "second", assetID: assetID, metrics: metrics))

    XCTAssertNoThrow(try InlineDocument(atoms: [first, second]))
  }

  func testPreparationAndLayoutHonorCancellation() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "abc", style: try style()))
    let document = try InlineDocument(atoms: [atom])
    let preparation = InlinePreparation(shaper: FixedShaper(advance: 1))

    XCTAssertThrowsError(
      try preparation.prepare(
        document: document, cancellation: { throw InlineLayoutError.cancelled })
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertThrowsError(try preparation.prepare(document: document, cancellation: {})) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("expected a typed cancellable-shaper error")
      }
    }

    let prepared = try preparation.prepare(document: document)
    XCTAssertThrowsError(
      try InlineLayoutEngine().layout(
        prepared: prepared,
        width: 20,
        cancellation: { throw InlineLayoutError.cancelled }
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
  }

  func testTrailingEmptyTextDoesNotPublishContinuation() throws {
    let first = try InlineAtom.text(InlineTextAtom(id: "first", text: "a", style: try style()))
    let empty = try InlineAtom.text(InlineTextAtom(id: "empty", text: "", style: try style()))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 1)).prepare(
      document: InlineDocument(atoms: [first, empty]))

    let result = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertNil(result.continuation)
  }

  func testContinuationRejectsDifferentLeading() throws {
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "a b c", style: try style()))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 2))
      .prepare(document: InlineDocument(atoms: [atom]))
    let first = try InlineLayoutEngine(leading: 2)
      .layout(prepared: prepared, width: 4, maximumLines: 1)
    guard let continuation = first.continuation else {
      return XCTFail("expected a bounded continuation")
    }

    XCTAssertThrowsError(
      try InlineLayoutEngine().layout(
        prepared: prepared,
        width: 4,
        continuation: continuation,
        maximumLines: 1
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidContinuation)
    }
  }

  func testContinuationCannotCrossPreparationRevision() throws {
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "abc", style: try style()))
    let continuation = InlineLayoutContinuation(
      cursor: .zero,
      preparationRevision: "different",
      width: 4,
      oversizedVectorPolicy: .reject
    )
    let changed = try InlinePreparation(shaper: FixedShaper(advance: 5))
      .prepare(document: InlineDocument(atoms: [atom]))
    XCTAssertThrowsError(
      try InlineLayoutEngine().layout(
        prepared: changed,
        width: 4,
        continuation: continuation
      ))
  }

  func testBoundedLayoutResumesAtLogicalCursor() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(
        id: "text", text: "a b c", style: try style()))
    let prepared = try InlinePreparation(shaper: FixedShaper(advance: 4))
      .prepare(document: InlineDocument(atoms: [atom]))
    let engine = try InlineLayoutEngine()
    let first = try engine.layout(prepared: prepared, width: 8, maximumLines: 1)
    guard let continuation = first.continuation else {
      return XCTFail("expected a bounded continuation")
    }
    let second = try engine.layoutTail(
      prepared: prepared, from: continuation, width: 8, maximumLines: 1)

    XCTAssertEqual(first.lines.count, 1)
    XCTAssertEqual(
      first.lines[0].atoms[0].sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 2))
    XCTAssertEqual(
      second.lines[0].atoms[0].sourceRange, try InlineSourceRange(startUTF16: 2, endUTF16: 4))
  }

  #if canImport(CoreText)
    func testDefaultPreparationUsesCoreTextShaping() throws {
      let atom = try InlineAtom.text(
        InlineTextAtom(
          id: "text",
          text: "Hello, 세계",
          style: try style(size: 14)
        ))
      let prepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [atom])
      )
      XCTAssertGreaterThan(prepared.totalGlyphs, 0)
      XCTAssertEqual(prepared.totalGraphemes, Array("Hello, 세계").count)
    }

    func testCoreTextDefaultShaperWidthAndNoExclusionFlowParity() throws {
      let atom = try InlineAtom.text(
        InlineTextAtom(
          id: "text",
          text: "Alpha beta gamma delta",
          style: try style(size: 14)
        ))
      let prepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [atom])
      )
      let engine = try InlineLayoutEngine()
      let width = 80.0
      let widthLayout = try engine.layout(prepared: prepared, width: width)
      let flow = try InlineFlowRegion(
        rect: try InlineFlowRect(x: 0, y: 0, width: width, height: 200)
      )
      let flowLayout = try engine.layout(prepared: prepared, flow: flow)

      XCTAssertEqual(widthLayout.lines, flowLayout.lines)
      XCTAssertEqual(widthLayout.width, flowLayout.width, accuracy: 1.0 / 64.0)
      XCTAssertEqual(widthLayout.height, flowLayout.height, accuracy: 1.0 / 64.0)
      XCTAssertEqual(widthLayout.preparationRevision, flowLayout.preparationRevision)
    }

    func testCoreTextShaperMapsCombiningGrapheme() throws {
      let style = try style(size: 14)
      let source = "e\u{301}"
      let shaped = try CoreTextInlineShaper().shape(
        text: source,
        style: style,
        sourceRange: try InlineSourceRange(startUTF16: 0, endUTF16: source.utf16.count)
      )
      XCTAssertEqual(shaped.graphemeRanges.count, 1)
      XCTAssertEqual(shaped.graphemeAdvances.count, 1)
      XCTAssertFalse(shaped.runs.isEmpty)
      XCTAssertTrue(shaped.runs.allSatisfy { !$0.glyphs.isEmpty })
    }

    func testCoreTextRTLRunClustersStayWithinTheirRun() throws {
      let source = "אבגx"
      let shaped = try CoreTextInlineShaper().shape(
        text: source,
        style: try style(size: 14),
        sourceRange: try InlineSourceRange(startUTF16: 0, endUTF16: source.utf16.count)
      )

      XCTAssertTrue(
        shaped.runs
          .flatMap(\.glyphs)
          .filter { $0.sourceUTF16Index < 6 }
          .allSatisfy { $0.sourceRange.endUTF16 <= 6 }
      )
    }

    func testCoreTextMixedTextVectorTextKeepsCoreTextBreakBoundaries() throws {
      let first = try InlineAtom.text(
        InlineTextAtom(id: "first", text: "Alpha, beta ", style: try style(size: 14)))
      let vector = try InlineAtom.vector(
        InlineVectorAtom(
          id: "marker",
          assetID: try InlineAssetID(rawValue: "marker"),
          metrics: try InlineMetrics(advance: 8, ascent: 10, descent: 2)
        ))
      let last = try InlineAtom.text(
        InlineTextAtom(id: "last", text: "gamma, delta", style: try style(size: 14)))
      let prepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [first, vector, last]))
      let result = try InlineLayoutEngine().layout(prepared: prepared, width: 70)

      var breaksByID: [String: Set<Int>] = [:]
      for atom in prepared.atoms {
        guard case .text(let text) = atom else { continue }
        breaksByID[text.atom.id] = Set(text.textBreakEnds)
      }
      let positioned = result.lines.flatMap(\.atoms)
      XCTAssertTrue(positioned.contains { $0.kind == .vector && $0.atomID == "marker" })
      for atom in positioned where atom.kind == .text {
        guard let range = atom.sourceRange, let allowed = breaksByID[atom.atomID] else {
          return XCTFail("expected prepared text boundary metadata")
        }
        XCTAssertTrue(allowed.contains(range.endUTF16), "unexpected mixed boundary: \(atom)")
      }
    }

    func testCoreTextLayoutMatchesCoreTextLineCount() throws {
      let engine = LiveTextEngine.appleDefault()
      for source in ["Alpha, beta gamma", "你好世界你好", "one—two, three"] {
        let atom = try InlineAtom.text(
          InlineTextAtom(id: "text", text: source, style: try style(size: 14)))
        let document = try InlineDocument(atoms: [atom])
        let prepared = try InlinePreparation().prepare(document: document)
        guard case .text(let inlineText) = prepared.atoms[0],
          let textKernelPrepared = inlineText.textKernelPrepared
        else {
          return XCTFail("expected LiveTextCore preparation")
        }
        let width = 70.0
        var cursor = LayoutCursor.zero
        var expectedStarts: [InlineCursor] = []
        var expectedEnds: [InlineCursor] = []
        while let range = try engine.layoutNextLineRange(
          prepared: textKernelPrepared, start: cursor, maxWidth: width
        ) {
          expectedStarts.append(
            try inlineCursor(
              for: coreTextOffset(range.start, prepared: textKernelPrepared), source: source)
          )
          expectedEnds.append(
            try inlineCursor(
              for: coreTextOffset(range.end, prepared: textKernelPrepared), source: source)
          )
          cursor = range.end
        }

        let result = try InlineLayoutEngine().layout(prepared: prepared, width: width)
        XCTAssertEqual(result.lines.map(\.start), expectedStarts, source)
        XCTAssertEqual(result.lines.map(\.end), expectedEnds, source)
        XCTAssertTrue(result.lines.allSatisfy { $0.width <= width + 1.0 / 64.0 }, source)
      }
    }

    func testCoreTextFastPathSkipsEmptyTextAndSpecialPolicies() throws {
      let empty = try InlineAtom.text(
        InlineTextAtom(id: "empty", text: "", style: try style(size: 14)))
      let emptyPrepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [empty]))
      let emptyResult = try InlineLayoutEngine().layout(prepared: emptyPrepared, width: 40)
      XCTAssertTrue(emptyResult.lines.isEmpty)
      XCTAssertNil(emptyResult.continuation)

      let trackingStyle = try InlineTextStyle(
        font: FontDescriptor(postScriptName: "Helvetica", pointSize: 14), tracking: 1)
      let tracked = try InlineAtom.text(
        InlineTextAtom(id: "tracked", text: "ab", style: trackingStyle))
      let trackedPrepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [tracked]))
      guard case .text(let trackedText) = trackedPrepared.atoms[0] else {
        return XCTFail("expected text preparation")
      }
      XCTAssertNil(trackedText.textKernelPrepared)

      let ordinary = try InlineDocument(atoms: [
        .text(
          InlineTextAtom(
            id: "ordinary",
            text: "alpha beta gamma delta",
            style: try style(size: 14)
          ))
      ])
      let fullPrepared = try InlinePreparation().prepare(document: ordinary)
      let cancellablePrepared = try InlinePreparation().prepare(
        document: ordinary, cancellation: {})
      guard case .text(let fullText) = fullPrepared.atoms[0],
        case .text(let cancellableText) = cancellablePrepared.atoms[0]
      else {
        return XCTFail("expected text preparation")
      }
      XCTAssertNotNil(fullText.textKernelPrepared)
      XCTAssertNil(cancellableText.textKernelPrepared)
      XCTAssertNotEqual(fullPrepared.revision, cancellablePrepared.revision)

      let boundedFirst = try InlineLayoutEngine().layout(
        prepared: cancellablePrepared, width: 20, maximumLines: 1)
      let fullFirst = try InlineLayoutEngine().layout(
        prepared: fullPrepared, width: 20, maximumLines: 1)
      if let fullContinuation = fullFirst.continuation {
        XCTAssertThrowsError(
          try InlineLayoutEngine().layoutTail(
            prepared: cancellablePrepared,
            from: fullContinuation,
            width: 20
          )
        )
      }
      if let boundedContinuation = boundedFirst.continuation {
        XCTAssertThrowsError(
          try InlineLayoutEngine().layoutTail(
            prepared: fullPrepared,
            from: boundedContinuation,
            width: 20
          )
        )
      }

      let vector = try InlineAtom.vector(
        InlineVectorAtom(
          id: "vector-only",
          assetID: try InlineAssetID(rawValue: "vector-only"),
          metrics: try InlineMetrics(advance: 4, ascent: 2, descent: 1)
        ))
      XCTAssertNoThrow(
        try InlinePreparation(shaper: FixedShaper(advance: 1)).prepare(
          document: InlineDocument(atoms: [vector]),
          cancellation: {}
        )
      )

      let keepTogether = try InlineAtom.text(
        InlineTextAtom(
          id: "keep",
          text: "ab",
          style: try style(size: 14),
          breakBehavior: .keepTogether
        ))
      let keepPrepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [keepTogether]))
      let keepResult = try InlineLayoutEngine().layout(prepared: keepPrepared, width: 40)
      XCTAssertEqual(keepResult.lines.count, 1)
    }

    func testCoreTextContinuationMatchesCoreTextCursor() throws {
      let source = "  alpha beta gamma"
      let atom = try InlineAtom.text(
        InlineTextAtom(id: "text", text: source, style: try style(size: 14)))
      let prepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [atom]))
      guard case .text(let inlineText) = prepared.atoms[0],
        let textKernelPrepared = inlineText.textKernelPrepared
      else {
        return XCTFail("expected LiveTextCore preparation")
      }
      let textEngine = LiveTextEngine.appleDefault()
      let width = 40.0
      guard
        let firstRange = try textEngine.layoutNextLineRange(
          prepared: textKernelPrepared, start: .zero, maxWidth: width
        )
      else {
        return XCTFail("expected first CoreText line")
      }
      guard
        let secondRange = try textEngine.layoutNextLineRange(
          prepared: textKernelPrepared, start: firstRange.end, maxWidth: width
        )
      else {
        return XCTFail("expected second CoreText line")
      }

      let engine = try InlineLayoutEngine()
      let first = try engine.layout(prepared: prepared, width: width, maximumLines: 1)
      guard let continuation = first.continuation else {
        return XCTFail("expected inline continuation")
      }
      XCTAssertEqual(continuation.flowRevision, 0)
      XCTAssertEqual(continuation.nextY, first.height, accuracy: 1.0 / 64.0)
      XCTAssertEqual(
        first.lines[0].start,
        try inlineCursor(
          for: coreTextOffset(firstRange.start, prepared: textKernelPrepared), source: source))
      XCTAssertEqual(
        first.lines[0].end,
        try inlineCursor(
          for: coreTextOffset(firstRange.end, prepared: textKernelPrepared), source: source))

      let second = try engine.layoutTail(
        prepared: prepared, from: continuation, width: width, maximumLines: 1)
      XCTAssertEqual(
        second.lines[0].baselineY - second.lines[0].ascent,
        continuation.nextY,
        accuracy: 1.0 / 64.0
      )
      XCTAssertEqual(
        second.lines[0].start,
        try inlineCursor(
          for: coreTextOffset(secondRange.start, prepared: textKernelPrepared), source: source))
      XCTAssertEqual(
        second.lines[0].end,
        try inlineCursor(
          for: coreTextOffset(secondRange.end, prepared: textKernelPrepared), source: source))
    }

    private func coreTextOffset(_ cursor: LayoutCursor, prepared: PreparedText) -> Int {
      guard cursor.segmentIndex < prepared.segments.count else {
        return prepared.normalized.utf16.count
      }
      let segment = prepared.segments[cursor.segmentIndex]
      return segment.startUTF16 + String(segment.text.prefix(cursor.graphemeIndex)).utf16.count
    }

    private func inlineCursor(for offset: Int, source: String) throws -> InlineCursor {
      var consumed = 0
      for (index, grapheme) in source.enumerated() {
        if consumed == offset { return InlineCursor(atomIndex: 0, graphemeIndex: index) }
        consumed += String(grapheme).utf16.count
        if consumed == offset {
          let atomIndex = index + 1 == source.count ? 1 : 0
          let graphemeIndex = atomIndex == 1 ? 0 : index + 1
          return InlineCursor(atomIndex: atomIndex, graphemeIndex: graphemeIndex)
        }
      }
      guard consumed == offset else { throw InlineLayoutError.invalidRenderPlan }
      return InlineCursor(atomIndex: 1, graphemeIndex: 0)
    }
  #endif
}

private struct LigatureAndTailShaper: InlineTextShaping {
  func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
    -> InlineShapedText
  {
    guard text == "fi x" else { throw InlineLayoutError.unsupportedShaping("fixture") }
    let cluster = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let space = try InlineSourceRange(startUTF16: 2, endUTF16: 3)
    let tail = try InlineSourceRange(startUTF16: 3, endUTF16: 4)
    let clusterGlyph = try InlineGlyph(
      glyphID: 1,
      positionX: 0,
      positionY: 0,
      sourceUTF16Index: 0,
      sourceRange: cluster
    )
    let spaceGlyph = try InlineGlyph(
      glyphID: 2,
      positionX: 2,
      positionY: 0,
      sourceUTF16Index: 2,
      sourceRange: space
    )
    let tailGlyph = try InlineGlyph(
      glyphID: 3,
      positionX: 2,
      positionY: 0,
      sourceUTF16Index: 3,
      sourceRange: tail
    )
    let run = try InlineShapedRun(
      glyphs: [clusterGlyph, spaceGlyph, tailGlyph],
      font: style.font,
      sourceRange: try InlineSourceRange(startUTF16: 0, endUTF16: 4),
      advance: 3,
      ascent: style.font.pointSize,
      descent: 2
    )
    return try InlineShapedText(
      graphemeRanges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
        space,
        tail,
      ],
      graphemeAdvances: [2, 0, 0, 1],
      runs: [run],
      metrics: try InlineMetrics(advance: 3, ascent: style.font.pointSize, descent: 2)
    )
  }
}
