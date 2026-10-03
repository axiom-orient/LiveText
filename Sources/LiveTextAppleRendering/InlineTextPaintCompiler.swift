import CoreGraphics
import Foundation
import LiveTextCore
public import LiveTextLayout
import SwiftUI

#if canImport(CoreText)
  import CoreText
#endif

#if canImport(CoreText)
  private func makeSemanticStrokeEntry(
    unitID: InlineRevealUnitID,
    sourceRange: InlineSourceRange,
    stroke: InlineWritingStroke,
    prepared: PreparedInlineText,
    advancePrefixes: [Double],
    positioned: PositionedInlineAtom,
    fragmentRange: InlineSourceRange
  ) throws -> InlineTextPaintEntry {
    guard
      let graphemeIndex = InlineSourceRangeSearch.exactIndex(
        of: sourceRange, in: prepared.shaped.graphemeRanges)
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let fragmentStart = InlineSourceRangeSearch.firstStarting(
      atOrAfter: fragmentRange.startUTF16, in: prepared.shaped.graphemeRanges)
    guard graphemeIndex >= fragmentStart else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let xBeforeUnit = advancePrefixes[graphemeIndex]
    let xBeforeFragment = advancePrefixes[fragmentStart]
    let cellWidth = prepared.shaped.graphemeAdvances[graphemeIndex]
    let cellHeight = max(
      1,
      max(positioned.metrics.ascent + positioned.metrics.descent, positioned.height))
    guard cellWidth.isFinite, cellWidth > 0, cellHeight.isFinite else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let points = stroke.points.map {
      CGPoint(
        x: CGFloat((xBeforeUnit - xBeforeFragment) + $0.x * cellWidth),
        y: CGFloat($0.y * cellHeight))
    }
    guard let first = points.first else {
      throw InlineLayoutError.invalidWritingStroke("semantic stroke has no points")
    }
    var path = Path()
    path.move(to: first)
    for point in points.dropFirst() { path.addLine(to: point) }
    let width = max(
      0.5,
      stroke.points.map(\.width).reduce(0, +) / Double(stroke.points.count)
        * min(cellWidth, cellHeight) * 0.08)
    let bounds = path.boundingRect.insetBy(
      dx: -CGFloat(width * 0.5), dy: -CGFloat(width * 0.5))
    guard bounds.width > 0, bounds.height > 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    return try InlineTextPaintEntry(
      semanticStrokePath: path,
      sourceRange: sourceRange,
      writingUnitID: unitID,
      strokeWidth: CGFloat(width),
      strokePoints: points,
      localPaintBounds: bounds)
  }
#endif

