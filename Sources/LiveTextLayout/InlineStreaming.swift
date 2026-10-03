import Foundation

/// One independently valid value emitted by an inline preparation/layout stream.
///
/// The prepared document is immutable and shared by every tail. Consumers must
/// treat each layout as a complete tail result; no value represents a mutable
/// or partially prepared document.
public struct InlineStreamingResult: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case prepared, layout
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      prepared: values.decode(PreparedInlineDocument.self, forKey: .prepared),
      layout: values.decode(InlineLayoutResult.self, forKey: .layout)
    )
  }

  public let prepared: PreparedInlineDocument
  public let layout: InlineLayoutResult

  public init(prepared: PreparedInlineDocument, layout: InlineLayoutResult) throws {
    try self.init(prepared: prepared, layout: layout, oversizedVectorPolicy: nil)
  }

  public init(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    oversizedVectorPolicy: InlineOversizedVectorPolicy?
  ) throws {
    guard layout.preparationRevision == prepared.revision else {
      throw InlineLayoutError.invalidRenderPlan
    }
    try layout.validate(for: prepared)
    if let expected = oversizedVectorPolicy,
      let continuation = layout.continuation,
      continuation.oversizedVectorPolicy != expected
    {
      throw InlineLayoutError.invalidContinuation
    }
    self.prepared = prepared
    self.layout = layout
  }
}

/// A caller-attested semantic atom boundary for append-only ingestion.
///
/// The initializer validates the atom value, but it cannot infer whether a
/// transport chunk is semantically complete. Product ingestion must perform
/// incremental UTF-8, grapheme, and sentence buffering before constructing
/// this value.
public struct InlineSealedAppendAtom: Sendable, Hashable {
  public let atom: InlineAtom

  public init(sealingCompleteSemanticAtom atom: InlineAtom) throws {
    // Reuse the static atom/document validation without inventing a boundary
    // or accepting an empty identifier through a future enum case.
    _ = try InlineDocument(atoms: [atom])
    self.atom = atom
  }
}

/// One contiguous append accepted by `InlineAppendReducer`.
public struct InlineAppendBatch: Sendable, Hashable {
  public let streamID: UUID
  public let sequence: UInt64
  public let baseRevision: String
  public let atoms: [InlineSealedAppendAtom]

  public init(
    streamID: UUID,
    sequence: UInt64,
    baseRevision: String,
    atoms: [InlineSealedAppendAtom]
  ) {
    self.streamID = streamID
    self.sequence = sequence
    self.baseRevision = baseRevision
    self.atoms = atoms
  }
}

/// A reducer event. These values deliberately are not `Codable`; transport
/// decoding belongs to product ingestion before semantic atoms are sealed.
public enum InlineAppendEvent: Sendable, Hashable {
  case append(InlineAppendBatch)
  case finish(streamID: UUID, sequence: UInt64, baseRevision: String)
}

/// Limits for the one mutable final-line tail.
public struct InlineAppendLimits: Sendable, Hashable, Codable {
  public static let defaultMaximumReplayReceipts = 1
  public static let maximumSupportedReplayReceipts = 256
  public static let `default`: InlineAppendLimits = try! InlineAppendLimits()

  public let maximumTailAtoms: Int
  public let maximumTailGraphemes: Int
  public let maximumTailGlyphs: Int
  /// Number of accepted append receipts retained for exact idempotent replay.
  ///
  /// The default preserves the historical one-receipt behavior. Callers that
  /// need a wider retry window can opt in without turning the reducer into an
  /// unbounded event journal.
  public let maximumReplayReceipts: Int

  internal static let maximumTailAtomsHardCap = 1_024
  internal static let maximumTailGraphemesHardCap = 65_536
  internal static let maximumTailGlyphsHardCap = 131_072

  public init(
    maximumTailAtoms: Int = 256,
    maximumTailGraphemes: Int = 4_096,
    maximumTailGlyphs: Int = 8_192,
    maximumReplayReceipts: Int = Self.defaultMaximumReplayReceipts
  ) throws {
    guard maximumTailAtoms > 0 else {
      throw InlineLayoutError.invalidMetric(
        name: "maximumTailAtoms", value: Double(maximumTailAtoms))
    }
    guard maximumTailGraphemes > 0 else {
      throw InlineLayoutError.invalidMetric(
        name: "maximumTailGraphemes", value: Double(maximumTailGraphemes))
    }
    guard maximumTailGlyphs > 0 else {
      throw InlineLayoutError.invalidMetric(
        name: "maximumTailGlyphs", value: Double(maximumTailGlyphs))
    }
    guard maximumTailAtoms <= Self.maximumTailAtomsHardCap else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "tail atoms", actual: maximumTailAtoms,
        limit: Self.maximumTailAtomsHardCap)
    }
    guard maximumTailGraphemes <= Self.maximumTailGraphemesHardCap else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "tail graphemes", actual: maximumTailGraphemes,
        limit: Self.maximumTailGraphemesHardCap)
    }
    guard maximumTailGlyphs <= Self.maximumTailGlyphsHardCap else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "tail glyphs", actual: maximumTailGlyphs,
        limit: Self.maximumTailGlyphsHardCap)
    }
    guard maximumReplayReceipts > 0 else {
      throw InlineLayoutError.invalidMetric(
        name: "maximumReplayReceipts", value: Double(maximumReplayReceipts))
    }
    guard maximumReplayReceipts <= Self.maximumSupportedReplayReceipts else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "replay receipts", actual: maximumReplayReceipts,
        limit: Self.maximumSupportedReplayReceipts)
    }
    self.maximumTailAtoms = maximumTailAtoms
    self.maximumTailGraphemes = maximumTailGraphemes
    self.maximumTailGlyphs = maximumTailGlyphs
    self.maximumReplayReceipts = maximumReplayReceipts
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumTailAtoms: values.decode(Int.self, forKey: .maximumTailAtoms),
      maximumTailGraphemes: values.decode(Int.self, forKey: .maximumTailGraphemes),
      maximumTailGlyphs: values.decode(Int.self, forKey: .maximumTailGlyphs),
      maximumReplayReceipts:
        values.decodeIfPresent(Int.self, forKey: .maximumReplayReceipts)
        ?? Self.defaultMaximumReplayReceipts
    )
  }

  private enum CodingKeys: String, CodingKey {
    case maximumTailAtoms, maximumTailGraphemes, maximumTailGlyphs, maximumReplayReceipts
  }
}

/// Immutable reducer output. `tailStart` is the old tail's replacement
/// boundary; the next state derives its new boundary from `tailLines`.
public struct InlineAppendDelta: Sendable, Hashable {
  public let streamID: UUID
  public let sequence: UInt64
  public let baseRevision: String
  public let revision: String
  public let appendedDocumentAtoms: [InlineAtom]
  public let appendedPreparedAtoms: [PreparedInlineDocument.Atom]
  public let newlyCommittedLines: [InlineLayoutLine]
  public let tailLines: [InlineLayoutLine]
  public let tailStart: InlineCursor
  public let tailStartLineIndex: Int
  public let layoutWidth: Double
  public let layoutHeight: Double
  public let isFinal: Bool

}

