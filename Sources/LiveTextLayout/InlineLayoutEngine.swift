import Foundation
import LiveTextCore

/// Deterministic greedy mixed-flow layout over prepared text and vector atoms.
public struct InlineLayoutEngine: Sendable {
  public let leading: Double
  public let oversizedVectorPolicy: InlineOversizedVectorPolicy

  public init(
    leading: Double = 0,
    oversizedVectorPolicy: InlineOversizedVectorPolicy = .reject
  ) throws {
    guard leading.isFinite, leading >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "leading", value: leading)
    }
    self.leading = leading
    self.oversizedVectorPolicy = oversizedVectorPolicy
  }

  public func layout(
    prepared: PreparedInlineDocument,
    width: Double,
    continuation: InlineLayoutContinuation? = nil,
    maximumLines: Int? = nil,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineLayoutResult {
    guard width.isFinite, width >= 0 else { throw InlineLayoutError.invalidWidth(width) }
    if let maximumLines {
      guard maximumLines > 0 else {
        throw InlineLayoutError.invalidMetric(name: "maximumLines", value: Double(maximumLines))
      }
    }
    try validate(policy: oversizedVectorPolicy)
    let region = try InlineFlowRegion(
      rect: try InlineFlowRect(
        x: 0, y: 0, width: width, height: Double.greatestFiniteMagnitude
      ),
      layoutStyle: .standard
    )
    return try layout(
      prepared: prepared,
      flow: region,
      continuation: continuation,
      maximumLines: maximumLines,
      cancellation: cancellation
    )
  }

  /// Lays out mixed text, vector, and image atoms through one rectangular
  /// flow region. Exclusions are external geometry and are never added to the
  /// prepared document. The width-only API above is this solver with one
  /// unobstructed fragment per row.
  public func layout(
    prepared: PreparedInlineDocument,
    flow: InlineFlowRegion,
    continuation: InlineLayoutContinuation? = nil,
    maximumLines: Int? = nil,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineLayoutResult {
    let content = flow.contentRect
    guard content.width.isFinite, content.width >= 0 else {
      throw InlineLayoutError.invalidFlowRegion("content width is invalid")
    }
    if let maximumLines {
      guard maximumLines > 0 else {
        throw InlineLayoutError.invalidMetric(name: "maximumLines", value: Double(maximumLines))
      }
    }
    try validate(policy: oversizedVectorPolicy)
    let start = normalized(
      try validate(
        continuation,
        prepared: prepared,
        width: content.width,
        flowRevision: flow.revision
      ), prepared: prepared)
    let storage = InlinePreparedAtomStorage(base: prepared.atoms)
    var state = UnitCursorState(cursor: start)
    if content.width == 0 {
      var probe = state
      if try nextUnit(storage: storage, state: &probe, cancellation: cancellation) != nil {
        throw InlineLayoutError.flowContentExceedsRegion
      }
    }
    var lines: [InlineLayoutLine] = []
    var lineTop = continuation?.nextY ?? content.minY
    guard lineTop.isFinite, lineTop >= content.minY, lineTop <= content.maxY else {
      throw InlineLayoutError.invalidContinuation
    }
    var lineIndex = 0
    let tolerance = 1.0 / 64.0

    func appendLine(
      placements: [FlowPlacement],
      stateAfter: UnitCursorState,
      top: Double,
      lineHeight: (ascent: Double, descent: Double),
      start: InlineCursor,
      end: InlineCursor
    ) throws {
      let line = try makeFlowLine(
        placements: placements,
        index: lineIndex,
        baseline: top + lineHeight.ascent,
        ascent: lineHeight.ascent,
        descent: lineHeight.descent,
        start: start,
        end: end
      )
      lines.append(line)
      lineIndex += 1
      state = stateAfter
      let nextTop = top + line.height
      guard nextTop.isFinite else {
        throw InlineLayoutError.invalidFlowRegion("line position overflowed")
      }
      lineTop = nextTop
    }

    while true {
      try cancellation()
      if let maximumLines, lines.count >= maximumLines { break }
      var lineState = state
      var units: [LayoutUnit] = []
      var placements: [FlowPlacement] = []
      var fittedMetrics: (ascent: Double, descent: Double)?
      var hasLegalBreak = false
      var lineStart: InlineCursor?
      var lineEnd: InlineCursor?
      var retryAtNextRow = false

      lineLoop: while true {
        try cancellation()
        var candidateState = lineState
        guard
          var candidate = try nextUnit(
            storage: storage, state: &candidateState, cancellation: cancellation
          )
        else {
          // `nextUnit` consumes empty trailing text atoms while looking for a
          // renderable unit. Preserve that advanced state even when no unit
          // remains, otherwise the outer loop retries the same empty cursor.
          state = candidateState
          if units.isEmpty {
            lineTop = max(lineTop, content.minY)
          } else {
            let metrics = lineMetrics(for: units)
            try appendLine(
              placements: placements,
              stateAfter: candidateState,
              top: lineTop,
              lineHeight: metrics,
              start: lineStart ?? units[0].start,
              end: lineEnd ?? units[0].end
            )
          }
          retryAtNextRow = false
          break lineLoop
        }

        if candidate.isHardBreak {
          if units.isEmpty {
            let emptyLine = try InlineLayoutLine(
              index: lineIndex,
              baselineY: lineTop,
              ascent: 0,
              descent: 0,
              leading: leading,
              width: 0,
              start: candidate.start,
              end: candidate.end,
              atoms: []
            )
            lines.append(emptyLine)
            lineIndex += 1
            lineState = candidateState
            state = candidateState
            let nextTop = lineTop + emptyLine.height
            guard nextTop.isFinite else {
              throw InlineLayoutError.invalidFlowRegion("line position overflowed")
            }
            lineTop = nextTop
          } else {
            let metrics = lineMetrics(for: units)
            try appendLine(
              placements: placements,
              stateAfter: candidateState,
              top: lineTop,
              lineHeight: metrics,
              start: lineStart ?? units[0].start,
              end: lineEnd ?? units[0].end
            )
          }
          if atEnd(candidateState, storage: storage), !units.isEmpty,
            maximumLines.map({ lines.count < $0 }) ?? true
          {
            let emptyLine = try InlineLayoutLine(
              index: lineIndex,
              baselineY: lineTop,
              ascent: 0,
              descent: 0,
              leading: leading,
              width: 0,
              start: candidate.end,
              end: candidate.end,
              atoms: []
            )
            lines.append(emptyLine)
            lineIndex += 1
            let nextTop = lineTop + emptyLine.height
            guard nextTop.isFinite else {
              throw InlineLayoutError.invalidFlowRegion("line position overflowed")
            }
            lineTop = nextTop
            state = candidateState
          } else if atEnd(candidateState, storage: storage), !units.isEmpty,
            maximumLines.map({ lines.count >= $0 }) ?? false
          {
            // Keep a terminal hard break pending when the visible line
            // consumed the caller's line budget. The next bounded call must
            // resume at this newline to publish its intentional empty line.
            state = lineState
          }
          retryAtNextRow = false
          break lineLoop
        }

        if candidate.breakBefore, !units.isEmpty {
          let metrics = lineMetrics(for: units)
          try appendLine(
            placements: placements,
            stateAfter: lineState,
            top: lineTop,
            lineHeight: metrics,
            start: lineStart ?? units[0].start,
            end: lineEnd ?? units[0].end
          )
          retryAtNextRow = false
          break lineLoop
        }

        if candidate.isVector,
          !LineFitKernel.fitsPrevalidated(
            currentWidth: 0, additionalAdvance: candidate.baseWidth, maximumWidth: content.width,
            tolerance: tolerance)
        {
          switch oversizedVectorPolicy {
          case .reject:
            throw InlineLayoutError.oversizedVector(
              id: candidate.id, advance: candidate.baseWidth, width: content.width)
          case .scaleToFit(let minimumScale):
            let scale = content.width == 0 ? 0 : content.width / candidate.baseWidth
            guard scale.isFinite, scale >= minimumScale else {
              throw InlineLayoutError.oversizedVector(
                id: candidate.id, advance: candidate.baseWidth, width: content.width)
            }
            candidate.scale = scale
          case .overflow:
            break
          }
        }
        if candidate.isImage,
          !LineFitKernel.fitsPrevalidated(
            currentWidth: 0, additionalAdvance: candidate.baseWidth, maximumWidth: content.width,
            tolerance: tolerance)
        {
          throw InlineLayoutError.oversizedImage(
            id: candidate.id, advance: candidate.baseWidth, width: content.width)
        }

        let candidateHasLegalBreak =
          hasLegalBreak
          || units.last.map {
            LineFitKernel.permitsBreak(
              previousCanBreakAfter: $0.canBreakAfter,
              nextCanBreakBefore: candidate.canBreakBefore)
          } == true

        // An unobstructed row does not move its existing placements when a
        // new unit fits. Extend it in O(1), using the same horizontal authority
        // and the same vertical-fragment validation as the complete fitter.
        // Exclusions and legal-break rewinds still use the complete fitter.
        if flow.exclusions.isEmpty, let previousMetrics = fittedMetrics, let last = placements.last
        {
          let metrics = (
            ascent: max(
              previousMetrics.ascent,
              (candidate.ascent + candidate.baselineOffset) * candidate.scale),
            descent: max(
              previousMetrics.descent,
              max(0, candidate.descent - candidate.baselineOffset) * candidate.scale)
          )
          let height = max(metrics.ascent + metrics.descent + leading, tolerance)
          let fragments = try flow.fragments(atY: lineTop, height: height)
          let originX = last.originX + last.unit.width * last.unit.scale
          let advance = candidate.width * candidate.scale
          if let fragment = fragments.first, advance.isFinite, advance >= 0,
            LineFitKernel.fitsPrevalidated(
              currentWidth: originX - fragment.originX,
              additionalAdvance: advance, maximumWidth: fragment.maxWidth,
              tolerance: tolerance)
              || LineFitKernel.permitsUnbreakableOverflow(
                allowed: true, hasLegalBreak: candidateHasLegalBreak)
          {
            units.append(candidate)
            placements.append(FlowPlacement(unit: candidate, originX: originX))
            fittedMetrics = metrics
            hasLegalBreak = candidateHasLegalBreak
            lineState = candidateState
            lineStart = lineStart ?? candidate.start
            lineEnd = candidate.end
            if candidate.breakAfter {
              try appendLine(
                placements: placements, stateAfter: lineState, top: lineTop,
                lineHeight: metrics, start: lineStart ?? candidate.start, end: candidate.end)
              retryAtNextRow = false
              break lineLoop
            }
            continue lineLoop
          }
        }

        let candidateUnits = units + [candidate]
        let fit = try fitFlowUnits(candidateUnits, top: lineTop, flow: flow)
        switch fit {
        case .placed(let newPlacements, let metrics):
          units = candidateUnits
          placements = newPlacements
          fittedMetrics = metrics
          hasLegalBreak = candidateHasLegalBreak
          lineState = candidateState
          lineStart = lineStart ?? candidate.start
          lineEnd = candidate.end
          if candidate.breakAfter {
            try appendLine(
              placements: placements,
              stateAfter: lineState,
              top: lineTop,
              lineHeight: metrics,
              start: lineStart ?? candidate.start,
              end: lineEnd ?? candidate.end
            )
            retryAtNextRow = false
            break lineLoop
          }
        case .needsNextRow:
          if units.isEmpty {
            let advance = max(candidate.ascent + candidate.descent + leading, tolerance)
            let nextTop = lineTop + advance
            guard nextTop.isFinite, nextTop < content.maxY else {
              throw InlineLayoutError.flowContentExceedsRegion
            }
            lineTop = nextTop
            retryAtNextRow = true
            break lineLoop
          }
          let metrics = lineMetrics(for: units)
          try appendLine(
            placements: placements,
            stateAfter: lineState,
            top: lineTop,
            lineHeight: metrics,
            start: lineStart ?? units[0].start,
            end: lineEnd ?? units[0].end
          )
          retryAtNextRow = false
          break lineLoop
        case .rewind(let prefixPlacements, let prefixUnits, let metrics, let prefixEnd):
          guard let prefixStart = prefixUnits.first?.start else {
            throw InlineLayoutError.invalidRenderPlan
          }
          try appendLine(
            placements: prefixPlacements,
            stateAfter: UnitCursorState(cursor: prefixEnd),
            top: lineTop,
            lineHeight: metrics,
            start: prefixStart,
            end: prefixEnd
          )
          retryAtNextRow = false
          break lineLoop
        }
      }

      if retryAtNextRow { continue }
      if state.cursor.atomIndex >= storage.count { break }
      if let maximumLines, lines.count >= maximumLines { break }
      if lineTop >= content.maxY,
        state.cursor.atomIndex < storage.count
      {
        throw InlineLayoutError.flowContentExceedsRegion
      }
    }

    let endCursor = normalized(state.cursor, prepared: prepared)
    let continuation: InlineLayoutContinuation? =
      endCursor.atomIndex < prepared.atoms.count
      ? InlineLayoutContinuation(
        cursor: endCursor,
        preparationRevision: prepared.revision,
        width: content.width,
        leading: leading,
        oversizedVectorPolicy: oversizedVectorPolicy,
        flowRevision: flow.revision,
        nextY: lineTop
      )
      : nil
    let bottom = max(lineTop, content.minY)
    let outputHeight = bottom - flow.rect.minY
    guard outputHeight.isFinite, outputHeight >= 0 else {
      throw InlineLayoutError.invalidFlowRegion("layout height overflowed")
    }
    return InlineLayoutResult(
      lines: lines,
      width: content.width,
      height: outputHeight,
      preparationRevision: prepared.revision,
      continuation: continuation,
      flowRevision: flow.revision
    )
  }

  /// Lays out the next bounded tail and returns a continuation when content remains.
  public func layoutTail(
    prepared: PreparedInlineDocument,
    from continuation: InlineLayoutContinuation,
    width: Double,
    maximumLines: Int = 1,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineLayoutResult {
    try layout(
      prepared: prepared,
      width: width,
      continuation: continuation,
      maximumLines: maximumLines,
      cancellation: cancellation
    )
  }

  private struct UnitCursorState: Sendable {
    var cursor: InlineCursor
  }

  /// Read-only concatenation of the committed prepared prefix and the atoms
  /// staged by one append. The arrays are intentionally kept as two storage
  /// segments: creating this view never copies or validates the prefix.
  struct InlinePreparedAtomStorage: Sendable {
    let base: [PreparedInlineDocument.Atom]
    let appended: [PreparedInlineDocument.Atom]

    init(
      base: [PreparedInlineDocument.Atom],
      appended: [PreparedInlineDocument.Atom] = []
    ) {
      self.base = base
      self.appended = appended
    }

    var count: Int { base.count + appended.count }

    subscript(index: Int) -> PreparedInlineDocument.Atom {
      precondition(index >= 0 && index < count)
      return index < base.count ? base[index] : appended[index - base.count]
    }
  }

  struct InlineAppendLayoutOutput: Sendable {
    let lines: [InlineLayoutLine]
    let endCursor: InlineCursor
    let height: Double
    let visitedUnits: Int
  }

  private struct LayoutUnit: Sendable {
    let id: String
    let kind: PositionedInlineAtomKind
    let start: InlineCursor
    let end: InlineCursor
    let sourceRange: InlineSourceRange?
    let baseWidth: Double
    let ascent: Double
    let descent: Double
    let baselineOffset: Double
    let breakBefore: Bool
    let breakAfter: Bool
    let canBreakBefore: Bool
    let canBreakAfter: Bool
    let isVector: Bool
    let isImage: Bool
    let isHardBreak: Bool
    var scale: Double = 1
    var width: Double { baseWidth }
  }

  private struct TextLineFitAdapter: Sendable {
    let text: PreparedInlineText

    func breakBefore(index: Int) -> Bool {
      let behavior = text.atom.breakBehavior
      return index == 0 && (behavior == .breakBefore || behavior == .keepTogether)
    }

    func canBreakBefore() -> Bool {
      let behavior = text.atom.breakBehavior
      return behavior != .noBreakAround && behavior != .keepTogether
    }

    func canBreakAfter(index: Int, isLast: Bool) -> Bool {
      guard text.shaped.graphemeCanBreakAfter[index] else { return false }
      return containsSorted(
        text.textBreakEnds, value: text.shaped.graphemeRanges[index].endUTF16
      ) || isLast
    }

    private func containsSorted(_ values: [Int], value: Int) -> Bool {
      var lower = 0
      var upper = values.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if values[middle] < value {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower < values.count && values[lower] == value
    }
  }

  private func nextUnit(
    storage: InlinePreparedAtomStorage,
    state: inout UnitCursorState,
    cancellation: InlineCancellationCheck
  ) throws -> LayoutUnit? {
    while state.cursor.atomIndex < storage.count {
      try cancellation()
      let atomIndex = state.cursor.atomIndex
      let atomStart = state.cursor.graphemeIndex
      switch storage[atomIndex] {
      case .vector(let preparedVector):
        guard atomStart == 0 else {
          state.cursor = InlineCursor(atomIndex: atomIndex + 1, graphemeIndex: 0)
          continue
        }
        let vector = preparedVector.atom
        state.cursor = InlineCursor(atomIndex: atomIndex + 1, graphemeIndex: 0)
        return LayoutUnit(
          id: vector.id,
          kind: .vector,
          start: InlineCursor(atomIndex: atomIndex, graphemeIndex: 0),
          end: state.cursor,
          sourceRange: nil,
          baseWidth: vector.metrics.advance,
          ascent: vector.metrics.ascent,
          descent: vector.metrics.descent,
          baselineOffset: vector.metrics.baselineOffset,
          breakBefore: vector.breakBehavior == .breakBefore
            || vector.breakBehavior == .keepTogether,
          breakAfter: vector.breakBehavior == .breakAfter,
          canBreakBefore: vector.breakBehavior != .noBreakAround,
          canBreakAfter: vector.breakBehavior != .noBreakAround,
          isVector: true,
          isImage: false,
          isHardBreak: false
        )
      case .text(let preparedText):
        let text = preparedText.atom
        let lineFit = TextLineFitAdapter(text: preparedText)
        guard atomStart < preparedText.graphemes.count else {
          state.cursor = InlineCursor(atomIndex: atomIndex + 1, graphemeIndex: 0)
          continue
        }
        let index = atomStart
        let grapheme = preparedText.graphemes[index]
        let isHardBreak = LineBreakOpportunityKernel.isHardBreak(grapheme)
        let start = InlineCursor(atomIndex: atomIndex, graphemeIndex: index)
        let isLast = index + 1 == preparedText.graphemes.count
        let end =
          isLast
          ? InlineCursor(atomIndex: atomIndex + 1, graphemeIndex: 0)
          : InlineCursor(atomIndex: atomIndex, graphemeIndex: index + 1)
        state.cursor = end
        return LayoutUnit(
          id: text.id,
          kind: .text,
          start: start,
          end: end,
          sourceRange: preparedText.shaped.graphemeRanges[index],
          baseWidth: isHardBreak ? 0 : preparedText.shaped.graphemeAdvances[index],
          ascent: preparedText.metrics.ascent,
          descent: preparedText.metrics.descent,
          baselineOffset: preparedText.atom.style.baselineOffset,
          breakBefore: lineFit.breakBefore(index: index),
          breakAfter: isLast && text.breakBehavior == .breakAfter,
          canBreakBefore: lineFit.canBreakBefore(),
          canBreakAfter: lineFit.canBreakAfter(index: index, isLast: isLast),
          isVector: false,
          isImage: false,
          isHardBreak: isHardBreak
        )
      case .image(let preparedImage):
        guard atomStart == 0 else {
          state.cursor = InlineCursor(atomIndex: atomIndex + 1, graphemeIndex: 0)
          continue
        }
        let image = preparedImage.atom
        state.cursor = InlineCursor(atomIndex: atomIndex + 1, graphemeIndex: 0)
        return LayoutUnit(
          id: image.id,
          kind: .image,
          start: InlineCursor(atomIndex: atomIndex, graphemeIndex: 0),
          end: state.cursor,
          sourceRange: nil,
          baseWidth: image.metrics.advance,
          ascent: image.metrics.ascent,
          descent: image.metrics.descent,
          baselineOffset: image.metrics.baselineOffset,
          breakBefore: image.breakBehavior == .breakBefore
            || image.breakBehavior == .keepTogether,
          breakAfter: image.breakBehavior == .breakAfter,
          canBreakBefore: image.breakBehavior != .noBreakAround,
          canBreakAfter: image.breakBehavior != .noBreakAround,
          isVector: false,
          isImage: true,
          isHardBreak: false
        )
      }
    }
    return nil
  }

  private func atEnd(_ state: UnitCursorState, storage: InlinePreparedAtomStorage) -> Bool {
    normalized(state.cursor, storage: storage).atomIndex >= storage.count
  }

  /// Lays out the mutable append tail over a segmented prepared view.
  ///
  /// This entry point deliberately has no public-document construction or
  /// whole-document validation in its path. The caller supplies the logical
  /// start, global line index, and global baseline origin so every emitted
  /// line remains in document coordinates while only the replaceable tail is
  /// visited.
  func layoutAppendTail(
    storage: InlinePreparedAtomStorage,
    start: InlineCursor,
    lineIndex: Int,
    baselineOrigin: Double,
    width: Double,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineAppendLayoutOutput {
    guard width.isFinite, width >= 0 else { throw InlineLayoutError.invalidWidth(width) }
    guard lineIndex >= 0, baselineOrigin.isFinite, baselineOrigin >= 0 else {
      throw InlineLayoutError.unsupportedShaping("invalid append layout origin")
    }
    try validate(policy: oversizedVectorPolicy)

    let tolerance = 1.0 / 64.0
    var lines: [InlineLayoutLine] = []
    var current: [LayoutUnit] = []
    var currentWidth = 0.0
    var currentHasLegalBreak = false
    var cursor = normalized(start, storage: storage)
    var currentLineIndex = lineIndex
    var baseline = baselineOrigin
    var unitState = UnitCursorState(cursor: cursor)
    var visitedUnits = 0

    func totalWidth(of units: [LayoutUnit]) -> Double {
      units.reduce(0) { $0 + $1.width * $1.scale }
    }

    func fit(_ units: [LayoutUnit]) throws -> LineFitKernel.Decision {
      do {
        return try LineFitKernel.fit(
          units: units.map {
            LineFitKernel.Unit(
              advance: $0.width * $0.scale,
              canBreakBefore: $0.canBreakBefore,
              canBreakAfter: $0.canBreakAfter
            )
          },
          fragments: [LineFitKernel.Fragment(originX: 0, maxWidth: width)],
          tolerance: tolerance,
          allowUnbreakableOverflow: true
        )
      } catch {
        throw InlineLayoutError.unsupportedShaping("invalid append line-fit input: \(error)")
      }
    }

    func flush() throws {
      guard !current.isEmpty else { return }
      let ascent = current.map { $0.ascent + $0.baselineOffset }.max() ?? 0
      let descent = current.map { max(0, $0.descent - $0.baselineOffset) }.max() ?? 0
      let line = try makeLine(
        units: current,
        index: currentLineIndex,
        baseline: baseline + ascent,
        ascent: ascent,
        descent: descent,
        start: current[0].start,
        end: cursor,
        width: currentWidth
      )
      lines.append(line)
      baseline += line.height
      currentLineIndex += 1
      current.removeAll(keepingCapacity: true)
      currentWidth = 0
      currentHasLegalBreak = false
    }

    while true {
      try cancellation()
      guard
        var unit = try nextUnit(
          storage: storage, state: &unitState, cancellation: cancellation
        )
      else {
        break
      }
      visitedUnits += 1
      let isLastUnit = atEnd(unitState, storage: storage)

      if unit.isHardBreak {
        if current.isEmpty {
          cursor = unit.end
          let emptyLine = try InlineLayoutLine(
            index: currentLineIndex,
            baselineY: baseline,
            ascent: 0,
            descent: 0,
            leading: leading,
            width: 0,
            start: unit.start,
            end: unit.end,
            atoms: []
          )
          lines.append(emptyLine)
          baseline += emptyLine.height
          currentLineIndex += 1
        } else {
          try flush()
          cursor = unit.end
          if isLastUnit {
            let emptyLine = try InlineLayoutLine(
              index: currentLineIndex,
              baselineY: baseline,
              ascent: 0,
              descent: 0,
              leading: leading,
              width: 0,
              start: unit.end,
              end: unit.end,
              atoms: []
            )
            lines.append(emptyLine)
            baseline += emptyLine.height
            currentLineIndex += 1
          }
        }
        continue
      }

      if unit.breakBefore && !current.isEmpty {
        try flush()
      }

      if unit.isVector
        && !LineFitKernel.fitsPrevalidated(
          currentWidth: 0, additionalAdvance: unit.width, maximumWidth: width, tolerance: tolerance)
      {
        switch oversizedVectorPolicy {
        case .reject:
          throw InlineLayoutError.oversizedVector(
            id: unit.id, advance: unit.width, width: width)
        case .scaleToFit(let minimumScale):
          let scale = width == 0 ? 0 : width / unit.width
          guard scale.isFinite, scale >= minimumScale else {
            throw InlineLayoutError.oversizedVector(
              id: unit.id, advance: unit.width, width: width)
          }
          unit.scale = scale
        case .overflow:
          break
        }
      }

      if unit.isImage
        && !LineFitKernel.fitsPrevalidated(
          currentWidth: 0, additionalAdvance: unit.width, maximumWidth: width, tolerance: tolerance)
      {
        throw InlineLayoutError.oversizedImage(
          id: unit.id, advance: unit.width, width: width)
      }

      let advance = unit.width * unit.scale
      let candidateHasLegalBreak =
        currentHasLegalBreak
        || current.last.map {
          LineFitKernel.permitsBreak(
            previousCanBreakAfter: $0.canBreakAfter, nextCanBreakBefore: unit.canBreakBefore)
        } == true
      if advance.isFinite, advance >= 0,
        LineFitKernel.fitsPrevalidated(
          currentWidth: currentWidth, additionalAdvance: advance,
          maximumWidth: width, tolerance: tolerance)
          || LineFitKernel.permitsUnbreakableOverflow(
            allowed: true, hasLegalBreak: candidateHasLegalBreak)
      {
        // No rewind or fragment change is possible on a successful extension.
        // Avoid copying and rescanning the complete final-line tail per unit.
        current.append(unit)
        currentWidth += advance
        currentHasLegalBreak = candidateHasLegalBreak
        cursor = unit.end
        if unit.breakAfter { try flush() }
        continue
      }

      let candidate = current + [unit]
      switch try fit(candidate) {
      case .placed:
        current = candidate
        currentWidth = totalWidth(of: current)
        currentHasLegalBreak = candidateHasLegalBreak
        cursor = unit.end

      case .rewind(let prefixCount, _):
        guard prefixCount > 0, prefixCount < candidate.count else {
          throw InlineLayoutError.invalidRenderPlan
        }
        let prefix = Array(candidate.prefix(prefixCount))
        let suffix = Array(candidate.dropFirst(prefixCount))
        guard let prefixEnd = prefix.last?.end, let suffixEnd = suffix.last?.end else {
          throw InlineLayoutError.invalidRenderPlan
        }
        current = prefix
        currentWidth = totalWidth(of: prefix)
        cursor = prefixEnd
        try flush()

        guard case .placed = try fit(suffix) else {
          throw InlineLayoutError.invalidRenderPlan
        }
        current = suffix
        currentWidth = totalWidth(of: suffix)
        currentHasLegalBreak = zip(suffix, suffix.dropFirst()).contains {
          LineFitKernel.permitsBreak(
            previousCanBreakAfter: $0.0.canBreakAfter, nextCanBreakBefore: $0.1.canBreakBefore)
        }
        cursor = suffixEnd

      case .needsNextRow:
        guard !current.isEmpty else {
          throw InlineLayoutError.flowContentExceedsRegion
        }
        try flush()
        guard case .placed = try fit([unit]) else {
          throw InlineLayoutError.flowContentExceedsRegion
        }
        current = [unit]
        currentWidth = unit.width * unit.scale
        cursor = unit.end
      }

      if unit.breakAfter {
        try flush()
      }
    }
    try flush()

    return InlineAppendLayoutOutput(
      lines: lines,
      endCursor: normalized(unitState.cursor, storage: storage),
      height: baseline,
      visitedUnits: visitedUnits
    )
  }

  private struct FlowPlacement: Sendable {
    let unit: LayoutUnit
    let originX: Double
  }

  private enum FlowFitResult {
    case placed([FlowPlacement], (ascent: Double, descent: Double))
    case needsNextRow
    case rewind(
      placements: [FlowPlacement],
      units: [LayoutUnit],
      metrics: (ascent: Double, descent: Double),
      end: InlineCursor
    )
  }

  private func lineMetrics(for units: [LayoutUnit]) -> (ascent: Double, descent: Double) {
    let ascent = units.map { ($0.ascent + $0.baselineOffset) * $0.scale }.max() ?? 0
    let descent =
      units.map {
        max(0, ($0.descent - $0.baselineOffset) * $0.scale)
      }.max() ?? 0
    return (ascent, descent)
  }

  /// Fits a complete candidate line against fragments computed from its final
  /// metrics. Recomputing the fragments here is intentional: adding a taller
  /// image/vector can extend the line rectangle into an exclusion that did not
  /// intersect the provisional line, so the candidate is re-evaluated before
  /// any geometry is published.
  private func fitFlowUnits(
    _ units: [LayoutUnit],
    top: Double,
    flow: InlineFlowRegion
  ) throws -> FlowFitResult {
    let metrics = lineMetrics(for: units)
    let height = max(metrics.ascent + metrics.descent + leading, 1.0 / 64.0)
    let fragments = try flow.fragments(atY: top, height: height)
    guard !fragments.isEmpty else { return .needsNextRow }

    let tolerance = 1.0 / 64.0
    let content = flow.contentRect
    let unobstructed =
      fragments.count == 1
      && abs(fragments[0].originX - content.minX) <= tolerance
      && abs(fragments[0].maxWidth - content.width) <= tolerance

    let fitUnits = units.map {
      LineFitKernel.Unit(
        advance: $0.width * $0.scale,
        canBreakBefore: $0.canBreakBefore,
        canBreakAfter: $0.canBreakAfter
      )
    }
    let fitFragments = fragments.map {
      LineFitKernel.Fragment(originX: $0.originX, maxWidth: $0.maxWidth)
    }

    let decision: LineFitKernel.Decision
    do {
      decision = try LineFitKernel.fit(
        units: fitUnits,
        fragments: fitFragments,
        tolerance: tolerance,
        allowUnbreakableOverflow: unobstructed
      )
    } catch {
      throw InlineLayoutError.unsupportedShaping("invalid line-fit input: \(error)")
    }

    switch decision {
    case .placed(let fitPlacements):
      let placements = fitPlacements.map {
        FlowPlacement(unit: units[$0.unitIndex], originX: $0.originX)
      }
      return .placed(placements, metrics)

    case .rewind(let prefixCount, let fitPlacements):
      guard prefixCount > 0, prefixCount < units.count else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let prefixUnits = Array(units.prefix(prefixCount))
      guard let prefixEnd = prefixUnits.last?.end else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let prefixPlacements = fitPlacements.map {
        FlowPlacement(unit: units[$0.unitIndex], originX: $0.originX)
      }
      return .rewind(
        placements: prefixPlacements,
        units: prefixUnits,
        metrics: lineMetrics(for: prefixUnits),
        end: prefixEnd
      )

    case .needsNextRow:
      return .needsNextRow
    }
  }

  private func makeFlowLine(
    placements: [FlowPlacement],
    index: Int,
    baseline: Double,
    ascent: Double,
    descent: Double,
    start: InlineCursor,
    end: InlineCursor
  ) throws -> InlineLayoutLine {
    var atoms: [PositionedInlineAtom] = []
    atoms.reserveCapacity(placements.count)
    var offset = 0
    var totalWidth = 0.0
    let tolerance = 1.0 / 64.0

    while offset < placements.count {
      let first = placements[offset]
      var last = first
      var fragmentWidth = first.unit.width * first.unit.scale
      var next = offset + 1
      while next < placements.count {
        let candidate = placements[next]
        let candidateWidth = candidate.unit.width * candidate.unit.scale
        guard candidate.unit.id == first.unit.id,
          candidate.unit.kind == first.unit.kind,
          candidate.unit.sourceRange != nil,
          last.unit.sourceRange != nil,
          abs(candidate.originX - (last.originX + last.unit.width * last.unit.scale))
            <= tolerance
        else { break }
        last = candidate
        fragmentWidth += candidateWidth
        next += 1
      }

      let sourceRange: InlineSourceRange?
      if let firstRange = first.unit.sourceRange, let lastRange = last.unit.sourceRange {
        sourceRange = try InlineSourceRange(
          startUTF16: firstRange.startUTF16,
          endUTF16: lastRange.endUTF16
        )
      } else {
        sourceRange = nil
      }
      let metrics = try InlineMetrics(
        advance: fragmentWidth,
        ascent: first.unit.ascent * first.unit.scale,
        descent: first.unit.descent * first.unit.scale,
        baselineOffset: first.unit.baselineOffset * first.unit.scale
      )
      atoms.append(
        try PositionedInlineAtom(
          atomID: first.unit.id,
          kind: first.unit.kind,
          lineIndex: index,
          originX: first.originX,
          baselineY: baseline,
          width: fragmentWidth,
          height: metrics.ascent + metrics.descent,
          metrics: metrics,
          scale: first.unit.scale,
          sourceRange: sourceRange
        ))
      totalWidth += fragmentWidth
      offset = next
    }

    return try InlineLayoutLine(
      index: index,
      baselineY: baseline,
      ascent: ascent,
      descent: descent,
      leading: leading,
      width: totalWidth,
      start: start,
      end: end,
      atoms: atoms
    )
  }

  private func makeLine(
    units: [LayoutUnit],
    index: Int,
    baseline: Double,
    ascent: Double,
    descent: Double,
    start: InlineCursor,
    end: InlineCursor,
    width: Double
  ) throws -> InlineLayoutLine {
    var placed: [PositionedInlineAtom] = []
    var x = 0.0
    var offset = 0
    while offset < units.count {
      let first = units[offset]
      var last = first
      var fragmentWidth = first.width * first.scale
      var next = offset + 1
      while next < units.count,
        units[next].id == first.id,
        units[next].kind == first.kind,
        units[next].sourceRange != nil,
        last.sourceRange != nil
      {
        last = units[next]
        fragmentWidth += units[next].width * units[next].scale
        next += 1
      }
      let sourceRange: InlineSourceRange?
      if let firstRange = first.sourceRange, let lastRange = last.sourceRange {
        sourceRange = try InlineSourceRange(
          startUTF16: firstRange.startUTF16,
          endUTF16: lastRange.endUTF16
        )
      } else {
        sourceRange = nil
      }
      let metrics = try InlineMetrics(
        advance: fragmentWidth,
        ascent: first.ascent * first.scale,
        descent: first.descent * first.scale,
        baselineOffset: first.baselineOffset * first.scale
      )
      placed.append(
        try PositionedInlineAtom(
          atomID: first.id,
          kind: first.kind,
          lineIndex: index,
          originX: x,
          baselineY: baseline,
          width: fragmentWidth,
          height: metrics.ascent + metrics.descent,
          metrics: metrics,
          scale: first.scale,
          sourceRange: sourceRange
        ))
      x += fragmentWidth
      offset = next
    }
    return try InlineLayoutLine(
      index: index,
      baselineY: baseline,
      ascent: ascent,
      descent: descent,
      leading: leading,
      width: width,
      start: start,
      end: end,
      atoms: placed
    )
  }

  private func validate(
    _ continuation: InlineLayoutContinuation?,
    prepared: PreparedInlineDocument,
    width: Double,
    flowRevision: UInt64 = 0
  ) throws -> InlineCursor {
    guard let continuation else { return .zero }
    guard continuation.preparationRevision == prepared.revision,
      continuation.width == width,
      continuation.leading == leading,
      continuation.oversizedVectorPolicy == oversizedVectorPolicy,
      continuation.flowRevision == flowRevision,
      continuation.nextY.isFinite
    else {
      throw InlineLayoutError.invalidContinuation
    }
    let cursor = continuation.cursor
    guard cursor.atomIndex >= 0, cursor.atomIndex <= prepared.atoms.count else {
      throw InlineLayoutError.invalidCursor(cursor)
    }
    if cursor.atomIndex == prepared.atoms.count {
      guard cursor.graphemeIndex == 0 else { throw InlineLayoutError.invalidCursor(cursor) }
    } else {
      let count: Int
      switch prepared.atoms[cursor.atomIndex] {
      case .text(let text): count = text.graphemes.count
      case .vector: count = 1
      case .image: count = 1
      }
      guard cursor.graphemeIndex >= 0,
        cursor.graphemeIndex < count || (count == 0 && cursor.graphemeIndex == 0)
      else {
        throw InlineLayoutError.invalidCursor(cursor)
      }
    }
    return cursor
  }

  private func normalized(_ cursor: InlineCursor, prepared: PreparedInlineDocument) -> InlineCursor
  {
    var atomIndex = cursor.atomIndex
    let originalAtomIndex = atomIndex
    while atomIndex < prepared.atoms.count {
      guard case .text(let text) = prepared.atoms[atomIndex], text.graphemes.isEmpty else { break }
      atomIndex += 1
    }
    let graphemeIndex = atomIndex == originalAtomIndex ? cursor.graphemeIndex : 0
    return InlineCursor(atomIndex: atomIndex, graphemeIndex: graphemeIndex)
  }

  private func normalized(_ cursor: InlineCursor, storage: InlinePreparedAtomStorage)
    -> InlineCursor
  {
    var atomIndex = cursor.atomIndex
    let originalAtomIndex = atomIndex
    while atomIndex < storage.count {
      guard case .text(let text) = storage[atomIndex], text.graphemes.isEmpty else { break }
      atomIndex += 1
    }
    let graphemeIndex = atomIndex == originalAtomIndex ? cursor.graphemeIndex : 0
    return InlineCursor(atomIndex: atomIndex, graphemeIndex: graphemeIndex)
  }

  private func validate(policy: InlineOversizedVectorPolicy) throws {
    if case .scaleToFit(let minimumScale) = policy,
      !minimumScale.isFinite || minimumScale <= 0 || minimumScale > 1
    {
      throw InlineLayoutError.invalidOversizedVectorPolicy
    }
  }
}
