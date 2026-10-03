import Foundation

/// Package-internal, renderer-neutral authority for greedy horizontal fitting.
///
/// Callers own semantic unit construction and vertical metrics. This kernel owns
/// the only decisions about whether measured units fit available horizontal
/// fragments, when a legal break must rewind a suffix, and when the caller must
/// advance to the next row.
package enum LineFitKernel {
  package struct Unit: Sendable, Hashable {
    package let advance: Double
    package let canBreakBefore: Bool
    package let canBreakAfter: Bool

    package init(
      advance: Double,
      canBreakBefore: Bool,
      canBreakAfter: Bool
    ) {
      self.advance = advance
      self.canBreakBefore = canBreakBefore
      self.canBreakAfter = canBreakAfter
    }
  }

  package struct Fragment: Sendable, Hashable {
    package let originX: Double
    package let maxWidth: Double

    package init(originX: Double, maxWidth: Double) {
      self.originX = originX
      self.maxWidth = maxWidth
    }

    package var maxX: Double { originX + maxWidth }
  }

  package struct Placement: Sendable, Hashable {
    package let unitIndex: Int
    package let originX: Double

    package init(unitIndex: Int, originX: Double) {
      self.unitIndex = unitIndex
      self.originX = originX
    }
  }

  package enum Decision: Sendable, Hashable {
    case placed([Placement])
    case rewind(prefixCount: Int, placements: [Placement])
    case needsNextRow
  }

  package enum Failure: Error, Sendable, Equatable {
    case invalidTolerance(Double)
    case invalidAdvance(index: Int, value: Double)
    case invalidFragment(index: Int, originX: Double, maxWidth: Double)
  }

  /// Fits a complete candidate line against one or more ordered fragments.
  ///
  /// `allowUnbreakableOverflow` preserves the established behavior for a
  /// single unbroken text cluster in an unobstructed line. Callers must reject
  /// atom kinds that are not allowed to overflow before invoking the kernel.
  package static func fit(
    units: [Unit],
    fragments: [Fragment],
    tolerance: Double,
    allowUnbreakableOverflow: Bool
  ) throws -> Decision {
    guard tolerance.isFinite, tolerance >= 0 else {
      throw Failure.invalidTolerance(tolerance)
    }
    for (index, fragment) in fragments.enumerated() {
      guard fragment.originX.isFinite, fragment.maxWidth.isFinite, fragment.maxWidth >= 0,
        fragment.maxX.isFinite
      else {
        throw Failure.invalidFragment(
          index: index, originX: fragment.originX, maxWidth: fragment.maxWidth)
      }
    }
    for (index, unit) in units.enumerated() {
      guard unit.advance.isFinite, unit.advance >= 0 else {
        throw Failure.invalidAdvance(index: index, value: unit.advance)
      }
    }
    guard !units.isEmpty else { return .placed([]) }
    guard !fragments.isEmpty else { return .needsNextRow }

    var fragmentIndex = 0
    var x = fragments[0].originX
    var placements: [Placement] = []
    placements.reserveCapacity(units.count)
    var lastLegalBreakIndex: Int?

    for (index, unit) in units.enumerated() {
      var didPlace = false
      let legalBreakBefore =
        index > 0
        && permitsBreak(
          previousCanBreakAfter: units[index - 1].canBreakAfter,
          nextCanBreakBefore: unit.canBreakBefore)
      if legalBreakBefore {
        lastLegalBreakIndex = index
      }

      if fitsPrevalidated(
        currentWidth: x - fragments[fragmentIndex].originX,
        additionalAdvance: unit.advance,
        maximumWidth: fragments[fragmentIndex].maxWidth,
        tolerance: tolerance
      ) {
        placements.append(Placement(unitIndex: index, originX: x))
        x += unit.advance
        didPlace = true
      } else if index == 0 || legalBreakBefore {
        var next = fragmentIndex + 1
        while next < fragments.count {
          if fitsPrevalidated(
            currentWidth: 0,
            additionalAdvance: unit.advance,
            maximumWidth: fragments[next].maxWidth,
            tolerance: tolerance
          ) {
            fragmentIndex = next
            x = fragments[next].originX
            placements.append(Placement(unitIndex: index, originX: x))
            x += unit.advance
            didPlace = true
            break
          }
          next += 1
        }
      }

      if !didPlace,
        permitsUnbreakableOverflow(
          allowed: allowUnbreakableOverflow, hasLegalBreak: lastLegalBreakIndex != nil)
      {
        placements.append(Placement(unitIndex: index, originX: x))
        x += unit.advance
        didPlace = true
      }

      guard didPlace else {
        if let breakIndex = lastLegalBreakIndex, breakIndex < index {
          return .rewind(
            prefixCount: breakIndex,
            placements: Array(placements.prefix(breakIndex))
          )
        }
        return .needsNextRow
      }
    }

    return .placed(placements)
  }

  /// Shared adjacency and overflow policy for complete and incremental fitting.
  @inline(__always)
  package static func permitsBreak(
    previousCanBreakAfter: Bool, nextCanBreakBefore: Bool
  ) -> Bool {
    previousCanBreakAfter && nextCanBreakBefore
  }

  @inline(__always)
  package static func permitsUnbreakableOverflow(allowed: Bool, hasLegalBreak: Bool) -> Bool {
    allowed && !hasLegalBreak
  }

  /// Nonthrowing fit primitive for already-validated prepared geometry.
  /// All Core line walkers and the mixed/append solver route horizontal fit
  /// comparisons through this function so the tolerance rule has one owner.
  @inline(__always)
  package static func fitsPrevalidated(
    currentWidth: Double,
    additionalAdvance: Double,
    maximumWidth: Double,
    tolerance: Double
  ) -> Bool {
    currentWidth + additionalAdvance <= maximumWidth + tolerance
  }

}