/// Test-only operation counters used to prove append work is bounded by the
/// batch and mutable tail rather than the committed prefix.
@usableFromInline
internal struct InlineAppendOperationAccounting: Sendable, Hashable {
  internal var shapedAtomCount = 0
  internal var validatedAtomCount = 0
  internal var tailLayoutUnitVisits = 0
  internal var emittedAtomCount = 0
  internal var emittedLineCount = 0
  internal var tailReplacementCount = 0
}

/// Caller-owned append reducer with one replaceable final-line tail.
public struct InlineAppendReducer: Sendable {
  public let streamID: UUID
  public private(set) var revision: String
  public private(set) var nextSequence: UInt64
  public private(set) var isFinished: Bool

  private let preparation: InlinePreparation
  fileprivate let preparationIdentityContext: InlinePreparationIdentityContext
  private let engine: InlineLayoutEngine
  fileprivate let width: Double
  fileprivate let limits: InlineAppendLimits
  fileprivate var revisionBuilder: InlineRevisionBuilder
  fileprivate var documentAtoms: [InlineAtom]
  fileprivate var preparedAtoms: [PreparedInlineDocument.Atom]
  private var seenAtomIDs: Set<String>
  fileprivate var totalTextUTF16Units: Int
  private var totalGraphemes: Int
  private var totalGlyphs: Int
  private var totalRuns: Int
  fileprivate var totalImageAtoms: Int
  private var totalWritingStrokes: Int
  private var totalWritingPoints: Int
  fileprivate var committedLines: [InlineLayoutLine]
  fileprivate var tailLines: [InlineLayoutLine]
  fileprivate var tailStart: InlineCursor
  fileprivate var tailStartLineIndex: Int
  fileprivate var layoutHeight: Double
  fileprivate var replayReceipts: [UInt64: InlineAppendReplayReceipt]
  fileprivate var replayReceiptOrder: [UInt64]

  internal private(set) var operationAccounting = InlineAppendOperationAccounting()

