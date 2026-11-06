import Foundation
import LiveTextCore
import XCTest

@testable import LiveTextLayout

final class InlineWritingFaceTests: XCTestCase {
  private struct Face: InlineWritingFace {
    let id: String
    let version = "test-1"

    func glyph(for character: Character) throws -> InlineWritingGlyph? {
      switch character {
      case "A":
        return try InlineWritingGlyph(
          character: "A",
          advance: 1,
          strokes: [
            try InlineWritingStroke(points: [
              try InlineNormalizedWritingPoint(x: 0.1, y: 0.9),
              try InlineNormalizedWritingPoint(x: 0.5, y: 0.1),
            ]),
            try InlineWritingStroke(points: [
              try InlineNormalizedWritingPoint(x: 0.5, y: 0.1),
              try InlineNormalizedWritingPoint(x: 0.9, y: 0.9),
            ]),
          ]
        )
      case "한":
        return try InlineWritingGlyph(
          character: "한",
          advance: 1,
          strokes: [
            try InlineWritingStroke(points: [
              try InlineNormalizedWritingPoint(x: 0.1, y: 0.1),
              try InlineNormalizedWritingPoint(x: 0.9, y: 0.1),
            ]),
            try InlineWritingStroke(points: [
              try InlineNormalizedWritingPoint(x: 0.1, y: 0.9),
              try InlineNormalizedWritingPoint(x: 0.9, y: 0.9),
            ]),
          ]
        )
      default:
        return nil
      }
    }
  }