/// One immutable paint payload for a prepared text fragment.
///
/// Outline glyphs remain SwiftUI paths so existing pigment and chalk adapters
/// keep their vector behaviour. A glyph for which Core Text has no outline
/// (for example, an AppleColorEmoji `sbix` glyph) retains the validated Core
/// Text run and glyph index instead. The run is drawn directly into the
/// adapter's CGContext; no bitmap or SwiftUI image is created.
package struct InlineTextPaintEntry {
  public enum Kind: String {
    case outline
    case coreText
    case semanticStroke
  }

  public let kind: Kind
  public let sourceRange: InlineSourceRange
  public let localDrawRect: CGRect
  public let localPaintBounds: CGRect
  public let outlinePath: Path?
  /// Non-nil only for a prepared semantic handwriting stroke.  The path is a
  /// centerline in fragment-local coordinates; the width is retained with
  /// the entry so frame-time painting never performs face/catalog lookup.
  public let writingUnitID: InlineRevealUnitID?
  public let semanticStrokeWidth: CGFloat
  public let semanticStrokePoints: [CGPoint]

  #if canImport(CoreText)
    /// The retained, revalidated run used by a `.coreText` entry.
    public let coreTextRun: CTRun?
    /// Index into `coreTextRun`, measured in glyphs rather than UTF-16 units.
    public let coreTextGlyphIndex: Int?
    private let coreTextFragmentOriginX: CGFloat?
    private let coreTextAscent: CGFloat?
  #endif

  public init(
    outlinePath: Path,
    sourceRange: InlineSourceRange,
    localPaintBounds: CGRect
  ) throws {
    try Self.validate(rect: localPaintBounds)
    guard localPaintBounds.width > 0, localPaintBounds.height > 0 else {
      throw InlineLayoutError.unsupportedShaping("outline glyph has empty paint bounds")
    }
    self.kind = .outline
    self.sourceRange = sourceRange
    self.localDrawRect = localPaintBounds
    self.localPaintBounds = localPaintBounds
    self.outlinePath = outlinePath
    self.writingUnitID = nil
    self.semanticStrokeWidth = 0
    self.semanticStrokePoints = []
    #if canImport(CoreText)
      self.coreTextRun = nil
      self.coreTextGlyphIndex = nil
      self.coreTextFragmentOriginX = nil
      self.coreTextAscent = nil
    #endif
  }

  package init(
    semanticStrokePath: Path,
    sourceRange: InlineSourceRange,
    writingUnitID: InlineRevealUnitID,
    strokeWidth: CGFloat,
    strokePoints: [CGPoint],
    localPaintBounds: CGRect
  ) throws {
    try Self.validate(rect: localPaintBounds)
    guard strokeWidth.isFinite, strokeWidth > 0,
      localPaintBounds.width > 0, localPaintBounds.height > 0
    else {
      throw InlineLayoutError.unsupportedShaping("semantic stroke has empty paint bounds")
    }
    self.kind = .semanticStroke
    self.sourceRange = sourceRange
    self.localDrawRect = localPaintBounds
    self.localPaintBounds = localPaintBounds
    self.outlinePath = semanticStrokePath
    self.writingUnitID = writingUnitID
    self.semanticStrokeWidth = strokeWidth
    self.semanticStrokePoints = strokePoints
    #if canImport(CoreText)
      self.coreTextRun = nil
      self.coreTextGlyphIndex = nil
      self.coreTextFragmentOriginX = nil
      self.coreTextAscent = nil
    #endif
  }

  #if canImport(CoreText)
    fileprivate init(
      coreTextRun: CTRun,
      coreTextGlyphIndex: Int,
      sourceRange: InlineSourceRange,
      localPaintBounds: CGRect,
      fragmentOriginX: Double,
      ascent: Double
    ) throws {
      guard coreTextGlyphIndex >= 0,
        fragmentOriginX.isFinite,
        ascent.isFinite
      else {
        throw InlineLayoutError.invalidRenderPlan
      }
      try Self.validate(rect: localPaintBounds)
      guard localPaintBounds.width > 0, localPaintBounds.height > 0 else {
        throw InlineLayoutError.unsupportedShaping("color glyph has empty paint bounds")
      }
      guard coreTextGlyphIndex < CTRunGetGlyphCount(coreTextRun) else {
        throw InlineLayoutError.unsupportedShaping("Core Text glyph index is outside its run")
      }
      self.kind = .coreText
      self.sourceRange = sourceRange
      self.localDrawRect = localPaintBounds
      self.localPaintBounds = localPaintBounds
      self.outlinePath = nil
      self.writingUnitID = nil
      self.semanticStrokeWidth = 0
      self.semanticStrokePoints = []
      self.coreTextRun = coreTextRun
      self.coreTextGlyphIndex = coreTextGlyphIndex
      self.coreTextFragmentOriginX = CGFloat(fragmentOriginX)
      self.coreTextAscent = CGFloat(ascent)
    }

    /// Draw this entry in the fragment-local coordinate system used by the
    /// SwiftUI `Canvas` adapters. Core Text uses y-up user space, while the
    /// Canvas fragment is y-down; the transform is local and fully restored.
    package func draw(in context: inout GraphicsContext) {
      guard kind == .coreText,
        let coreTextRun,
        let coreTextGlyphIndex,
        let fragmentOriginX = coreTextFragmentOriginX,
        let ascent = coreTextAscent
      else { return }
      context.withCGContext { cgContext in
        cgContext.saveGState()
        cgContext.translateBy(x: -fragmentOriginX, y: ascent)
        cgContext.scaleBy(x: 1, y: -1)
        CTRunDraw(
          coreTextRun,
          cgContext,
          CFRange(location: coreTextGlyphIndex, length: 1)
        )
        cgContext.restoreGState()
      }
    }
  #endif

  private static func validate(rect: CGRect) throws {
    guard rect.minX.isFinite, rect.minY.isFinite,
      rect.width.isFinite, rect.width >= 0,
      rect.height.isFinite, rect.height >= 0,
      rect.maxX.isFinite, rect.maxY.isFinite
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
  }
}