  public init(
    streamID: UUID = UUID(),
    preparation: InlinePreparation,
    engine: InlineLayoutEngine,
    width: Double,
    limits: InlineAppendLimits = .default
  ) throws {
    guard width.isFinite, width > 0 else { throw InlineLayoutError.invalidWidth(width) }
    guard limits.maximumTailAtoms <= preparation.limits.maximumAtoms else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "tail atoms", actual: limits.maximumTailAtoms,
        limit: preparation.limits.maximumAtoms)
    }
    guard limits.maximumTailGraphemes <= preparation.limits.maximumGraphemes else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "tail graphemes", actual: limits.maximumTailGraphemes,
        limit: preparation.limits.maximumGraphemes)
    }
    guard limits.maximumTailGlyphs <= preparation.limits.maximumGlyphs else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "tail glyphs", actual: limits.maximumTailGlyphs,
        limit: preparation.limits.maximumGlyphs)
    }
    let builder = try InlineRevisionBuilder(
      includeTextKernelPreparation: false, limits: preparation.limits)
    let initialRevision = builder.finalizedHex()
    self.streamID = streamID
    self.revision = initialRevision
    self.nextSequence = 0
    self.isFinished = false
    self.preparation = preparation
    self.preparationIdentityContext = .cancellationAware(limits: preparation.limits)
    self.engine = engine
    self.width = width
    self.limits = limits
    self.revisionBuilder = builder
    self.documentAtoms = []
    self.preparedAtoms = []
    self.seenAtomIDs = []
    self.totalTextUTF16Units = 0
    self.totalGraphemes = 0
    self.totalGlyphs = 0
    self.totalRuns = 0
    self.totalImageAtoms = 0
    self.totalWritingStrokes = 0
    self.totalWritingPoints = 0
    self.committedLines = []
    self.tailLines = []
    self.tailStart = .zero
    self.tailStartLineIndex = 0
    self.layoutHeight = 0
    self.replayReceipts = [:]
    self.replayReceiptOrder = []
  }

  public mutating func apply(
    _ event: InlineAppendEvent,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineAppendDelta {
    let incomingID = event.inlineStreamID
    let incomingSequence = event.inlineSequence
    let incomingRevision = event.inlineBaseRevision

    guard incomingID == streamID else {
      throw InlineLayoutError.streamIdentityMismatch(expected: streamID, actual: incomingID)
    }
    if let retained = replayReceipts[incomingSequence] {
      guard retained.event == event else {
        throw InlineLayoutError.conflictingStreamReplay(sequence: incomingSequence)
      }
      return retained.delta
    }
    if isFinished {
      throw InlineLayoutError.streamAlreadyFinished
    }
    if nextSequence > 0, incomingSequence == nextSequence - 1 {
      throw InlineLayoutError.conflictingStreamReplay(sequence: incomingSequence)
    }
    guard incomingSequence == nextSequence else {
      throw InlineLayoutError.streamSequenceMismatch(
        expected: nextSequence, actual: incomingSequence)
    }
    guard incomingRevision == revision else {
      throw InlineLayoutError.streamRevisionMismatch(expected: revision, actual: incomingRevision)
    }
    guard incomingSequence < UInt64.max else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "stream sequence", actual: Int.max, limit: Int.max - 1)
    }

    switch event {
    case .append(let batch):
      return try apply(
        batch,
        event: event,
        cancellation: cancellation
      )
    case .finish:
      try cancellation()
      let oldTailStart = tailStart
      let oldTailStartLineIndex = tailStartLineIndex
      let oldTail = tailLines
      let delta = InlineAppendDelta(
        streamID: streamID,
        sequence: incomingSequence,
        baseRevision: revision,
        revision: revision,
        appendedDocumentAtoms: [],
        appendedPreparedAtoms: [],
        newlyCommittedLines: oldTail,
        tailLines: [],
        tailStart: oldTailStart,
        tailStartLineIndex: oldTailStartLineIndex,
        layoutWidth: width,
        layoutHeight: layoutHeight,
        isFinal: true
      )
      try cancellation()
      committedLines.append(contentsOf: oldTail)
      tailLines.removeAll(keepingCapacity: true)
      if let last = oldTail.last {
        tailStart = last.end
        tailStartLineIndex = last.index + 1
      } else {
        tailStart = oldTailStart
        tailStartLineIndex = committedLines.count
      }
      isFinished = true
      nextSequence += 1
      recordReplayReceipt(event: event, delta: delta)
      operationAccounting.emittedLineCount += oldTail.count
      operationAccounting.tailReplacementCount += 1
      return delta
    }
  }

  private mutating func apply(
    _ batch: InlineAppendBatch,
    event: InlineAppendEvent,
    cancellation: @escaping InlineCancellationCheck
  ) throws -> InlineAppendDelta {
    guard !batch.atoms.isEmpty else {
      throw InlineLayoutError.invalidMetric(name: "batchAtoms", value: 0)
    }
    var batchIDs = Set<String>(minimumCapacity: batch.atoms.count)
    for sealed in batch.atoms {
      try cancellation()
      let id = sealed.atom.id
      guard !seenAtomIDs.contains(id), batchIDs.insert(id).inserted else {
        throw InlineLayoutError.duplicateIdentifier(id)
      }
    }

    _ = try inlineCheckedAdd(
      documentAtoms.count, batch.atoms.count,
      resource: "atoms", limit: preparation.limits.maximumAtoms)
    let sourceAtoms = batch.atoms.map(\.atom)
    let batchDocument = try InlineDocument(atoms: sourceAtoms)
    try cancellation()
    let isolated = try preparation.prepare(document: batchDocument, cancellation: cancellation)
    guard isolated.atoms.count == sourceAtoms.count else {
      throw InlineLayoutError.unsupportedShaping("append preparation atom count mismatch")
    }

    var stagedPreparedAtoms: [PreparedInlineDocument.Atom] = []
    stagedPreparedAtoms.reserveCapacity(isolated.atoms.count)
    var stagedBuilder = revisionBuilder
    let baseUTF16Offset = totalTextUTF16Units
    var stagedUTF16Offset = baseUTF16Offset
    var stagedWritingStrokes = totalWritingStrokes
    var stagedWritingPoints = totalWritingPoints
    for (sourceAtom, isolatedAtom) in zip(sourceAtoms, isolated.atoms) {
      try cancellation()
      let preparedAtom = try shiftInlinePreparedAtom(isolatedAtom, by: baseUTF16Offset)
      try inlineValidatePreparedPair(
        source: sourceAtom,
        prepared: preparedAtom,
        expectedUTF16Offset: stagedUTF16Offset
      )
      if case .text(let preparedText) = preparedAtom {
        for unit in preparedText.writingUnits {
          try cancellation()
          guard case .semanticStroke(let stroke) = unit.kind else { continue }
          stagedWritingStrokes = try inlineCheckedAdd(
            stagedWritingStrokes, 1,
            resource: "writing strokes", limit: preparation.limits.maximumWritingStrokes)
          stagedWritingPoints = try inlineCheckedAdd(
            stagedWritingPoints, stroke.points.count,
            resource: "writing points", limit: preparation.limits.maximumWritingPoints)
        }
      }
      // Hash only the globally ranged, fully validated representation.
      try stagedBuilder.append(documentAtom: sourceAtom, preparedAtom: preparedAtom)
      stagedPreparedAtoms.append(preparedAtom)
      if case .text(let text) = sourceAtom {
        stagedUTF16Offset = try inlineCheckedAdd(
          stagedUTF16Offset, text.text.utf16.count,
          resource: "text UTF-16 units", limit: preparation.limits.maximumTextUTF16Units)
      }
    }
    try cancellation()

    let stagedTextUnits = try inlineCheckedAdd(
      totalTextUTF16Units, isolated.totalTextUTF16Units,
      resource: "text UTF-16 units", limit: preparation.limits.maximumTextUTF16Units)
    let stagedGraphemes = try inlineCheckedAdd(
      totalGraphemes, isolated.totalGraphemes,
      resource: "graphemes", limit: preparation.limits.maximumGraphemes)
    let stagedGlyphs = try inlineCheckedAdd(
      totalGlyphs, isolated.totalGlyphs,
      resource: "glyphs", limit: preparation.limits.maximumGlyphs)
    let stagedRuns = try inlineCheckedAdd(
      totalRuns, isolated.totalRuns,
      resource: "runs", limit: preparation.limits.maximumRuns)
    let stagedImageAtoms = try inlineCheckedAdd(
      totalImageAtoms, isolated.totalImageAtoms,
      resource: "image atoms", limit: preparation.limits.maximumImageAtoms)
    let stagedRevision = stagedBuilder.finalizedHex()

    let storage = InlineLayoutEngine.InlinePreparedAtomStorage(
      base: preparedAtoms, appended: stagedPreparedAtoms)
    let oldTailStart = tailStart
    let oldTailStartLineIndex = tailStartLineIndex
    let baselineOrigin: Double
    if let oldTail = tailLines.first {
      baselineOrigin = oldTail.baselineY - oldTail.ascent
    } else {
      baselineOrigin = layoutHeight
    }
    let layoutOutput = try engine.layoutAppendTail(
      storage: storage,
      start: oldTailStart,
      lineIndex: oldTailStartLineIndex,
      baselineOrigin: baselineOrigin,
      width: width,
      cancellation: cancellation
    )

    let newCommittedLines: [InlineLayoutLine]
    let newTailLines: [InlineLayoutLine]
    let newTailStart: InlineCursor
    let newTailStartLineIndex: Int
    let newHeight: Double
    if layoutOutput.lines.isEmpty {
      // Empty semantic atoms do not erase an existing empty tail line.
      newCommittedLines = []
      newTailLines = tailLines
      newTailStart = tailStart
      newTailStartLineIndex = tailStartLineIndex
      newHeight = layoutHeight
    } else {
      newCommittedLines = Array(layoutOutput.lines.dropLast())
      let finalLine = layoutOutput.lines[layoutOutput.lines.count - 1]
      newTailLines = [finalLine]
      newTailStart = finalLine.start
      newTailStartLineIndex = finalLine.index
      newHeight = layoutOutput.height
    }
    try inlineValidateTailLimits(
      start: newTailLines.first?.start ?? newTailStart,
      end: newTailLines.first?.end,
      storage: storage,
      limits: limits
    )
    guard newHeight.isFinite, newHeight >= 0 else {
      throw InlineLayoutError.unsupportedShaping("invalid append layout height")
    }
    let delta = InlineAppendDelta(
      streamID: streamID,
      sequence: batch.sequence,
      baseRevision: batch.baseRevision,
      revision: stagedRevision,
      appendedDocumentAtoms: sourceAtoms,
      appendedPreparedAtoms: stagedPreparedAtoms,
      newlyCommittedLines: newCommittedLines,
      tailLines: newTailLines,
      tailStart: oldTailStart,
      tailStartLineIndex: oldTailStartLineIndex,
      layoutWidth: width,
      layoutHeight: newHeight,
      isFinal: false
    )
    try cancellation()

    // From this point on all operations are non-throwing state publication.
    documentAtoms.append(contentsOf: sourceAtoms)
    preparedAtoms.append(contentsOf: stagedPreparedAtoms)
    seenAtomIDs.formUnion(batchIDs)
    revisionBuilder = stagedBuilder
    revision = stagedRevision
    totalTextUTF16Units = stagedTextUnits
    totalGraphemes = stagedGraphemes
    totalGlyphs = stagedGlyphs
    totalRuns = stagedRuns
    totalImageAtoms = stagedImageAtoms
    totalWritingStrokes = stagedWritingStrokes
    totalWritingPoints = stagedWritingPoints
    committedLines.append(contentsOf: newCommittedLines)
    tailLines = newTailLines
    tailStart = newTailStart
    tailStartLineIndex = newTailStartLineIndex
    layoutHeight = newHeight
    nextSequence += 1
    recordReplayReceipt(event: event, delta: delta)
    operationAccounting.shapedAtomCount += sourceAtoms.count
    operationAccounting.validatedAtomCount += stagedPreparedAtoms.count
    operationAccounting.tailLayoutUnitVisits += layoutOutput.visitedUnits
    operationAccounting.emittedAtomCount += sourceAtoms.count
    operationAccounting.emittedLineCount += newCommittedLines.count
    operationAccounting.tailReplacementCount += 1
    return delta
  }

  private mutating func recordReplayReceipt(event: InlineAppendEvent, delta: InlineAppendDelta) {
    replayReceipts[delta.sequence] = InlineAppendReplayReceipt(event: event, delta: delta)
    replayReceiptOrder.append(delta.sequence)
    if replayReceiptOrder.count > limits.maximumReplayReceipts {
      let expiredSequence = replayReceiptOrder.removeFirst()
      replayReceipts[expiredSequence] = nil
    }
  }

  public func finalizedResult() throws -> InlineStreamingResult {
    guard isFinished else { throw InlineLayoutError.streamNotFinished }
    let document = try InlineDocument(atoms: documentAtoms)
    let prepared = try PreparedInlineDocument(
      document: document,
      atoms: preparedAtoms,
      revision: revision,
      identityContext: preparationIdentityContext,
      totalTextUTF16Units: totalTextUTF16Units,
      totalGraphemes: totalGraphemes,
      totalGlyphs: totalGlyphs,
      totalRuns: totalRuns,
      totalImageAtoms: totalImageAtoms
    )
    let layout = try engine.layout(prepared: prepared, width: width)
    guard layout.height == layoutHeight, layout.lines == committedLines else {
      throw InlineLayoutError.invalidRenderPlan
    }
    return try InlineStreamingResult(
      prepared: prepared,
      layout: layout,
      oversizedVectorPolicy: engine.oversizedVectorPolicy
    )
  }
}