  private struct Shaper: CancellableInlineTextShaping {
    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      var ranges: [InlineSourceRange] = []
      var glyphs: [InlineGlyph] = []
      var offset = sourceRange.startUTF16
      for (index, grapheme) in text.enumerated() {
        let length = String(grapheme).utf16.count
        let range = try InlineSourceRange(startUTF16: offset, endUTF16: offset + length)
        ranges.append(range)
        glyphs.append(
          try InlineGlyph(
            glyphID: UInt16(index),
            positionX: Double(index),
            positionY: 0,
            sourceUTF16Index: offset,
            sourceRange: range
          )
        )
        offset += length
      }
      let metrics = try InlineMetrics(
        advance: Double(ranges.count),
        ascent: style.font.pointSize,
        descent: 2,
        baselineOffset: style.baselineOffset
      )
      let runs: [InlineShapedRun]
      if let first = ranges.first, let last = ranges.last {
        runs = [
          try InlineShapedRun(
            glyphs: glyphs,
            font: style.font,
            sourceRange: try InlineSourceRange(
              startUTF16: first.startUTF16, endUTF16: last.endUTF16),
            advance: metrics.advance,
            ascent: metrics.ascent,
            descent: metrics.descent
          )
        ]
      } else {
        runs = []
      }
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: 1, count: ranges.count),
        runs: runs,
        metrics: metrics
      )
    }

    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange,
      cancellation: InlineCancellationCheck
    ) throws -> InlineShapedText {
      try cancellation()
      return try shape(text: text, style: style, sourceRange: sourceRange)
    }
  }

  func testHandwritingPreparationPreservesLatinHangulOrderAndEmojiAtomicity() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: .handwriting(faceID: "test-face")
    )
    let atom = try InlineTextAtom(id: "text", text: "A😀 한", style: style)
    let faces = try InlineWritingFaceStore(faces: [Face(id: "test-face")])
    let prepared = try InlinePreparation(shaper: Shaper(), writingFaceStore: faces).prepare(
      document: InlineDocument(atoms: [.text(atom)])
    )
    guard case .text(let text) = prepared.atoms[0] else {
      return XCTFail("expected text")
    }
    XCTAssertEqual(text.writingUnits.count, 6)
    XCTAssertEqual(text.writingUnits[0].sourceRange, text.writingUnits[1].sourceRange)
    XCTAssertNotEqual(text.writingUnits[0].id, text.writingUnits[1].id)
    if case .nativeAtomic = text.writingUnits[2].kind {
    } else {
      XCTFail("emoji must remain atomic")
    }
    if case .timingOnly = text.writingUnits[3].kind {
    } else {
      XCTFail("space must remain timing-only")
    }
    if case .semanticStroke = text.writingUnits[4].kind {
    } else {
      XCTFail("Hangul must use semantic strokes")
    }
  }

  func testTextPlanUsesPreparedUnitsAndUnitProgressDisambiguatesRepeatedRanges() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: .handwriting(faceID: "test-face")
    )
    let atom = try InlineTextAtom(id: "text", text: "A", style: style)
    let faces = try InlineWritingFaceStore(faces: [Face(id: "test-face")])
    let prepared = try InlinePreparation(shaper: Shaper(), writingFaceStore: faces).prepare(
      document: InlineDocument(atoms: [.text(atom)])
    )
    let plan = try InlineRevealPlanBuilder(secondsPerUnit: 1).textPlan(prepared: prepared)
    XCTAssertTrue(plan.units.allSatisfy { $0.kind == .semanticStroke })
    XCTAssertEqual(plan.units[0].sourceRange, plan.units[1].sourceRange)
    let activation = try InlineRenderRevealTextActivation(
      atomID: "text",
      units: try plan.units.map { try InlineRenderRevealTextUnit(unit: $0) }
    )
    let phase = try InlineRenderRevealPhase(rawValue: 0.5)
    XCTAssertEqual(activation.progress(at: phase, unitID: plan.units[0].id), 1)
    XCTAssertEqual(activation.progress(at: phase, unitID: plan.units[1].id), 0)
    let sourceRange = try XCTUnwrap(plan.units[0].sourceRange)
    XCTAssertEqual(
      activation.progress(at: phase, sourceRange: sourceRange), 1
    )
  }

  func testWritingFaceFailuresAndHardCutStyleSchemaAreTyped() throws {
    XCTAssertThrowsError(
      try InlineWritingFaceStore(faces: [Face(id: "same"), Face(id: "same")])
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .duplicateWritingFace("same"))
    }
    XCTAssertThrowsError(
      try InlineNormalizedWritingPoint(x: 1.1, y: 0.5)
    ) { error in
      guard case .invalidWritingPoint(field: "x", value: 1.1) = error as? InlineLayoutError else {
        return XCTFail("expected normalized point error")
      }
    }
    let oldStyle = Data(
      "{\"font\":{\"postScriptName\":\"Helvetica\",\"pointSize\":12},\"tracking\":0,\"baselineOffset\":0}"
        .utf8
    )
    XCTAssertThrowsError(try JSONDecoder().decode(InlineTextStyle.self, from: oldStyle))

    let handwritingStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: .handwriting(faceID: "missing")
    )
    let missingAtom = try InlineTextAtom(id: "missing-face", text: "A", style: handwritingStyle)
    XCTAssertThrowsError(
      try InlinePreparation(shaper: Shaper()).prepare(
        document: InlineDocument(atoms: [.text(missingAtom)])
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .missingWritingFace(faceID: "missing", atomID: "missing-face", glyph: "A")
      )
    }

    let unsupportedAtom = try InlineTextAtom(
      id: "unsupported",
      text: "!",
      style: try InlineTextStyle(
        font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
        revealMode: .handwriting(faceID: "test-face")
      )
    )
    let faces = try InlineWritingFaceStore(faces: [Face(id: "test-face")])
    XCTAssertThrowsError(
      try InlinePreparation(shaper: Shaper(), writingFaceStore: faces).prepare(
        document: InlineDocument(atoms: [.text(unsupportedAtom)])
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .unsupportedWritingGlyph(faceID: "test-face", glyph: "!")
      )
    }
  }

  func testKeycapClassifierRequiresExactGrammar() {
    XCTAssertFalse(inlineIsNativeEmoji("A\u{20E3}"))
    XCTAssertTrue(inlineIsNativeEmoji("1\u{FE0F}\u{20E3}"))
    XCTAssertTrue(inlineIsNativeEmoji("#\u{20E3}"))
    XCTAssertFalse(inlineIsNativeEmoji("12\u{20E3}"))
  }

  func testAppendEnforcesWritingLimitsAcrossBatchesWithoutMutatingOnFailure() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: .handwriting(faceID: "test-face"))
    let faces = try InlineWritingFaceStore(faces: [Face(id: "test-face")])
    let limits = InlinePreparationLimits(
      maximumWritingStrokes: 3, maximumWritingPoints: 100)
    let preparation = InlinePreparation(
      shaper: Shaper(), limits: limits, writingFaceStore: faces)

    let firstAtom = try InlineAtom.text(InlineTextAtom(id: "first", text: "A", style: style))
    let secondAtom = try InlineAtom.text(InlineTextAtom(id: "second", text: "A", style: style))
    XCTAssertThrowsError(
      try preparation.prepare(document: InlineDocument(atoms: [firstAtom, secondAtom]))
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .resourceLimitExceeded(resource: "writing strokes", actual: 4, limit: 3))
    }

    var reducer = try InlineAppendReducer(
      preparation: preparation, engine: InlineLayoutEngine(), width: 10)
    let firstEvent = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: reducer.streamID, sequence: reducer.nextSequence,
        baseRevision: reducer.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: firstAtom)]
      ))
    let firstDelta = try reducer.apply(firstEvent)
    XCTAssertEqual(try reducer.apply(firstEvent), firstDelta)

    let committedRevision = reducer.revision
    let committedSequence = reducer.nextSequence
    let secondEvent = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: reducer.streamID, sequence: reducer.nextSequence,
        baseRevision: reducer.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: secondAtom)]
      ))
    XCTAssertThrowsError(try reducer.apply(secondEvent)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .resourceLimitExceeded(resource: "writing strokes", actual: 4, limit: 3))
    }
    XCTAssertEqual(reducer.revision, committedRevision)
    XCTAssertEqual(reducer.nextSequence, committedSequence)
  }

  func testAppendEnforcesWritingPointLimitAcrossBatches() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: .handwriting(faceID: "test-face"))
    let faces = try InlineWritingFaceStore(faces: [Face(id: "test-face")])
    let preparation = InlinePreparation(
      shaper: Shaper(),
      limits: InlinePreparationLimits(maximumWritingStrokes: 10, maximumWritingPoints: 6),
      writingFaceStore: faces)
    var reducer = try InlineAppendReducer(
      preparation: preparation, engine: InlineLayoutEngine(), width: 10)

    for (index, id) in ["first", "second"].enumerated() {
      let atom = try InlineAtom.text(InlineTextAtom(id: id, text: "A", style: style))
      let event = InlineAppendEvent.append(
        InlineAppendBatch(
          streamID: reducer.streamID, sequence: reducer.nextSequence,
          baseRevision: reducer.revision,
          atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)]
        ))
      if index == 0 {
        XCTAssertNoThrow(try reducer.apply(event))
      } else {
        XCTAssertThrowsError(try reducer.apply(event)) { error in
          XCTAssertEqual(
            error as? InlineLayoutError,
            .resourceLimitExceeded(resource: "writing points", actual: 8, limit: 6))
        }
      }
    }
  }

  func testHandwritingLimitsRejectConfiguredBoundsAndPreparedOverflow() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: .handwriting(faceID: "test-face"))
    let atom = try InlineTextAtom(id: "limited", text: "A", style: style)
    let faces = try InlineWritingFaceStore(faces: [Face(id: "test-face")])
    let strokeLimited = InlinePreparation(
      shaper: Shaper(),
      limits: InlinePreparationLimits(maximumWritingStrokes: 1),
      writingFaceStore: faces)
    XCTAssertThrowsError(
      try strokeLimited.prepare(document: InlineDocument(atoms: [.text(atom)]))
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .resourceLimitExceeded(resource: "writing strokes", actual: 2, limit: 1))
    }
    let invalid = InlinePreparation(
      shaper: Shaper(),
      limits: InlinePreparationLimits(maximumWritingPoints: 0),
      writingFaceStore: faces)
    XCTAssertThrowsError(
      try invalid.prepare(document: InlineDocument(atoms: [.text(atom)]))
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .invalidWritingLimit(resource: "points", value: 0))
    }
  }
}