/// Shared preparation compiler used by both SwiftUI and Canvas adapters.
///
/// The compiler owns all Core Text access and outline construction. It also
/// reconstructs and validates a Core Text line whenever a pathless glyph is
/// present, then retains only the exact run/glyph payload needed for frame-time
/// `CTRunDraw`. Preparation is atomic: no candidate map is returned after a
/// mapping, bounds, or metric mismatch.
package enum InlineTextPaintCompiler {
  public static func compile(
    geometry: [PreparedInlineGeometry]
  ) throws -> [PositionedInlineAtom: [InlineTextPaintEntry]] {
    var result: [PositionedInlineAtom: [InlineTextPaintEntry]] = [:]
    #if canImport(CoreText)
      var groups: [String: TextGeometryGroup] = [:]
      for (geometryOrder, item) in geometry.enumerated() {
        guard case .text(let positioned, let prepared) = item else { continue }
        guard let sourceRange = positioned.sourceRange else {
          throw InlineLayoutError.invalidRenderPlan
        }
        let fragment = TextFragment(
          positioned: positioned,
          sourceRange: sourceRange,
          geometryOrder: geometryOrder
        )
        if let existing = groups[positioned.atomID], existing.prepared != prepared {
          throw InlineLayoutError.invalidRenderPlan
        }
        groups[
          positioned.atomID,
          default: TextGeometryGroup(
            prepared: prepared,
            fragments: [])
        ].fragments.append(fragment)
      }

      for group in groups.values {
        let fragments = group.fragments.sorted {
          if $0.sourceRange.startUTF16 != $1.sourceRange.startUTF16 {
            return $0.sourceRange.startUTF16 < $1.sourceRange.startUTF16
          }
          if $0.sourceRange.endUTF16 != $1.sourceRange.endUTF16 {
            return $0.sourceRange.endUTF16 < $1.sourceRange.endUTF16
          }
          return $0.geometryOrder < $1.geometryOrder
        }
        for index in 1..<fragments.count {
          guard
            fragments[index - 1].sourceRange.endUTF16
              <= fragments[index].sourceRange.startUTF16
          else {
            throw InlineLayoutError.invalidRenderPlan
          }
        }

        var entries = Array(
          repeating: [InlineTextPaintEntry](),
          count: fragments.count)
        var fragmentOrigins = Array(repeating: 0.0, count: fragments.count)
        var hasGlyph = Array(repeating: false, count: fragments.count)
        var assignments: [GlyphAssignment] = []
        assignments.reserveCapacity(
          group.prepared.shaped.runs.reduce(0) { $0 + $1.glyphs.count })

        for (runIndex, run) in group.prepared.shaped.runs.enumerated() {
          for (glyphIndex, glyph) in run.glyphs.enumerated() {
            let firstFragment = firstTextFragment(
              in: fragments,
              overlapping: glyph.sourceRange)
            guard firstFragment < fragments.count else { continue }

            var fragmentIndex = firstFragment
            var overlapsFragment = false
            while fragmentIndex < fragments.count {
              let fragmentRange = fragments[fragmentIndex].sourceRange
              if fragmentRange.startUTF16 >= glyph.sourceRange.endUTF16 { break }
              if fragmentRange.startUTF16 < fragmentRange.endUTF16,
                glyph.sourceRange.startUTF16 < fragmentRange.endUTF16,
                fragmentRange.startUTF16 < glyph.sourceRange.endUTF16
              {
                overlapsFragment = true
                if !hasGlyph[fragmentIndex] {
                  fragmentOrigins[fragmentIndex] = glyph.positionX
                  hasGlyph[fragmentIndex] = true
                } else {
                  fragmentOrigins[fragmentIndex] = min(
                    fragmentOrigins[fragmentIndex], glyph.positionX)
                }
              }
              fragmentIndex += 1
            }
            guard overlapsFragment else { continue }
            assignments.append(
              GlyphAssignment(
                glyph: glyph,
                runIndex: runIndex,
                glyphIndex: glyphIndex,
                firstFragment: firstFragment,
                endFragment: fragmentIndex
              ))
          }
        }

        var fonts = [CTFont?](
          repeating: nil,
          count: group.prepared.shaped.runs.count)
        let semanticUnits = group.prepared.writingUnits.compactMap {
          unit -> (InlineRevealUnitID, InlineSourceRange, InlineWritingStroke)? in
          guard case .semanticStroke(let stroke) = unit.kind else { return nil }
          return (unit.id, unit.sourceRange, stroke)
        }
        let semanticRanges = semanticUnits.map { $0.1 }
        let semanticRangeSet = Set(semanticRanges)
        var advancePrefixes: [Double] = [0]
        if !semanticUnits.isEmpty {
          advancePrefixes.reserveCapacity(group.prepared.shaped.graphemeAdvances.count + 1)
          var advance = 0.0
          for value in group.prepared.shaped.graphemeAdvances {
            advance += value
            advancePrefixes.append(advance)
          }
        }
        // Repeated stroke ranges share the same cell. Check glyph ownership
        // once through an indexed range join, not once per stroke × glyph.
        let uniqueSemanticRanges = semanticRangeSet.sorted {
          $0.startUTF16 < $1.startUTF16
        }
        for run in group.prepared.shaped.runs {
          for glyph in run.glyphs {
            for index in InlineSourceRangeSearch.overlappingIndices(
              in: uniqueSemanticRanges, with: glyph.sourceRange)
            where uniqueSemanticRanges[index] != glyph.sourceRange {
              throw InlineLayoutError.unsupportedShaping(
                "semantic handwriting unit intersects a shaped glyph cluster")
            }
          }
        }
        var pathlessAssignments: [GlyphAssignment] = []
        pathlessAssignments.reserveCapacity(assignments.count)
        for assignment in assignments {
          let glyph = assignment.glyph
          if semanticRangeSet.contains(glyph.sourceRange) {
            // Ordinary handwriting units are painted from their prepared face
            // path below. Never retain the native font outline for them.
            continue
          }
          if fonts[assignment.runIndex] == nil {
            let run = group.prepared.shaped.runs[assignment.runIndex]
            let font = try resolvedFont(for: run.font)
            fonts[assignment.runIndex] = font
          }
          guard let font = fonts[assignment.runIndex] else {
            throw InlineLayoutError.unsupportedShaping("text run has no resolved font")
          }
          if CTFontCreatePathForGlyph(font, CGGlyph(glyph.glyphID), nil) == nil,
            !isNonRenderingGlyph(glyph, in: group.prepared)
          {
            pathlessAssignments.append(assignment)
          }
        }

        // A pathless glyph must be tied back to Core Text before publication.
        // This validates the glyph id, order, source index, positions, run
        // metrics, and range against the exact prepared shaping payload.
        let reconstructedRuns: [ReconstructedRun]
        if pathlessAssignments.isEmpty {
          reconstructedRuns = []
        } else {
          reconstructedRuns = try reconstructRuns(for: group.prepared)
        }

        for assignment in assignments {
          let glyph = assignment.glyph
          if semanticRangeSet.contains(glyph.sourceRange) { continue }
          guard let font = fonts[assignment.runIndex] else {
            throw InlineLayoutError.unsupportedShaping("text run has no resolved font")
          }
          let path = CTFontCreatePathForGlyph(font, CGGlyph(glyph.glyphID), nil)
          for fragmentIndex in assignment.firstFragment..<assignment.endFragment {
            let fragmentRange = fragments[fragmentIndex].sourceRange
            guard fragmentRange.startUTF16 < fragmentRange.endUTF16,
              glyph.sourceRange.startUTF16 < fragmentRange.endUTF16,
              fragmentRange.startUTF16 < glyph.sourceRange.endUTF16
            else { continue }
            let fragmentOriginX =
              hasGlyph[fragmentIndex]
              ? fragmentOrigins[fragmentIndex]
              : 0
            if isNonRenderingGlyph(glyph, in: group.prepared) {
              // Whitespace remains intentionally non-rendering, even if a
              // custom font happens to expose an outline for its glyph.
              continue
            } else if let path {
              var transform = CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: -1,
                tx: glyph.positionX - fragmentOriginX,
                ty: fragments[fragmentIndex].positioned.metrics.ascent + glyph.positionY
              )
              guard let transformed = path.copy(using: &transform) else {
                throw InlineLayoutError.unsupportedShaping("failed to transform glyph path")
              }
              let localPath = Path(transformed)
              let paintBounds = localPath.boundingRect
              entries[fragmentIndex].append(
                try InlineTextPaintEntry(
                  outlinePath: localPath,
                  sourceRange: glyph.sourceRange,
                  localPaintBounds: paintBounds
                ))
            } else {
              guard assignment.runIndex < reconstructedRuns.count,
                assignment.glyphIndex < reconstructedRuns[assignment.runIndex].glyphs.count
              else {
                throw InlineLayoutError.unsupportedShaping(
                  "Core Text run/glyph mapping changed during direct drawing")
              }
              let reconstructed = reconstructedRuns[assignment.runIndex]
              let localPaintBounds = try localGlyphBounds(
                font: font,
                glyph: glyph,
                fragmentOriginX: fragmentOriginX,
                ascent: fragments[fragmentIndex].positioned.metrics.ascent
              )
              entries[fragmentIndex].append(
                try InlineTextPaintEntry(
                  coreTextRun: reconstructed.run,
                  coreTextGlyphIndex: assignment.glyphIndex,
                  sourceRange: glyph.sourceRange,
                  localPaintBounds: localPaintBounds,
                  fragmentOriginX: fragmentOriginX,
                  ascent: fragments[fragmentIndex].positioned.metrics.ascent
                ))
            }
          }
        }

        for (fragmentIndex, fragment) in fragments.enumerated() {
          let fragmentRange = fragment.sourceRange
          for unitIndex in InlineSourceRangeSearch.overlappingIndices(
            in: semanticRanges, with: fragmentRange)
          {
            let (unitID, sourceRange, stroke) = semanticUnits[unitIndex]
            let entry = try makeSemanticStrokeEntry(
              unitID: unitID,
              sourceRange: sourceRange,
              stroke: stroke,
              prepared: group.prepared,
              advancePrefixes: advancePrefixes,
              positioned: fragment.positioned,
              fragmentRange: fragmentRange
            )
            entries[fragmentIndex].append(entry)
          }
        }

        if case .handwriting = group.prepared.atom.style.revealMode {
          // Native text keeps the order in which Core Text exposed runs and
          // glyphs. Handwriting is different: semantic strokes and native
          // atomic entries are one prepared sequence, so order by that
          // sequence rather than by source range (multiple strokes can share
          // one grapheme range).
          var writingUnitOrder: [InlineRevealUnitID: Int] = [:]
          var sourceRangeOrder: [InlineSourceRange: Int] = [:]
          for (unitIndex, unit) in group.prepared.writingUnits.enumerated() {
            writingUnitOrder[unit.id] = unitIndex
            sourceRangeOrder[unit.sourceRange] = min(
              sourceRangeOrder[unit.sourceRange] ?? unitIndex, unitIndex)
          }
          for index in entries.indices {
            entries[index] = entries[index].enumerated().sorted {
              let lhs = $0.element
              let rhs = $1.element
              let lhsOrder =
                lhs.writingUnitID.flatMap { writingUnitOrder[$0] }
                ?? sourceRangeOrder[lhs.sourceRange]
                ?? Int.max
              let rhsOrder =
                rhs.writingUnitID.flatMap { writingUnitOrder[$0] }
                ?? sourceRangeOrder[rhs.sourceRange]
                ?? Int.max
              return lhsOrder == rhsOrder ? $0.offset < $1.offset : lhsOrder < rhsOrder
            }.map(\.element)
          }
        }

        for (index, fragment) in fragments.enumerated() {
          result[fragment.positioned] = entries[index]
        }
      }
    #else
      if geometry.contains(where: { item in
        if case .text = item { return true }
        return false
      }) {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text is unavailable for text paint compilation")
      }
    #endif
    return result
  }
}