/// Stable public summary of one append session state.
///
/// Renderer projection payloads remain package-owned so callers cannot depend
/// on internal chunking, prepared atoms, or cache/layout transaction details.
public struct InlineAppendSnapshot: Sendable, Hashable {
  public let revision: String
  public let nextSequence: UInt64
  public let atomCount: Int
  public let committedLineCount: Int
  public let tailLineCount: Int
  public let layoutWidth: Double
  public let layoutHeight: Double
  public let isFinal: Bool

  public var lineCount: Int { committedLineCount + tailLineCount }

  package init(projection: InlineAppendProjection) {
    self.revision = projection.revision
    self.nextSequence = projection.nextSequence
    self.atomCount = projection.documentAtoms.count
    self.committedLineCount = projection.committedLines.count
    self.tailLineCount = projection.tailLines.count
    self.layoutWidth = projection.layoutWidth
    self.layoutHeight = projection.layoutHeight
    self.isFinal = projection.isFinal
  }
}

/// Renderer-owned derived projection of reducer deltas.
package struct InlineAppendProjection: Sendable, Hashable {
  package private(set) var documentAtoms: [InlineAtom]
  package private(set) var preparedAtoms: [PreparedInlineDocument.Atom]
  package private(set) var committedLines: [InlineLayoutLine]
  package private(set) var tailLines: [InlineLayoutLine]
  package private(set) var revision: String
  package private(set) var preparationIdentityContext: InlinePreparationIdentityContext
  package private(set) var nextSequence: UInt64
  package private(set) var layoutWidth: Double
  package private(set) var layoutHeight: Double
  package private(set) var tailStart: InlineCursor
  package private(set) var tailStartLineIndex: Int
  package private(set) var isFinal: Bool

  private let streamID: UUID
  private var seenAtomIDs: Set<String>
  private var totalTextUTF16Units: Int
  private var totalImageAtoms: Int
  private var revisionBuilder: InlineRevisionBuilder
  private let maximumReplayReceipts: Int
  private var replayFingerprints: [UInt64: InlineAppendDeltaFingerprint]
  private var replayReceiptOrder: [UInt64]

  fileprivate struct StateToken: Sendable, Hashable {
    let streamID: UUID
    let nextSequence: UInt64
    let revision: String
    let tailStart: InlineCursor
    let tailStartLineIndex: Int
    let isFinal: Bool

  }

  /// Internal validation receipt shared by the append adapters. Validation
  /// reads the existing projection and stages only delta-sized values; the
  /// receipt lets the adapters publish the already-validated transition
  /// without making a speculative copy of this projection.
  package struct Validation: Sendable {
    private let replay: Bool
    let fingerprint: InlineAppendDeltaFingerprint
    fileprivate let stateToken: StateToken
    let deltaIDs: Set<String>
    let stagedBuilder: InlineRevisionBuilder?
    let stagedUTF16Offset: Int?
    let stagedImageAtoms: Int?
    fileprivate var isVerified = false
    fileprivate var isCommitted = false

    package var isReplay: Bool { replay }

    fileprivate init(
      isReplay: Bool,
      fingerprint: InlineAppendDeltaFingerprint,
      stateToken: StateToken,
      deltaIDs: Set<String>,
      stagedBuilder: InlineRevisionBuilder?,
      stagedUTF16Offset: Int?,
      stagedImageAtoms: Int?
    ) {
      self.replay = isReplay
      self.fingerprint = fingerprint
      self.stateToken = stateToken
      self.deltaIDs = deltaIDs
      self.stagedBuilder = stagedBuilder
      self.stagedUTF16Offset = stagedUTF16Offset
      self.stagedImageAtoms = stagedImageAtoms
    }
  }

  package init(reducer: InlineAppendReducer) throws {
    // Break copy-on-write sharing at the snapshot boundary. The reducer must
    // remain uniquely mutable while a renderer projection retains this
    // snapshot; otherwise every subsequent append would copy the committed
    // prefix before it could publish its delta.
    self.documentAtoms = reducer.documentAtoms.map { $0 }
    self.preparedAtoms = reducer.preparedAtoms.map { $0 }
    self.committedLines = reducer.committedLines.map { $0 }
    self.tailLines = reducer.tailLines.map { $0 }
    self.revision = reducer.revision
    self.preparationIdentityContext = reducer.preparationIdentityContext
    self.nextSequence = reducer.nextSequence
    self.layoutWidth = reducer.width
    self.layoutHeight = reducer.layoutHeight
    self.tailStart = reducer.tailStart
    self.tailStartLineIndex = reducer.tailStartLineIndex
    self.isFinal = reducer.isFinished
    self.streamID = reducer.streamID
    self.seenAtomIDs = Set(reducer.documentAtoms.map(\.id))
    self.totalTextUTF16Units = reducer.totalTextUTF16Units
    self.totalImageAtoms = reducer.totalImageAtoms
    self.revisionBuilder = reducer.revisionBuilder
    self.maximumReplayReceipts = reducer.limits.maximumReplayReceipts
    self.replayReceiptOrder = reducer.replayReceiptOrder
    self.replayFingerprints = try Dictionary(
      uniqueKeysWithValues: reducer.replayReceiptOrder.map { sequence in
        guard let receipt = reducer.replayReceipts[sequence] else {
          throw InlineLayoutError.invalidContinuation
        }
        return (sequence, try InlineAppendDeltaFingerprint(receipt.delta))
      }
    )
  }

  /// Validates a reducer receipt without mutating the projection. The staged
  /// revision builder and ID set are bounded by the receipt's appended atoms.
  /// In particular, this method never copies the projection's committed line,
  /// prepared-atom, or document-atom prefixes.
  package func prevalidate(_ delta: InlineAppendDelta) throws -> Validation {
    guard delta.streamID == streamID else {
      throw InlineLayoutError.streamIdentityMismatch(expected: streamID, actual: delta.streamID)
    }
    let fingerprint = try InlineAppendDeltaFingerprint(delta)
    if let retained = replayFingerprints[delta.sequence] {
      guard retained == fingerprint else {
        throw InlineLayoutError.conflictingStreamReplay(sequence: delta.sequence)
      }
      return Validation(
        isReplay: true,
        fingerprint: fingerprint,
        stateToken: StateToken(
          streamID: streamID,
          nextSequence: nextSequence,
          revision: revision,
          tailStart: tailStart,
          tailStartLineIndex: tailStartLineIndex,
          isFinal: isFinal
        ),
        deltaIDs: [],
        stagedBuilder: nil,
        stagedUTF16Offset: nil,
        stagedImageAtoms: nil
      )
    }
    if isFinal { throw InlineLayoutError.streamAlreadyFinished }
    guard delta.sequence == nextSequence else {
      throw InlineLayoutError.streamSequenceMismatch(
        expected: nextSequence, actual: delta.sequence)
    }
    guard delta.sequence < UInt64.max else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "stream sequence", actual: Int.max, limit: Int.max - 1)
    }
    guard delta.baseRevision == revision else {
      throw InlineLayoutError.streamRevisionMismatch(
        expected: revision, actual: delta.baseRevision)
    }
    guard delta.tailStart == tailStart,
      delta.tailStartLineIndex == tailStartLineIndex
    else {
      throw InlineLayoutError.invalidContinuation
    }
    guard delta.layoutWidth == layoutWidth,
      delta.layoutWidth.isFinite, delta.layoutWidth > 0,
      delta.layoutHeight.isFinite, delta.layoutHeight >= 0,
      !delta.revision.isEmpty,
      delta.appendedDocumentAtoms.count == delta.appendedPreparedAtoms.count
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    if delta.isFinal {
      guard delta.appendedDocumentAtoms.isEmpty,
        delta.appendedPreparedAtoms.isEmpty,
        delta.newlyCommittedLines == tailLines
      else { throw InlineLayoutError.invalidRenderPlan }
    } else {
      guard !delta.appendedDocumentAtoms.isEmpty else {
        throw InlineLayoutError.invalidRenderPlan
      }
    }
    var deltaIDs = Set<String>(minimumCapacity: delta.appendedDocumentAtoms.count)
    var stagedBuilder = revisionBuilder
    var stagedUTF16Offset = totalTextUTF16Units
    var stagedImageAtoms = totalImageAtoms
    for (source, prepared) in zip(
      delta.appendedDocumentAtoms, delta.appendedPreparedAtoms)
    {
      try inlineValidatePreparedPair(
        source: source, prepared: prepared, expectedUTF16Offset: stagedUTF16Offset)
      guard !seenAtomIDs.contains(source.id), deltaIDs.insert(source.id).inserted else {
        throw InlineLayoutError.duplicateIdentifier(source.id)
      }
      try stagedBuilder.append(documentAtom: source, preparedAtom: prepared)
      if case .text(let text) = source {
        stagedUTF16Offset = try inlineCheckedAdd(
          stagedUTF16Offset, text.text.utf16.count,
          resource: "text UTF-16 units", limit: Int.max)
      } else if case .image = source {
        stagedImageAtoms = try inlineCheckedAdd(
          stagedImageAtoms, 1,
          resource: "image atoms", limit: Int.max)
      }
    }
    guard stagedBuilder.finalizedHex() == delta.revision else {
      throw InlineLayoutError.invalidRenderPlan
    }
    try inlineValidateProjectionLines(
      delta: delta,
      currentCommittedCount: committedLines.count,
      currentTail: tailLines,
      currentTailStartLineIndex: tailStartLineIndex
    )

    return Validation(
      isReplay: false,
      fingerprint: fingerprint,
      stateToken: StateToken(
        streamID: streamID,
        nextSequence: nextSequence,
        revision: revision,
        tailStart: tailStart,
        tailStartLineIndex: tailStartLineIndex,
        isFinal: isFinal
      ),
      deltaIDs: deltaIDs,
      stagedBuilder: stagedBuilder,
      stagedUTF16Offset: stagedUTF16Offset,
      stagedImageAtoms: stagedImageAtoms
    )
  }

  /// Verifies a receipt against the exact delta and current projection state.
  /// This is the throwing half of the append-adapter publication boundary. It
  /// never mutates the projection, so multiple adapters can verify their
  /// candidates before either one publishes a notification.
  package func verifyValidatedApply(
    _ delta: InlineAppendDelta,
    validation: inout Validation
  ) throws {
    guard !validation.isReplay, !validation.isVerified, !validation.isCommitted else {
      throw InlineLayoutError.invalidContinuation
    }
    let fingerprint = try InlineAppendDeltaFingerprint(delta)
    guard fingerprint == validation.fingerprint else {
      throw InlineLayoutError.invalidRenderPlan
    }
    guard
      StateToken(
        streamID: streamID,
        nextSequence: nextSequence,
        revision: revision,
        tailStart: tailStart,
        tailStartLineIndex: tailStartLineIndex,
        isFinal: isFinal
      ) == validation.stateToken
    else {
      throw InlineLayoutError.invalidContinuation
    }
    guard validation.stagedBuilder != nil,
      validation.stagedUTF16Offset != nil,
      validation.stagedImageAtoms != nil
    else {
      throw InlineLayoutError.invalidContinuation
    }

    validation.isVerified = true
  }

  /// Commits a receipt after `verifyValidatedApply` has checked its exact
  /// binding. This nonthrowing half is intentionally useful only inside an
  /// adapter's callback-local staging scope; misuse is a programmer error and
  /// traps instead of publishing a partial transition.
  package mutating func commitValidatedAfterVerification(
    _ delta: InlineAppendDelta,
    validation: inout Validation
  ) {
    guard validation.isVerified, !validation.isCommitted,
      let stagedBuilder = validation.stagedBuilder,
      let stagedUTF16Offset = validation.stagedUTF16Offset,
      let stagedImageAtoms = validation.stagedImageAtoms
    else {
      preconditionFailure("append receipt was not verified for commit")
    }
    validation.isCommitted = true
    commitValidated(
      delta,
      fingerprint: validation.fingerprint,
      deltaIDs: validation.deltaIDs,
      stagedBuilder: stagedBuilder,
      stagedUTF16Offset: stagedUTF16Offset,
      stagedImageAtoms: stagedImageAtoms
    )
  }

  /// Publishes a transition after `prevalidate(_:)` succeeds. The receipt is
  /// rechecked against the exact delta and current projection state before the
  /// callback is invoked, so stale, cross-delta, or replay receipts fail
  /// atomically without notifying a publisher. The callback is the final
  /// publication boundary: after it returns, the bound commit cannot throw.
  package mutating func applyValidated(
    _ delta: InlineAppendDelta,
    validation: Validation,
    willPublish: () -> Void = {}
  ) throws {
    var validation = validation
    try verifyValidatedApply(delta, validation: &validation)
    willPublish()
    commitValidatedAfterVerification(delta, validation: &validation)
  }

  /// Commits a receipt after `applyValidated` has checked its exact binding.
  /// This helper is deliberately private: callers cannot bypass the checks or
  /// invoke a publication callback before the commit is known to be safe.
  private mutating func commitValidated(
    _ delta: InlineAppendDelta,
    fingerprint: InlineAppendDeltaFingerprint,
    deltaIDs: Set<String>,
    stagedBuilder: InlineRevisionBuilder,
    stagedUTF16Offset: Int,
    stagedImageAtoms: Int
  ) {

    documentAtoms.append(contentsOf: delta.appendedDocumentAtoms)
    preparedAtoms.append(contentsOf: delta.appendedPreparedAtoms)
    seenAtomIDs.formUnion(deltaIDs)
    revisionBuilder = stagedBuilder
    totalTextUTF16Units = stagedUTF16Offset
    totalImageAtoms = stagedImageAtoms
    committedLines.append(contentsOf: delta.newlyCommittedLines)
    tailLines = delta.tailLines
    revision = delta.revision
    nextSequence += 1
    layoutWidth = delta.layoutWidth
    layoutHeight = delta.layoutHeight
    if let finalLine = tailLines.last {
      tailStart = finalLine.start
      tailStartLineIndex = finalLine.index
    } else if let committedLast = committedLines.last {
      tailStart = committedLast.end
      tailStartLineIndex = committedLast.index + 1
    } else {
      tailStart = delta.tailStart
      tailStartLineIndex = committedLines.count
    }
    isFinal = delta.isFinal
    replayFingerprints[delta.sequence] = fingerprint
    replayReceiptOrder.append(delta.sequence)
    if replayReceiptOrder.count > maximumReplayReceipts {
      let expiredSequence = replayReceiptOrder.removeFirst()
      replayFingerprints[expiredSequence] = nil
    }
  }

  package mutating func apply(_ delta: InlineAppendDelta) throws {
    let validation = try prevalidate(delta)
    if validation.isReplay { return }
    try applyValidated(delta, validation: validation)
  }
}

