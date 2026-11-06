import LiveTextCore
import XCTest

@testable import LiveTextLayout

final class InlineAppendStreamingTests: XCTestCase {
  private final class Counter: @unchecked Sendable {
    var value = 0
  }

  /// Minimal ingestion-style fixture: a boundary is not declared complete
  /// until the caller has seen the following chunk. This lets the test prove
  /// that the append core receives one composed semantic atom, not transport
  /// chunks split at an extended grapheme boundary.
  private struct SemanticChunkBuffer {
    private var pending = ""

    mutating func receive(_ chunk: String, boundaryIsComplete: Bool) -> String? {
      pending.append(contentsOf: chunk)
      guard boundaryIsComplete else { return nil }
      let value = pending
      pending.removeAll(keepingCapacity: true)
      return value
    }
  }

  private struct FixedCancellableShaper: CancellableInlineTextShaping {
    let advance: Double

    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      try shape(text: text, style: style, sourceRange: sourceRange, cancellation: {})
    }

    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange,
      cancellation: InlineCancellationCheck
    ) throws -> InlineShapedText {
      var ranges: [InlineSourceRange] = []
      var glyphs: [InlineGlyph] = []
      var offset = sourceRange.startUTF16
      var position = 0.0
      for (index, grapheme) in text.enumerated() {
        try cancellation()
        let length = String(grapheme).utf16.count
        let range = try InlineSourceRange(startUTF16: offset, endUTF16: offset + length)
        ranges.append(range)
        glyphs.append(
          try InlineGlyph(
            glyphID: UInt16(index),
            positionX: position,
            positionY: 0,
            sourceUTF16Index: offset,
            sourceRange: range
          ))
        offset += length
        position += advance
      }
      let metrics = try InlineMetrics(
        advance: position,
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
            advance: position,
            ascent: metrics.ascent,
            descent: metrics.descent
          )
        ]
      } else {
        runs = []
      }
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: advance, count: ranges.count),
        runs: runs,
        metrics: metrics
      )
    }
  }

  private func style(size: Double = 10) throws -> InlineTextStyle {
    try InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: size))
  }

  private func text(
    id: String,
    value: String,
    breakBehavior: InlineBreakBehavior = .normal
  ) throws -> InlineAtom {
    .text(
      try InlineTextAtom(
        id: id,
        text: value,
        style: style(),
        breakBehavior: breakBehavior
      ))
  }

  private func sealed(_ atom: InlineAtom) throws -> InlineSealedAppendAtom {
    try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)
  }

  private func appendEvent(
    reducer: InlineAppendReducer,
    atoms: [InlineAtom],
    sequence: UInt64? = nil,
    baseRevision: String? = nil
  ) throws -> InlineAppendEvent {
    InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: reducer.streamID,
        sequence: sequence ?? reducer.nextSequence,
        baseRevision: baseRevision ?? reducer.revision,
        atoms: try atoms.map(sealed)
      ))
  }

  private func makeReducer(
    width: Double = 3,
    limits: InlineAppendLimits = .default
  ) throws -> InlineAppendReducer {
    try InlineAppendReducer(
      streamID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      preparation: InlinePreparation(shaper: FixedCancellableShaper(advance: 1)),
      engine: InlineLayoutEngine(),
      width: width,
      limits: limits
    )
  }

  func testAppendMatchesCancellationAwareStaticPreparationAndLayout() throws {
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "marker",
        assetID: try InlineAssetID(rawValue: "marker"),
        metrics: try InlineMetrics(advance: 1, ascent: 10, descent: 2)
      ))
    let atoms = [
      try text(id: "left", value: "e\u{301}a"),
      vector,
      try text(id: "right", value: "bc"),
    ]
    let preparation = InlinePreparation(shaper: FixedCancellableShaper(advance: 1))
    let engine = try InlineLayoutEngine()
    var reducer = try InlineAppendReducer(
      streamID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      preparation: preparation,
      engine: engine,
      width: 3
    )
    var projection = try InlineAppendProjection(reducer: reducer)

    let first = try appendEvent(reducer: reducer, atoms: [atoms[0], atoms[1]])
    let firstDelta = try reducer.apply(first)
    try projection.apply(firstDelta)
    let second = try appendEvent(reducer: reducer, atoms: [atoms[2]])
    let secondDelta = try reducer.apply(second)
    try projection.apply(secondDelta)
    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    let finishDelta = try reducer.apply(finish)
    try projection.apply(finishDelta)

    let document = try InlineDocument(atoms: atoms)
    let staticPrepared = try preparation.prepare(document: document, cancellation: {})
    let staticLayout = try engine.layout(prepared: staticPrepared, width: 3)
    let final = try reducer.finalizedResult()

    XCTAssertEqual(final.prepared.revision, staticPrepared.revision)
    XCTAssertEqual(final.prepared.atoms, staticPrepared.atoms)
    XCTAssertEqual(final.layout.lines, staticLayout.lines)
    XCTAssertEqual(final.layout.height, staticLayout.height, accuracy: 0.0001)
    XCTAssertEqual(projection.documentAtoms, atoms)
    XCTAssertEqual(projection.preparedAtoms, staticPrepared.atoms)
    XCTAssertEqual(projection.committedLines, staticLayout.lines)
    XCTAssertTrue(projection.tailLines.isEmpty)
    XCTAssertTrue(projection.isFinal)
    XCTAssertFalse(firstDelta.appendedPreparedAtoms.isEmpty)
    XCTAssertFalse(secondDelta.appendedPreparedAtoms.isEmpty)
  }

  func testCJKSemanticAtomsMatchStaticPreparationAndLayout() throws {
    let atoms = [
      try text(id: "cjk-first", value: "漢字"),
      try text(id: "cjk-second", value: "かな"),
    ]
    let preparation = InlinePreparation(shaper: FixedCancellableShaper(advance: 1))
    let engine = try InlineLayoutEngine()
    var reducer = try InlineAppendReducer(
      streamID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      preparation: preparation,
      engine: engine,
      width: 3
    )
    var projection = try InlineAppendProjection(reducer: reducer)

    for atom in atoms {
      let delta = try reducer.apply(try appendEvent(reducer: reducer, atoms: [atom]))
      try projection.apply(delta)
    }
    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    try projection.apply(reducer.apply(finish))

    let document = try InlineDocument(atoms: atoms)
    let expectedPrepared = try preparation.prepare(document: document, cancellation: {})
    let expectedLayout = try engine.layout(prepared: expectedPrepared, width: 3)
    let actual = try reducer.finalizedResult()

    XCTAssertEqual(actual.prepared.atoms, expectedPrepared.atoms)
    XCTAssertEqual(actual.prepared.revision, expectedPrepared.revision)
    XCTAssertEqual(actual.layout.lines, expectedLayout.lines)
    XCTAssertEqual(actual.layout.height, expectedLayout.height, accuracy: 0.0001)
    XCTAssertEqual(projection.committedLines, expectedLayout.lines)
    XCTAssertEqual(
      expectedPrepared.atoms.compactMap { atom -> InlineSourceRange? in
        guard case .text(let text) = atom else { return nil }
        return text.sourceRange
      },
      [
        try InlineSourceRange(startUTF16: 0, endUTF16: 2),
        try InlineSourceRange(startUTF16: 2, endUTF16: 4),
      ]
    )
  }

  func testIngestionBuffersCombiningMarkBeforeSealing() throws {
    var buffer = SemanticChunkBuffer()
    XCTAssertNil(buffer.receive("e", boundaryIsComplete: false))
    let composed = try XCTUnwrap(
      buffer.receive("\u{301}", boundaryIsComplete: true)
    )
    XCTAssertEqual(composed, "e\u{301}")
    XCTAssertEqual(composed.count, 1)

    let atom = try text(id: "composed", value: composed)
    let preparation = InlinePreparation(shaper: FixedCancellableShaper(advance: 1))
    let engine = try InlineLayoutEngine()
    var reducer = try InlineAppendReducer(
      streamID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      preparation: preparation,
      engine: engine,
      width: 3
    )
    let delta = try reducer.apply(try appendEvent(reducer: reducer, atoms: [atom]))
    XCTAssertEqual(delta.appendedDocumentAtoms, [atom])
    XCTAssertEqual(delta.appendedPreparedAtoms.count, 1)
    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    _ = try reducer.apply(finish)

    let document = try InlineDocument(atoms: [atom])
    let expectedPrepared = try preparation.prepare(document: document, cancellation: {})
    let actual = try reducer.finalizedResult()
    XCTAssertEqual(actual.prepared.atoms, expectedPrepared.atoms)
    XCTAssertEqual(actual.prepared.revision, expectedPrepared.revision)
    guard case .text(let preparedText) = actual.prepared.atoms[0] else {
      return XCTFail("expected composed text atom")
    }
    XCTAssertEqual(preparedText.graphemes, ["e\u{301}"])
    XCTAssertEqual(preparedText.sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 2))
  }

  func testRetriesConflictsGapsStaleIdentityAndFinishAreTyped() throws {
    var reducer = try makeReducer()
    let firstEvent = try appendEvent(reducer: reducer, atoms: [try text(id: "a", value: "a")])
    let firstDelta = try reducer.apply(firstEvent)
    XCTAssertEqual(try reducer.apply(firstEvent), firstDelta)

    var projection = try InlineAppendProjection(reducer: reducer)
    try projection.apply(firstDelta)
    let projectionAfterReplay = projection
    try projection.apply(firstDelta)
    XCTAssertEqual(projection, projectionAfterReplay)
    let conflictingProjectionDelta = InlineAppendDelta(
      streamID: firstDelta.streamID,
      sequence: firstDelta.sequence,
      baseRevision: firstDelta.baseRevision,
      revision: firstDelta.revision,
      appendedDocumentAtoms: firstDelta.appendedDocumentAtoms,
      appendedPreparedAtoms: firstDelta.appendedPreparedAtoms,
      newlyCommittedLines: firstDelta.newlyCommittedLines,
      tailLines: firstDelta.tailLines,
      tailStart: firstDelta.tailStart,
      tailStartLineIndex: firstDelta.tailStartLineIndex,
      layoutWidth: firstDelta.layoutWidth,
      layoutHeight: firstDelta.layoutHeight + 1,
      isFinal: firstDelta.isFinal
    )
    XCTAssertThrowsError(try projection.apply(conflictingProjectionDelta)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .conflictingStreamReplay(sequence: firstDelta.sequence)
      )
    }
    XCTAssertEqual(projection, projectionAfterReplay)

    let conflicting = try appendEvent(
      reducer: reducer,
      atoms: [try text(id: "different", value: "b")],
      sequence: 0,
      baseRevision: firstDelta.baseRevision
    )
    XCTAssertThrowsError(try reducer.apply(conflicting)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .conflictingStreamReplay(sequence: 0))
    }

    let gap = try appendEvent(
      reducer: reducer, atoms: [try text(id: "gap", value: "c")], sequence: 3)
    XCTAssertThrowsError(try reducer.apply(gap)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .streamSequenceMismatch(expected: 1, actual: 3))
    }
    let stale = try appendEvent(
      reducer: reducer, atoms: [try text(id: "stale", value: "d")], baseRevision: "stale")
    XCTAssertThrowsError(try reducer.apply(stale)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .streamRevisionMismatch(expected: reducer.revision, actual: "stale")
      )
    }
    let wrongID = InlineAppendEvent.finish(
      streamID: UUID(), sequence: reducer.nextSequence, baseRevision: reducer.revision)
    XCTAssertThrowsError(try reducer.apply(wrongID)) { error in
      guard case .streamIdentityMismatch = error as? InlineLayoutError else {
        return XCTFail("expected stream identity mismatch")
      }
    }

    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    let finishDelta = try reducer.apply(finish)
    XCTAssertEqual(try reducer.apply(finish), finishDelta)
    let afterFinish = try appendEvent(reducer: reducer, atoms: [try text(id: "after", value: "e")])
    XCTAssertThrowsError(try reducer.apply(afterFinish)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .streamAlreadyFinished)
    }
  }

  func testReplayWindowIsExplicitBoundedAndConfigurable() throws {
    let limits = try InlineAppendLimits(maximumReplayReceipts: 2)
    var reducer = try makeReducer(width: 1, limits: limits)
    var projection = try InlineAppendProjection(reducer: reducer)

    let firstEvent = try appendEvent(
      reducer: reducer, atoms: [try text(id: "first-replay", value: "a")])
    let firstDelta = try reducer.apply(firstEvent)
    try projection.apply(firstDelta)

    let secondEvent = try appendEvent(
      reducer: reducer, atoms: [try text(id: "second-replay", value: "b")])
    let secondDelta = try reducer.apply(secondEvent)
    try projection.apply(secondDelta)

    let thirdEvent = try appendEvent(
      reducer: reducer, atoms: [try text(id: "third-replay", value: "c")])
    let thirdDelta = try reducer.apply(thirdEvent)
    try projection.apply(thirdDelta)

    let reducerBeforeReplay = reducer
    let projectionBeforeReplay = projection
    XCTAssertEqual(try reducer.apply(secondEvent), secondDelta)
    try projection.apply(secondDelta)
    XCTAssertEqual(reducer.revision, reducerBeforeReplay.revision)
    XCTAssertEqual(reducer.nextSequence, reducerBeforeReplay.nextSequence)
    XCTAssertEqual(projection, projectionBeforeReplay)

    let wrongStreamID = UUID()
    let wrongStreamReplay = InlineAppendDelta(
      streamID: wrongStreamID,
      sequence: secondDelta.sequence,
      baseRevision: secondDelta.baseRevision,
      revision: secondDelta.revision,
      appendedDocumentAtoms: secondDelta.appendedDocumentAtoms,
      appendedPreparedAtoms: secondDelta.appendedPreparedAtoms,
      newlyCommittedLines: secondDelta.newlyCommittedLines,
      tailLines: secondDelta.tailLines,
      tailStart: secondDelta.tailStart,
      tailStartLineIndex: secondDelta.tailStartLineIndex,
      layoutWidth: secondDelta.layoutWidth,
      layoutHeight: secondDelta.layoutHeight,
      isFinal: secondDelta.isFinal
    )
    XCTAssertThrowsError(try projection.apply(wrongStreamReplay)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .streamIdentityMismatch(expected: reducer.streamID, actual: wrongStreamID)
      )
    }

    let conflictingSecond = try appendEvent(
      reducer: reducer,
      atoms: [try text(id: "conflicting-retained", value: "x")],
      sequence: secondDelta.sequence,
      baseRevision: secondDelta.baseRevision
    )
    XCTAssertThrowsError(try reducer.apply(conflictingSecond)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .conflictingStreamReplay(sequence: secondDelta.sequence)
      )
    }

    XCTAssertThrowsError(try reducer.apply(firstEvent)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .streamSequenceMismatch(expected: thirdDelta.sequence + 1, actual: firstDelta.sequence)
      )
    }
    XCTAssertThrowsError(try projection.apply(firstDelta)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .streamSequenceMismatch(expected: thirdDelta.sequence + 1, actual: firstDelta.sequence)
      )
    }
  }

  func testReplayLimitCodableCompatibilityAndHardBounds() throws {
    let legacyJSON = Data(
      #"{"maximumTailAtoms":256,"maximumTailGraphemes":4096,"maximumTailGlyphs":8192}"#.utf8)
    let decoded = try JSONDecoder().decode(InlineAppendLimits.self, from: legacyJSON)
    XCTAssertEqual(decoded.maximumReplayReceipts, 1)

    let configured = try InlineAppendLimits(maximumReplayReceipts: 32)
    let roundTripped = try JSONDecoder().decode(
      InlineAppendLimits.self, from: JSONEncoder().encode(configured))
    XCTAssertEqual(roundTripped, configured)

    XCTAssertThrowsError(try InlineAppendLimits(maximumReplayReceipts: 0)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .invalidMetric(name: "maximumReplayReceipts", value: 0)
      )
    }
    XCTAssertThrowsError(try InlineAppendLimits(maximumReplayReceipts: 257)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .resourceLimitExceeded(resource: "replay receipts", actual: 257, limit: 256)
      )
    }
  }

  func testCancellationAndTailLimitFailuresRollBackReducerAndProjection() throws {
    let smallLimits = try InlineAppendLimits(
      maximumTailAtoms: 256, maximumTailGraphemes: 2, maximumTailGlyphs: 8_192)
    var reducer = try makeReducer(width: 20, limits: smallLimits)
    let beforeRevision = reducer.revision
    let beforeSequence = reducer.nextSequence
    let cancellationCalls = Counter()
    let event = try appendEvent(reducer: reducer, atoms: [try text(id: "cancel", value: "ab")])
    XCTAssertThrowsError(
      try reducer.apply(
        event,
        cancellation: {
          cancellationCalls.value += 1
          if cancellationCalls.value >= 2 { throw InlineLayoutError.cancelled }
        })
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertGreaterThanOrEqual(cancellationCalls.value, 2)
    XCTAssertEqual(reducer.revision, beforeRevision)
    XCTAssertEqual(reducer.nextSequence, beforeSequence)
    XCTAssertFalse(reducer.isFinished)

    let failing = try appendEvent(reducer: reducer, atoms: [try text(id: "long", value: "abc")])
    XCTAssertThrowsError(try reducer.apply(failing)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .resourceLimitExceeded(resource: "tail graphemes", actual: 3, limit: 2)
      )
    }
    XCTAssertEqual(reducer.revision, beforeRevision)
    XCTAssertEqual(reducer.nextSequence, beforeSequence)

    var projection = try InlineAppendProjection(reducer: reducer)
    let wrongTail = InlineAppendDelta(
      streamID: reducer.streamID,
      sequence: reducer.nextSequence,
      baseRevision: reducer.revision,
      revision: "candidate",
      appendedDocumentAtoms: [],
      appendedPreparedAtoms: [],
      newlyCommittedLines: [],
      tailLines: [],
      tailStart: InlineCursor(atomIndex: 99),
      tailStartLineIndex: 99,
      layoutWidth: 20,
      layoutHeight: 0,
      isFinal: false
    )
    XCTAssertThrowsError(try projection.apply(wrongTail))
    XCTAssertEqual(projection.revision, beforeRevision)
    XCTAssertEqual(projection.nextSequence, beforeSequence)
    XCTAssertTrue(projection.documentAtoms.isEmpty)
  }

  func testNoBreakAroundTailLimitFailureRollsBackForExactRetry() throws {
    let limits = try InlineAppendLimits(
      maximumTailAtoms: 1,
      maximumTailGraphemes: 2,
      maximumTailGlyphs: 8_192
    )
    var reducer = try makeReducer(width: 2, limits: limits)
    let atom = try text(
      id: "no-break",
      value: "abc",
      breakBehavior: .noBreakAround
    )
    let event = try appendEvent(reducer: reducer, atoms: [atom])
    let beforeRevision = reducer.revision
    let beforeSequence = reducer.nextSequence
    let beforeAccounting = reducer.operationAccounting

    for _ in 0..<2 {
      XCTAssertThrowsError(try reducer.apply(event)) { error in
        XCTAssertEqual(
          error as? InlineLayoutError,
          .resourceLimitExceeded(resource: "tail graphemes", actual: 3, limit: 2)
        )
      }
      XCTAssertEqual(reducer.revision, beforeRevision)
      XCTAssertEqual(reducer.nextSequence, beforeSequence)
      XCTAssertEqual(reducer.operationAccounting, beforeAccounting)
      XCTAssertFalse(reducer.isFinished)
    }
  }

  func testTailReplacementFinishAndHardCaps() throws {
    var reducer = try makeReducer(width: 1)
    let first = try appendEvent(reducer: reducer, atoms: [try text(id: "first", value: "a")])
    let firstDelta = try reducer.apply(first)
    XCTAssertTrue(firstDelta.newlyCommittedLines.isEmpty)
    XCTAssertEqual(firstDelta.tailLines.count, 1)

    let second = try appendEvent(reducer: reducer, atoms: [try text(id: "second", value: "b")])
    let secondDelta = try reducer.apply(second)
    XCTAssertEqual(secondDelta.newlyCommittedLines.map(\.atoms.first?.atomID), ["first"])
    XCTAssertEqual(secondDelta.tailLines.map { $0.atoms.first?.atomID }, ["second"])
    XCTAssertEqual(secondDelta.tailStart, firstDelta.tailStart)

    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    let finishDelta = try reducer.apply(finish)
    XCTAssertEqual(finishDelta.newlyCommittedLines.map { $0.atoms.first?.atomID }, ["second"])
    XCTAssertTrue(finishDelta.tailLines.isEmpty)
    XCTAssertNoThrow(try reducer.finalizedResult())

    XCTAssertThrowsError(
      try InlineAppendLimits(maximumTailAtoms: 1_025, maximumTailGraphemes: 1, maximumTailGlyphs: 1)
    ) { error in
      guard
        case .resourceLimitExceeded(resource: "tail atoms", actual: 1_025, limit: 1_024) =
          error as? InlineLayoutError
      else { return XCTFail("expected hard atom cap") }
    }
    XCTAssertThrowsError(try InlineAppendLimits(maximumTailAtoms: 0)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError, .invalidMetric(name: "maximumTailAtoms", value: 0))
    }
  }

  func testHardBreakTailReplacementMatchesStaticLayout() throws {
    let preparation = InlinePreparation(shaper: FixedCancellableShaper(advance: 1))
    let engine = try InlineLayoutEngine()
    let atoms = [
      try text(id: "line-break", value: "a\n"),
      try text(id: "after-break", value: "b"),
    ]
    var reducer = try InlineAppendReducer(
      streamID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      preparation: preparation,
      engine: engine,
      width: 3
    )
    let firstDelta = try reducer.apply(try appendEvent(reducer: reducer, atoms: [atoms[0]]))
    let firstDocument = try InlineDocument(atoms: [atoms[0]])
    let firstPrepared = try preparation.prepare(document: firstDocument, cancellation: {})
    let firstStaticLayout = try engine.layout(prepared: firstPrepared, width: 3)
    XCTAssertEqual(
      firstDelta.newlyCommittedLines + firstDelta.tailLines,
      firstStaticLayout.lines
    )
    XCTAssertEqual(firstDelta.newlyCommittedLines.count, 1)
    XCTAssertEqual(firstDelta.tailLines.count, 1)
    XCTAssertEqual(firstDelta.newlyCommittedLines[0].end, firstStaticLayout.lines[0].end)
    XCTAssertEqual(firstDelta.tailLines[0].start, firstStaticLayout.lines[1].start)
    XCTAssertEqual(firstDelta.tailLines[0].end, firstStaticLayout.lines[1].end)
    _ = try reducer.apply(try appendEvent(reducer: reducer, atoms: [atoms[1]]))
    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    _ = try reducer.apply(finish)

    let document = try InlineDocument(atoms: atoms)
    let expectedPrepared = try preparation.prepare(document: document, cancellation: {})
    let expectedLayout = try engine.layout(prepared: expectedPrepared, width: 3)
    let actual = try reducer.finalizedResult()
    XCTAssertEqual(actual.prepared.atoms, expectedPrepared.atoms)
    XCTAssertEqual(actual.layout.lines, expectedLayout.lines)
    XCTAssertEqual(actual.layout.height, expectedLayout.height, accuracy: 0.0001)

    let standaloneAtom = try text(id: "standalone-break", value: "\n")
    var standaloneReducer = try InlineAppendReducer(
      streamID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
      preparation: preparation,
      engine: engine,
      width: 3
    )
    let standaloneDelta = try standaloneReducer.apply(
      try appendEvent(reducer: standaloneReducer, atoms: [standaloneAtom])
    )
    let standalonePrepared = try preparation.prepare(
      document: InlineDocument(atoms: [standaloneAtom]), cancellation: {})
    let standaloneLayout = try engine.layout(prepared: standalonePrepared, width: 3)
    XCTAssertEqual(
      standaloneDelta.newlyCommittedLines + standaloneDelta.tailLines, standaloneLayout.lines)
    XCTAssertTrue(standaloneDelta.newlyCommittedLines.isEmpty)
    XCTAssertEqual(standaloneDelta.tailLines.count, 1)
    XCTAssertEqual(standaloneDelta.tailLines[0].start, standaloneLayout.lines[0].start)
    XCTAssertEqual(standaloneDelta.tailLines[0].end, standaloneLayout.lines[0].end)
  }

  func testOneThousandSingleAtomAppendsHaveNoPrefixWorkOrReEmission() throws {
    var reducer = try makeReducer(width: 1)
    var projection = try InlineAppendProjection(reducer: reducer)
    for index in 0..<1_000 {
      let atom = try InlineAtom.vector(
        InlineVectorAtom(
          id: "vector-\(index)",
          assetID: try InlineAssetID(rawValue: "vector-\(index)"),
          metrics: try InlineMetrics(advance: 1, ascent: 1, descent: 0)
        ))
      let event = try appendEvent(reducer: reducer, atoms: [atom])
      let delta = try reducer.apply(event)
      try projection.apply(delta)
    }
    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID, sequence: reducer.nextSequence, baseRevision: reducer.revision)
    let finishDelta = try reducer.apply(finish)
    try projection.apply(finishDelta)

    let accounting = reducer.operationAccounting
    XCTAssertEqual(accounting.shapedAtomCount, 1_000)
    XCTAssertEqual(accounting.validatedAtomCount, 1_000)
    XCTAssertEqual(accounting.emittedAtomCount, 1_000)
    XCTAssertEqual(accounting.emittedLineCount, 1_000)
    XCTAssertEqual(accounting.tailReplacementCount, 1_001)
    XCTAssertLessThanOrEqual(accounting.tailLayoutUnitVisits, 2_000)
    XCTAssertEqual(projection.committedLines.count, 1_000)
    XCTAssertTrue(projection.tailLines.isEmpty)
  }
}