#if canImport(CoreText)
  private struct TextFragment {
    let positioned: PositionedInlineAtom
    let sourceRange: InlineSourceRange
    let geometryOrder: Int
  }

  private struct TextGeometryGroup {
    let prepared: PreparedInlineText
    var fragments: [TextFragment]
  }

  private struct GlyphAssignment {
    let glyph: InlineGlyph
    let runIndex: Int
    let glyphIndex: Int
    let firstFragment: Int
    let endFragment: Int
  }

  private struct ReconstructedRun {
    let run: CTRun
    let glyphs: [CGGlyph]
  }

  private func resolvedFont(for descriptor: FontDescriptor) throws -> CTFont {
    let font = CTFontCreateWithName(
      descriptor.postScriptName as CFString,
      descriptor.pointSize,
      nil)
    guard let resolvedName = CTFontCopyPostScriptName(font) as String?,
      resolvedName == descriptor.postScriptName,
      abs(CTFontGetSize(font) - descriptor.pointSize) <= 1.0 / 4096.0
    else {
      throw InlineLayoutError.unsupportedShaping(
        "font '\(descriptor.postScriptName)' was not resolved")
    }
    return font
  }

  private func firstTextFragment(
    in fragments: [TextFragment],
    overlapping glyphRange: InlineSourceRange
  ) -> Int {
    var lowerBound = 0
    var upperBound = fragments.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if fragments[middle].sourceRange.endUTF16 <= glyphRange.startUTF16 {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return lowerBound
  }

  private func reconstructRuns(
    for prepared: PreparedInlineText
  ) throws -> [ReconstructedRun] {
    let style = prepared.atom.style
    let font = try resolvedFont(for: style.font)
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
    ]
    if let locale = style.font.localeIdentifier, !locale.isEmpty {
      attributes[NSAttributedString.Key(rawValue: kCTLanguageAttributeName as String)] = locale
    }
    if style.tracking != 0 {
      attributes[NSAttributedString.Key(rawValue: kCTKernAttributeName as String)] = style.tracking
    }
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: prepared.atom.text, attributes: attributes))
    let actualRuns = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).filter {
      CTRunGetGlyphCount($0) > 0
    }
    guard actualRuns.count == prepared.shaped.runs.count else {
      throw InlineLayoutError.unsupportedShaping(
        "Core Text run count differs from prepared text")
    }

    var reconstructed: [ReconstructedRun] = []
    reconstructed.reserveCapacity(actualRuns.count)
    for (actual, expected) in zip(actualRuns, prepared.shaped.runs) {
      let count = CTRunGetGlyphCount(actual)
      guard count == expected.glyphs.count else {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text glyph count differs from prepared run")
      }
      let runAttributes = CTRunGetAttributes(actual) as NSDictionary
      guard let rawFont = runAttributes[kCTFontAttributeName] else {
        throw InlineLayoutError.unsupportedShaping("Core Text run has no resolved font")
      }
      let rawFontObject = rawFont as AnyObject
      let runFontRef = rawFontObject as CFTypeRef
      guard CFGetTypeID(runFontRef) == CTFontGetTypeID() else {
        throw InlineLayoutError.unsupportedShaping("Core Text run has no resolved font")
      }
      let runFont = unsafeDowncast(rawFontObject, to: CTFont.self)
      guard let runFontName = CTFontCopyPostScriptName(runFont) as String?,
        runFontName == expected.font.postScriptName,
        abs(CTFontGetSize(runFont) - expected.font.pointSize) <= 1.0 / 4096.0
      else {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text run font differs from prepared text")
      }

      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      CTRunGetGlyphs(actual, CFRange(location: 0, length: count), &glyphs)
      CTRunGetPositions(actual, CFRange(location: 0, length: count), &positions)
      CTRunGetStringIndices(actual, CFRange(location: 0, length: count), &indices)
      CTRunGetAdvances(actual, CFRange(location: 0, length: count), &advances)

      let actualStringRange = CTRunGetStringRange(actual)
      let actualStart = prepared.sourceRange.startUTF16 + actualStringRange.location
      let actualEnd = actualStart + actualStringRange.length
      guard actualStart == expected.sourceRange.startUTF16,
        actualEnd == expected.sourceRange.endUTF16
      else {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text run source range differs from prepared text")
      }
      let actualAdvance = Double(
        CTRunGetTypographicBounds(actual, CFRange(location: 0, length: count), nil, nil, nil))
      guard abs(actualAdvance - expected.advance) <= 1.0 / 4096.0 else {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text run advance differs from prepared text")
      }
      var summedGlyphAdvance = 0.0
      for advance in advances {
        guard advance.width.isFinite, advance.width >= 0,
          advance.height.isFinite
        else {
          throw InlineLayoutError.unsupportedShaping(
            "Core Text glyph advance is not finite")
        }
        let next = summedGlyphAdvance + Double(advance.width)
        guard next.isFinite else {
          throw InlineLayoutError.unsupportedShaping(
            "Core Text glyph advance overflowed")
        }
        summedGlyphAdvance = next
      }
      guard abs(summedGlyphAdvance - expected.advance) <= 1.0 / 4096.0 else {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text glyph advances differ from prepared text")
      }
      guard abs(Double(CTFontGetAscent(runFont)) - expected.ascent) <= 1.0 / 4096.0,
        abs(Double(CTFontGetDescent(runFont)) - expected.descent) <= 1.0 / 4096.0
      else {
        throw InlineLayoutError.unsupportedShaping(
          "Core Text run metrics differ from prepared text")
      }

      for glyphIndex in 0..<count {
        let expectedGlyph = expected.glyphs[glyphIndex]
        let expectedIndex = expectedGlyph.sourceUTF16Index - prepared.sourceRange.startUTF16
        guard UInt16(glyphs[glyphIndex]) == expectedGlyph.glyphID,
          Int(indices[glyphIndex]) == expectedIndex,
          abs(Double(positions[glyphIndex].x) - expectedGlyph.positionX) <= 1.0 / 4096.0,
          abs(Double(positions[glyphIndex].y) - expectedGlyph.positionY) <= 1.0 / 4096.0
        else {
          throw InlineLayoutError.unsupportedShaping(
            "Core Text glyph order, source index, position, or advance differs from prepared text")
        }
      }
      reconstructed.append(ReconstructedRun(run: actual, glyphs: glyphs))
    }
    return reconstructed
  }

  private func localGlyphBounds(
    font: CTFont,
    glyph: InlineGlyph,
    fragmentOriginX: Double,
    ascent: Double
  ) throws -> CGRect {
    var cgGlyph = CGGlyph(glyph.glyphID)
    var sourceBounds = CTFontGetBoundingRectsForGlyphs(
      font,
      .default,
      &cgGlyph,
      nil,
      1
    )
    sourceBounds.origin.x += CGFloat(glyph.positionX)
    sourceBounds.origin.y += CGFloat(glyph.positionY)
    guard sourceBounds.minX.isFinite, sourceBounds.minY.isFinite,
      sourceBounds.width.isFinite, sourceBounds.width > 0,
      sourceBounds.height.isFinite, sourceBounds.height > 0,
      sourceBounds.maxX.isFinite, sourceBounds.maxY.isFinite
    else {
      throw InlineLayoutError.unsupportedShaping("color glyph has empty paint bounds")
    }
    let local = CGRect(
      x: sourceBounds.minX - CGFloat(fragmentOriginX),
      y: CGFloat(ascent) - sourceBounds.maxY,
      width: sourceBounds.width,
      height: sourceBounds.height
    )
    guard local.minX.isFinite, local.minY.isFinite,
      local.width.isFinite, local.width > 0,
      local.height.isFinite, local.height > 0,
      local.maxX.isFinite, local.maxY.isFinite
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    return local
  }

  private func isNonRenderingGlyph(
    _ glyph: InlineGlyph,
    in prepared: PreparedInlineText
  ) -> Bool {
    let base = prepared.sourceRange.startUTF16
    let start = glyph.sourceRange.startUTF16 - base
    let end = glyph.sourceRange.endUTF16 - base
    guard start >= 0, end > start, end <= prepared.atom.text.utf16.count else { return false }
    let fragment = (prepared.atom.text as NSString).substring(
      with: NSRange(location: start, length: end - start))
    return !fragment.isEmpty
      && fragment.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
  }
#endif