extension InlineAppendProjection {
  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.streamID == rhs.streamID
      && lhs.documentAtoms == rhs.documentAtoms
      && lhs.preparedAtoms == rhs.preparedAtoms
      && lhs.committedLines == rhs.committedLines
      && lhs.tailLines == rhs.tailLines
      && lhs.revision == rhs.revision
      && lhs.preparationIdentityContext == rhs.preparationIdentityContext
      && lhs.nextSequence == rhs.nextSequence
      && lhs.layoutWidth == rhs.layoutWidth
      && lhs.layoutHeight == rhs.layoutHeight
      && lhs.totalImageAtoms == rhs.totalImageAtoms
      && lhs.tailStart == rhs.tailStart
      && lhs.tailStartLineIndex == rhs.tailStartLineIndex
      && lhs.isFinal == rhs.isFinal
      && lhs.maximumReplayReceipts == rhs.maximumReplayReceipts
      && lhs.replayFingerprints == rhs.replayFingerprints
      && lhs.replayReceiptOrder == rhs.replayReceiptOrder
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(streamID)
    hasher.combine(documentAtoms)
    hasher.combine(preparedAtoms)
    hasher.combine(committedLines)
    hasher.combine(tailLines)
    hasher.combine(revision)
    hasher.combine(preparationIdentityContext)
    hasher.combine(nextSequence)
    hasher.combine(layoutWidth)
    hasher.combine(layoutHeight)
    hasher.combine(totalImageAtoms)
    hasher.combine(tailStart)
    hasher.combine(tailStartLineIndex)
    hasher.combine(isFinal)
    hasher.combine(maximumReplayReceipts)
    hasher.combine(replayFingerprints)
    hasher.combine(replayReceiptOrder)
  }
}

private struct InlineAppendReplayReceipt: Sendable {
  let event: InlineAppendEvent
  let delta: InlineAppendDelta
}

/// Compact, deterministic receipt identity for the projection's bounded replay
/// window. The reducer retains full deltas because exact replay must return the
/// original value; a renderer projection only needs collision-resistant
/// fingerprints and should not retain a second geometry copy.
internal struct InlineAppendDeltaFingerprint: Sendable, Hashable {
  private struct Payload: Encodable {
    let streamID: UUID
    let sequence: UInt64
    let baseRevision: String
    let revision: String
    let appendedDocumentAtoms: [InlineAtom]
    let appendedPreparedAtoms: [PreparedInlineDocument.Atom]
    let newlyCommittedLines: [InlineLayoutLine]
    let tailLines: [InlineLayoutLine]
    let tailStart: InlineCursor
    let tailStartLineIndex: Int
    let layoutWidth: Double
    let layoutHeight: Double
    let isFinal: Bool

    init(_ delta: InlineAppendDelta) {
      self.streamID = delta.streamID
      self.sequence = delta.sequence
      self.baseRevision = delta.baseRevision
      self.revision = delta.revision
      self.appendedDocumentAtoms = delta.appendedDocumentAtoms
      self.appendedPreparedAtoms = delta.appendedPreparedAtoms
      self.newlyCommittedLines = delta.newlyCommittedLines
      self.tailLines = delta.tailLines
      self.tailStart = delta.tailStart
      self.tailStartLineIndex = delta.tailStartLineIndex
      self.layoutWidth = delta.layoutWidth
      self.layoutHeight = delta.layoutHeight
      self.isFinal = delta.isFinal
    }
  }

  private let digest: [UInt8]

  init(_ delta: InlineAppendDelta) throws {
    var data = Data("Packages/LiveText/append-delta-fingerprint-v2".utf8)
    data.append(0)
    data.append(try CanonicalIdentityEncoder.encode(Payload(delta)))
    self.digest = StableSHA256.hash(data: data)
  }
}

extension InlineAppendEvent {
  fileprivate var inlineStreamID: UUID {
    switch self {
    case .append(let batch): return batch.streamID
    case .finish(let streamID, _, _): return streamID
    }
  }

  fileprivate var inlineSequence: UInt64 {
    switch self {
    case .append(let batch): return batch.sequence
    case .finish(_, let sequence, _): return sequence
    }
  }

  fileprivate var inlineBaseRevision: String {
    switch self {
    case .append(let batch): return batch.baseRevision
    case .finish(_, _, let baseRevision): return baseRevision
    }
  }
}

private func inlineCheckedAdd(_ lhs: Int, _ rhs: Int, resource: String, limit: Int) throws -> Int {
  let (value, overflow) = lhs.addingReportingOverflow(rhs)
  guard !overflow else {
    throw InlineLayoutError.resourceLimitExceeded(resource: resource, actual: Int.max, limit: limit)
  }
  guard value <= limit else {
    throw InlineLayoutError.resourceLimitExceeded(resource: resource, actual: value, limit: limit)
  }
  return value
}

private func inlineValidateTailLimits(
  start: InlineCursor,
  end: InlineCursor?,
  storage: InlineLayoutEngine.InlinePreparedAtomStorage,
  limits: InlineAppendLimits
) throws {
  guard let end else { return }
  guard start.atomIndex >= 0, end.atomIndex >= start.atomIndex,
    end.atomIndex <= storage.count
  else { throw InlineLayoutError.invalidCursor(start) }
  var atomCount = 0
  var graphemeCount = 0
  var glyphCount = 0
  var atomIndex = start.atomIndex
  while atomIndex < storage.count && atomIndex <= end.atomIndex {
    let prepared = storage[atomIndex]
    let first: Int
    let last: Int
    switch prepared {
    case .vector:
      first = 0
      last = 1
    case .image:
      first = 0
      last = 1
    case .text(let text):
      first = atomIndex == start.atomIndex ? start.graphemeIndex : 0
      if atomIndex == end.atomIndex {
        last = end.graphemeIndex
      } else {
        last = text.graphemes.count
      }
    }
    guard first >= 0, last >= first else { throw InlineLayoutError.invalidCursor(start) }
    if last > first {
      switch prepared {
      case .vector:
        atomCount += 1
      case .image:
        atomCount += 1
      case .text:
        atomCount += 1
        graphemeCount += last - first
        glyphCount += prepared.glyphCount(intersecting: first, through: last)
      }
    }
    atomIndex += 1
    if atomIndex > end.atomIndex { break }
  }
  guard atomCount <= limits.maximumTailAtoms else {
    throw InlineLayoutError.resourceLimitExceeded(
      resource: "tail atoms", actual: atomCount, limit: limits.maximumTailAtoms)
  }
  guard graphemeCount <= limits.maximumTailGraphemes else {
    throw InlineLayoutError.resourceLimitExceeded(
      resource: "tail graphemes", actual: graphemeCount, limit: limits.maximumTailGraphemes)
  }
  guard glyphCount <= limits.maximumTailGlyphs else {
    throw InlineLayoutError.resourceLimitExceeded(
      resource: "tail glyphs", actual: glyphCount, limit: limits.maximumTailGlyphs)
  }
}

extension PreparedInlineDocument.Atom {
  fileprivate func glyphCount(intersecting first: Int, through last: Int) -> Int {
    switch self {
    case .vector:
      return last > first ? 0 : 0
    case .image:
      return 0
    case .text(let text):
      guard first < last, first >= 0, last <= text.graphemes.count else { return 0 }
      let lower = text.shaped.graphemeRanges[first].startUTF16
      let upper = text.shaped.graphemeRanges[last - 1].endUTF16
      return text.shaped.runs.reduce(0) { count, run in
        count
          + run.glyphs.filter {
            $0.sourceRange.endUTF16 > lower && $0.sourceRange.startUTF16 < upper
          }.count
      }
    }
  }
}

private func inlineValidateProjectionLines(
  delta: InlineAppendDelta,
  currentCommittedCount: Int,
  currentTail: [InlineLayoutLine],
  currentTailStartLineIndex: Int
) throws {
  let expectedFirstCommittedIndex =
    currentTail.isEmpty
    ? currentCommittedCount
    : currentTailStartLineIndex
  if let first = delta.newlyCommittedLines.first {
    guard first.index == expectedFirstCommittedIndex else {
      throw InlineLayoutError.invalidRenderPlan
    }
  }
  for (offset, line) in delta.newlyCommittedLines.enumerated() {
    guard line.index == expectedFirstCommittedIndex + offset else {
      throw InlineLayoutError.invalidRenderPlan
    }
  }
  if let first = delta.tailLines.first {
    let expectedIndex = expectedFirstCommittedIndex + delta.newlyCommittedLines.count
    guard first.index == expectedIndex else { throw InlineLayoutError.invalidRenderPlan }
  }
  if delta.isFinal {
    guard delta.tailLines.isEmpty else { throw InlineLayoutError.invalidRenderPlan }
  } else if delta.tailLines.count > 1 {
    throw InlineLayoutError.invalidRenderPlan
  }
}

private actor InlineFixedDocumentStreamState {
  private let preparation: InlinePreparation?
  private let document: InlineDocument?
  private let engine: InlineLayoutEngine
  private let width: Double
  private let maximumLinesPerYield: Int

  private var prepared: PreparedInlineDocument?
  private var nextContinuation: InlineLayoutContinuation?
  private var didStartLayout = false
  private var isFinished = false

  init(
    prepared: PreparedInlineDocument,
    engine: InlineLayoutEngine,
    width: Double,
    maximumLinesPerYield: Int
  ) {
    self.prepared = prepared
    self.preparation = nil
    self.document = nil
    self.engine = engine
    self.width = width
    self.maximumLinesPerYield = maximumLinesPerYield
  }

  init(
    preparation: InlinePreparation,
    document: InlineDocument,
    engine: InlineLayoutEngine,
    width: Double,
    maximumLinesPerYield: Int
  ) {
    self.prepared = nil
    self.preparation = preparation
    self.document = document
    self.engine = engine
    self.width = width
    self.maximumLinesPerYield = maximumLinesPerYield
  }

  func next() throws -> (prepared: PreparedInlineDocument, layout: InlineLayoutResult)? {
    guard !isFinished else { return nil }
    guard maximumLinesPerYield > 0 else {
      throw InlineLayoutError.invalidMetric(
        name: "maximumLinesPerYield", value: Double(maximumLinesPerYield))
    }
    if Task.isCancelled { throw InlineLayoutError.cancelled }

    let resolvedPrepared: PreparedInlineDocument
    if let prepared {
      resolvedPrepared = prepared
    } else {
      guard let preparation, let document else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let value = try preparation.prepare(document: document) {
        if Task.isCancelled { throw InlineLayoutError.cancelled }
      }
      if Task.isCancelled { throw InlineLayoutError.cancelled }
      prepared = value
      resolvedPrepared = value
    }

    let result: InlineLayoutResult
    if !didStartLayout {
      result = try engine.layout(
        prepared: resolvedPrepared,
        width: width,
        maximumLines: maximumLinesPerYield,
        cancellation: {
          if Task.isCancelled { throw InlineLayoutError.cancelled }
        }
      )
    } else if let continuation = nextContinuation {
      result = try engine.layoutTail(
        prepared: resolvedPrepared,
        from: continuation,
        width: width,
        maximumLines: maximumLinesPerYield,
        cancellation: {
          if Task.isCancelled { throw InlineLayoutError.cancelled }
        }
      )
    } else {
      isFinished = true
      return nil
    }

    try result.validate(for: resolvedPrepared)
    guard result.width == width else {
      throw InlineLayoutError.invalidContinuation
    }
    if let continuation = result.continuation,
      continuation.oversizedVectorPolicy != engine.oversizedVectorPolicy
    {
      throw InlineLayoutError.invalidContinuation
    }
    if Task.isCancelled { throw InlineLayoutError.cancelled }

    didStartLayout = true
    nextContinuation = result.continuation
    if result.continuation == nil {
      isFinished = true
    }
    return (resolvedPrepared, result)
  }
}

extension InlineLayoutEngine {
  /// Emits bounded, immutable layout tails on consumer demand until continuation exhaustion.
  ///
  /// No producer task or intermediate buffer exists: each iterator `next()` computes at most
  /// one tail. This makes backpressure structural rather than a lossy-buffer condition while
  /// preserving `AsyncThrowingStream` cancellation semantics. `maximumLinesPerYield` bounds
  /// each emitted tail.
  public func stream(
    prepared: PreparedInlineDocument,
    width: Double,
    maximumLinesPerYield: Int = 1
  ) -> AsyncThrowingStream<InlineLayoutResult, Error> {
    let state = InlineFixedDocumentStreamState(
      prepared: prepared,
      engine: self,
      width: width,
      maximumLinesPerYield: maximumLinesPerYield
    )
    return AsyncThrowingStream(unfolding: {
      try await state.next()?.layout
    })
  }
}

/// Shifts a batch-prepared atom into document-global UTF-16 coordinates.
///
/// The caller must run this before feeding the atom to the incremental
/// revision builder. Keeping the helper outside any streaming API makes the
/// ordering explicit and prevents local ranges from being hashed as if they
/// were global ranges.
private func shiftInlinePreparedAtom(
  _ atom: PreparedInlineDocument.Atom,
  by offset: Int
) throws -> PreparedInlineDocument.Atom {
  guard offset >= 0 else { throw InlineLayoutError.invalidSourceRange }
  switch atom {
  case .vector:
    return atom
  case .image:
    return atom
  case .text(let text):
    func shift(_ range: InlineSourceRange) throws -> InlineSourceRange {
      guard range.startUTF16 <= Int.max - offset,
        range.endUTF16 <= Int.max - offset
      else { throw InlineLayoutError.invalidSourceRange }
      return try InlineSourceRange(
        startUTF16: range.startUTF16 + offset,
        endUTF16: range.endUTF16 + offset
      )
    }
    let ranges = try text.shaped.graphemeRanges.map(shift)
    let runs = try text.shaped.runs.map { run in
      try InlineShapedRun(
        glyphs: run.glyphs.map { glyph in
          let shiftedIndex: Int
          guard glyph.sourceUTF16Index <= Int.max - offset else {
            throw InlineLayoutError.invalidSourceRange
          }
          shiftedIndex = glyph.sourceUTF16Index + offset
          return try InlineGlyph(
            glyphID: glyph.glyphID,
            positionX: glyph.positionX,
            positionY: glyph.positionY,
            sourceUTF16Index: shiftedIndex,
            sourceRange: try shift(glyph.sourceRange)
          )
        },
        font: run.font,
        sourceRange: try shift(run.sourceRange),
        advance: run.advance,
        ascent: run.ascent,
        descent: run.descent
      )
    }
    let shaped = try InlineShapedText(
      graphemeRanges: ranges,
      graphemeAdvances: text.shaped.graphemeAdvances,
      graphemeCanBreakAfter: text.shaped.graphemeCanBreakAfter,
      runs: runs,
      metrics: text.shaped.metrics
    )
    let writingUnits = try text.writingUnits.map { unit in
      try InlinePreparedWritingUnit(
        id: unit.id,
        sourceRange: try shift(unit.sourceRange),
        kind: unit.kind
      )
    }
    return .text(
      try PreparedInlineText(
        atom: text.atom,
        sourceRange: try shift(text.sourceRange),
        graphemes: text.graphemes,
        shaped: shaped,
        textKernelPrepared: text.textKernelPrepared,
        textBreakEnds: try text.textBreakEnds.map {
          guard $0 <= Int.max - offset else { throw InlineLayoutError.invalidSourceRange }
          return $0 + offset
        },
        writingUnits: writingUnits
      ))
  }
}

extension InlinePreparation {
  /// Prepares lazily on first demand, then emits bounded immutable layout tails.
  ///
  /// Preparation and layout share the same demand-driven stream state. No
  /// prepared value is published until complete preparation validation succeeds,
  /// and no detached producer continues after the consumer stops requesting tails.
  public func prepareAndLayoutStream(
    document: InlineDocument,
    engine: InlineLayoutEngine,
    width: Double,
    maximumLinesPerYield: Int = 1
  ) -> AsyncThrowingStream<InlineStreamingResult, Error> {
    let state = InlineFixedDocumentStreamState(
      preparation: self,
      document: document,
      engine: engine,
      width: width,
      maximumLinesPerYield: maximumLinesPerYield
    )
    return AsyncThrowingStream(unfolding: {
      guard let next = try await state.next() else { return nil }
      return try InlineStreamingResult(
        prepared: next.prepared,
        layout: next.layout,
        oversizedVectorPolicy: engine.oversizedVectorPolicy
      )
    })
  }
}
