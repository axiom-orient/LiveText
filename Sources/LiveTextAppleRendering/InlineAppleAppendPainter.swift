import CoreGraphics
import LiveTextEffects
public import LiveTextLayout
import SwiftUI

/// The renderer-neutral vector mask selected for one append frame.
///
/// Coverage remains the visible SVG geometry. A partial frame adds a
/// trajectory clip in front of that coverage; the trajectory itself is never
/// painted as the visible object.
@MainActor
package enum InlineAppleAppendVectorMaskPlan {
  case empty
  case completeCoverage(path: Path, paint: InlineSVGCoveragePaint)
  case partialCoverage(
    path: Path,
    paint: InlineSVGCoveragePaint,
    trajectory: Path,
    trajectoryStyle: InlineSVGStrokeStyle
  )

  public var isEmpty: Bool {
    if case .empty = self { return true }
    return false
  }

  public var isComplete: Bool {
    if case .completeCoverage = self { return true }
    return false
  }

  /// The final visible geometry, independent of the progress mask.
  public var coverage: Path? {
    switch self {
    case .empty: return nil
    case .completeCoverage(let path, _), .partialCoverage(let path, _, _, _): return path
    }
  }

  public var coveragePaint: InlineSVGCoveragePaint? {
    switch self {
    case .empty: return nil
    case .completeCoverage(_, let paint), .partialCoverage(_, let paint, _, _): return paint
    }
  }
}

/// A deterministic append vector paint plan. Both Apple adapters consume the
/// same plan and therefore cannot accidentally swap the fill and trajectory
/// roles.
@MainActor
package struct InlineAppleAppendVectorPaintPlan {
  public let mask: InlineAppleAppendVectorMaskPlan
  public let progress: Double

  public var isEmpty: Bool { mask.isEmpty }
  public var isComplete: Bool { mask.isComplete }
}

/// The one frame-time drawing boundary for both incremental Apple adapters.
/// It consumes immutable chunks prepared by `InlineAppleAppendSession`; it
/// never changes the session, resolves assets, or rebuilds a static plan.
@MainActor
package enum InlineAppleAppendPainter {
  public static func vectorPaintPlan(
    coverage: Path,
    coveragePaint: InlineSVGCoveragePaint,
    trajectoryCommands: [Int: InlineAppleVectorRevealCommand],
    trajectoryStyle: InlineSVGStrokeStyle,
    activation: InlineRenderRevealVectorActivation,
    totalDuration: Double,
    phase: InlineRenderRevealPhase
  ) -> InlineAppleAppendVectorPaintPlan {
    guard totalDuration.isFinite, totalDuration >= 0 else {
      preconditionFailure("validated append reveal duration is not finite")
    }
    let time = totalDuration * phase.rawValue
    let progress = vectorProgress(activation: activation, time: time)
    guard progress > 0 else {
      return InlineAppleAppendVectorPaintPlan(mask: .empty, progress: 0)
    }
    let reveal = InlineAppleRenderContent.makeVectorRevealPath(
      commands: trajectoryCommands, activation: activation, time: time)
    if reveal.isComplete {
      return InlineAppleAppendVectorPaintPlan(
        mask: .completeCoverage(path: coverage, paint: coveragePaint), progress: 1)
    }
    let visibleTrajectory = reveal.path
    guard !visibleTrajectory.isEmpty else {
      return InlineAppleAppendVectorPaintPlan(mask: .empty, progress: progress)
    }
    return InlineAppleAppendVectorPaintPlan(
      mask: .partialCoverage(
        path: coverage,
        paint: coveragePaint,
        trajectory: visibleTrajectory,
        trajectoryStyle: trajectoryStyle),
      progress: progress)
  }

  public static func materialResources(
    for material: InlineRendererMaterial
  ) throws -> InlineAppleAppendMaterialResources {
    switch material {
    case .none, .brush:
      return InlineAppleAppendMaterialResources()
    case .chalk:
      // Chalk resources are package-owned and cached by LiveTextChalkRendering.
      // Append publication no longer decodes a second texture copy.
      return InlineAppleAppendMaterialResources()
    case .coloredPencil, .pen, .ink, .marker, .knockout:
      throw InlineLayoutError.unsupportedShaping(
        "append renderer material is not supported by the shared painter")
    }
  }

  public static func draw(
    chunk: InlineAppleAppendChunk,
    reveal: InlineAppleAppendChunkReveal,
    totalDuration: Double,
    phase: InlineRenderRevealPhase,
    material: InlineRendererMaterial,
    resources: InlineAppleAppendMaterialResources,
    color: Color,
    materialSegments: [InlineWritingMaterialSegment]? = nil,
    effects: InlineAppleAppendEffectsPlan? = nil,
    in context: inout GraphicsContext
  ) {
    guard totalDuration.isFinite, totalDuration >= 0 else {
      preconditionFailure("validated append reveal duration is not finite")
    }
    guard effects?.shouldRenderArtwork(for: chunk) ?? true else { return }
    let masks = effects?.masks(for: chunk) ?? []
    if masks.isEmpty {
      drawUnmasked(
        chunk: chunk, reveal: reveal, totalDuration: totalDuration, phase: phase,
        material: material, resources: resources, color: color,
        materialSegments: materialSegments, in: &context)
      return
    }
    // Composition is target-local. Keeping reveal clips and destination-out
    // erasing in a transparency layer prevents one chunk's mask from
    // modifying the highlight or a neighboring append chunk.
    context.drawLayer { layer in
      InlineAppleCompositionPainter.applyRevealMasks(masks, in: &layer)
      drawUnmasked(
        chunk: chunk, reveal: reveal, totalDuration: totalDuration, phase: phase,
        material: material, resources: resources, color: color,
        materialSegments: materialSegments, in: &layer)
      InlineAppleCompositionPainter.applyEraseMasks(masks, in: &layer)
    }
  }

  private static func drawUnmasked(
    chunk: InlineAppleAppendChunk,
    reveal: InlineAppleAppendChunkReveal,
    totalDuration: Double,
    phase: InlineRenderRevealPhase,
    material: InlineRendererMaterial,
    resources: InlineAppleAppendMaterialResources,
    color: Color,
    materialSegments: [InlineWritingMaterialSegment]?,
    in context: inout GraphicsContext
  ) {
    let time = totalDuration * phase.rawValue
    switch chunk {
    case .text(_, let positioned, let entries):
      guard case .text(let activation) = reveal else {
        preconditionFailure("append text reveal payload does not match chunk")
      }
      drawText(
        entries: entries, positioned: positioned, activation: activation,
        time: time, material: material, resources: resources, color: color,
        chunkID: chunk.id, in: &context)
    case .vector(_, let positioned, let coverage, let coveragePaint, _):
      guard case .vector(let trajectoryCommands, let trajectoryStyle, let activation) = reveal
      else {
        preconditionFailure("append vector reveal payload does not match chunk")
      }
      drawVector(
        coverage: coverage, coveragePaint: coveragePaint,
        trajectoryCommands: trajectoryCommands, trajectoryStyle: trajectoryStyle,
        positioned: positioned, activation: activation,
        totalDuration: totalDuration, phase: phase,
        material: material, resources: resources, color: color,
        chunkID: chunk.id, materialSegments: materialSegments, in: &context)
    case .image(_, _, let paint, _, _):
      guard case .image(let activation) = reveal else {
        preconditionFailure("append image reveal payload does not match chunk")
      }
      guard activation.progress(at: time) > 0 else { return }
      paint.draw(in: &context)
    }
  }

  /// Draws one highlight behind append content in viewport coordinates.
  /// Both append adapters call this same implementation so style geometry and
  /// alpha cannot drift between SwiftUI and Canvas.
  package static func drawHighlight(
    _ plan: InlineHighlightPlan,
    viewport: InlineRenderViewport,
    in context: inout GraphicsContext
  ) {
    for fragment in plan.fragments {
      let rect = fragment.rect
      let local = CGRect(
        x: CGFloat(rect.minX - viewport.x),
        y: CGFloat(rect.minY - viewport.y),
        width: CGFloat(rect.width),
        height: CGFloat(rect.height))
      switch plan.style {
      case .highlighter(let color, let opacity, let cornerRadius):
        context.fill(
          Path(roundedRect: local, cornerRadius: CGFloat(cornerRadius)),
          with: .color(
            Color(
              .sRGB, red: color.red, green: color.green,
              blue: color.blue, opacity: color.alpha
            ).opacity(opacity)))
      case .underline(let color, let thickness, let offset):
        var path = Path()
        let y = local.maxY + CGFloat(offset) + CGFloat(thickness) / 2
        path.move(to: CGPoint(x: local.minX, y: y))
        path.addLine(to: CGPoint(x: local.maxX, y: y))
        context.stroke(
          path,
          with: .color(
            Color(
              .sRGB, red: color.red, green: color.green,
              blue: color.blue, opacity: color.alpha)),
          lineWidth: CGFloat(thickness))
      case .outline(let color, let thickness):
        context.stroke(
          Path(roundedRect: local, cornerRadius: 1),
          with: .color(
            Color(
              .sRGB, red: color.red, green: color.green,
              blue: color.blue, opacity: color.alpha)),
          lineWidth: CGFloat(thickness))
      }
    }
  }

  private static func drawText(
    entries: [InlineTextPaintEntry],
    positioned: PositionedInlineAtom,
    activation: InlineRenderRevealTextActivation,
    time: Double,
    material: InlineRendererMaterial,
    resources: InlineAppleAppendMaterialResources,
    color: Color,
    chunkID: String,
    in context: inout GraphicsContext
  ) {
    let visible = InlineAppleSemanticStrokePainter.visibleEntries(
      entries, activation: activation, time: time)
    guard !visible.isEmpty else { return }
    // Semantic entries retain a centerline in `outlinePath` only as their
    // prepared source geometry. They must be painted by the shared semantic
    // painter so reveal progress and dab/centerline geometry are applied once.
    let outlines: [Path] = visible.compactMap { entry -> Path? in
      guard entry.kind == .outline else { return nil }
      return entry.outlinePath
    }
    switch material {
    case .none:
      fillText(
        outlines: outlines, entries: visible, activation: activation, time: time,
        color: color, in: &context)
    case .brush(let configuration):
      drawBrushText(
        outlines: outlines, entries: visible, configuration: configuration,
        activation: activation, time: time, color: color, in: &context)
    case .chalk(let configuration):
      let mask = InlineAppleSemanticStrokePainter.maskPath(
        visible, activation: activation, time: time)
      guard !mask.isEmpty else { return }
      let target = makeTarget(
        id: chunkID, positioned: positioned, bounds: mask.boundingRect)
      InlineWritingChalkPainter.paint(
        mask: mask,
        target: target,
        configuration: configuration,
        color: color,
        documentOriginAtContextZero: documentOrigin(for: positioned),
        in: &context)
      drawCoreText(entries: visible, in: &context)
    case .coloredPencil, .pen, .ink, .marker, .knockout:
      preconditionFailure("unsupported append material reached the painter")
    }
  }

  private static func fillText(
    outlines: [Path],
    entries: [InlineTextPaintEntry],
    activation: InlineRenderRevealTextActivation,
    time: Double,
    color: Color,
    in context: inout GraphicsContext
  ) {
    for path in outlines { context.fill(path, with: .color(color)) }
    InlineAppleSemanticStrokePainter.draw(
      entries, color: color, activation: activation, time: time, in: &context)
    drawCoreText(entries: entries, in: &context)
  }

  private static func drawBrushText(
    outlines: [Path],
    entries: [InlineTextPaintEntry],
    configuration: WritingBrushConfiguration,
    activation: InlineRenderRevealTextActivation,
    time: Double,
    color: Color,
    in context: inout GraphicsContext
  ) {
    guard !outlines.isEmpty || entries.contains(where: { $0.kind == .semanticStroke }) else {
      drawCoreText(entries: entries, in: &context)
      return
    }
    for path in outlines {
      context.fill(path, with: .color(color.opacity(max(0.2, configuration.coverage))))
      context.stroke(
        path,
        with: .color(color.opacity(configuration.coverage)),
        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }
    InlineAppleSemanticStrokePainter.drawBrush(
      entries, configuration: configuration,
      activation: activation, time: time, color: color, in: &context)
    drawCoreText(entries: entries, in: &context)
  }

  private static func drawCoreText(
    entries: [InlineTextPaintEntry], in context: inout GraphicsContext
  ) {
    for entry in entries where entry.kind == .coreText {
      entry.draw(in: &context)
    }
  }

  private static func drawVector(
    coverage: Path,
    coveragePaint: InlineSVGCoveragePaint,
    trajectoryCommands: [Int: InlineAppleVectorRevealCommand],
    trajectoryStyle: InlineSVGStrokeStyle,
    positioned: PositionedInlineAtom,
    activation: InlineRenderRevealVectorActivation,
    totalDuration: Double,
    phase: InlineRenderRevealPhase,
    material: InlineRendererMaterial,
    resources: InlineAppleAppendMaterialResources,
    color: Color,
    chunkID: String,
    materialSegments: [InlineWritingMaterialSegment]?,
    in context: inout GraphicsContext
  ) {
    let time = totalDuration * phase.rawValue
    let plan = vectorPaintPlan(
      coverage: coverage,
      coveragePaint: coveragePaint,
      trajectoryCommands: trajectoryCommands,
      trajectoryStyle: trajectoryStyle,
      activation: activation,
      totalDuration: totalDuration,
      phase: phase)
    guard !plan.isEmpty else { return }
    let ownsMaterialGeometry: Bool
    if case .brush = material {
      ownsMaterialGeometry = true
    } else {
      ownsMaterialGeometry = false
    }
    context.drawLayer { layer in
      switch plan.mask {
      case .empty:
        return
      case .completeCoverage(let path, let paint):
        if !ownsMaterialGeometry {
          clipCoverage(path, paint: paint, in: &layer)
        }
      case .partialCoverage(let path, let paint, let visibleTrajectory, let style):
        if !ownsMaterialGeometry {
          layer.clip(to: visibleTrajectory.strokedPath(strokeStyle(style)))
          clipCoverage(path, paint: paint, in: &layer)
        }
      }
      switch material {
      case .none:
        guard let path = plan.mask.coverage, let paint = plan.mask.coveragePaint else { return }
        drawCoverage(path, paint: paint, color: color, in: &layer)
      case .chalk(let configuration):
        let mask: Path
        switch plan.mask {
        case .empty:
          return
        case .completeCoverage(let path, _):
          mask = InlineAppleVectorCoveragePainter.maskPath(
            coverage: path, paint: plan.mask.coveragePaint ?? coveragePaint)
        case .partialCoverage(_, _, let visibleTrajectory, let style):
          mask = visibleTrajectory.strokedPath(strokeStyle(style))
        }
        let target = makeTarget(
          id: chunkID, positioned: positioned, bounds: coverage.boundingRect)
        InlineWritingChalkPainter.paint(
          mask: mask,
          target: target,
          configuration: configuration,
          color: color,
          documentOriginAtContextZero: documentOrigin(for: positioned),
          in: &layer)
      case .brush(let configuration):
        let brush = WritingMaterial.brush(configuration)
        let geometries = Self.visibleMaterialGeometries(
          segments: materialSegments ?? [],
          activation: activation,
          time: time,
          material: brush,
          destinationHeight: Double(max(positioned.height, 1))
        )
        Self.drawBrushGeometries(
          geometries, color: color, coverage: configuration.coverage, in: &layer)
      case .coloredPencil, .pen, .ink, .marker, .knockout:
        preconditionFailure("unsupported append material reached the painter")
      }
    }
  }

  /// Builds append brush geometry from the same immutable source-distance
  /// prefix used by static rendering. Keeping the reveal cut before geometry
  /// construction is what makes the terminal taper belong to the visible
  /// prefix instead of painting the complete path at every partial phase.
  internal static func visibleMaterialGeometries(
    segments: [InlineWritingMaterialSegment],
    activation: InlineRenderRevealVectorActivation,
    time: Double,
    material: WritingMaterial,
    destinationHeight: Double
  ) -> [WritingStrokeGeometry] {
    let visibleSegments = InlineWritingMaterialSampler.visibleSegments(
      segments, activation: activation, time: time)
    return InlineAppleWritingMaterialGeometry.make(
      segments: visibleSegments,
      material: material,
      destinationHeight: destinationHeight
    )
  }

  private static func drawBrushGeometries(
    _ geometries: [WritingStrokeGeometry],
    color: Color,
    coverage: Double,
    in context: inout GraphicsContext
  ) {
    let opacity = min(1, max(0, coverage))
    for geometry in geometries {
      let body = Self.writingGeometryPath(geometry.body)
      guard !body.isEmpty else { continue }
      context.fill(body, with: .color(color.opacity(opacity)))
      for bristle in geometry.bristles {
        context.blendMode = bristle.isErosion ? .destinationOut : .normal
        for run in bristle.runs where run.count > 1 {
          var path = Path()
          path.move(to: CGPoint(x: run[0].x, y: run[0].y))
          for point in run.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
          }
          context.stroke(
            path,
            with: .color(
              color.opacity(
                opacity * min(0.9, max(0, bristle.opacity)))),
            style: StrokeStyle(
              lineWidth: CGFloat(max(0.18, bristle.width)),
              lineCap: .butt,
              lineJoin: .round))
        }
      }
      context.blendMode = .normal
      for splat in geometry.splatters {
        let radius = max(0.35, splat.radius)
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: splat.x - radius,
              y: splat.y - radius,
              width: radius * 2,
              height: radius * 2)),
          with: .color(
            color.opacity(
              opacity * min(0.84, max(0, splat.opacity)))))
      }
    }
    context.blendMode = .normal
  }

  private static func writingGeometryPath(_ points: [WritingPlanPoint]) -> Path {
    guard let first = points.first else { return Path() }
    var path = Path()
    path.move(to: CGPoint(x: first.x, y: first.y))
    for point in points.dropFirst() {
      path.addLine(to: CGPoint(x: point.x, y: point.y))
    }
    path.closeSubpath()
    return path
  }

  fileprivate static func vectorProgress(
    activation: InlineRenderRevealVectorActivation,
    time: Double
  ) -> Double {
    guard time.isFinite, !activation.units.isEmpty else { return 0 }
    guard time >= activation.units[0].startTime else { return 0 }
    let completed = activation.completedCommandCount(at: time)
    guard completed < activation.units.count else { return 1 }
    let total = activation.units.reduce(0.0) { $0 + $1.duration }
    guard total.isFinite, total > 0 else { return 0 }
    let completedDuration = activation.units.prefix(completed).reduce(0.0) {
      $0 + $1.duration
    }
    let unit = activation.units[completed]
    let local = min(1, max(0, (time - unit.startTime) / unit.duration))
    return min(1, max(0, (completedDuration + local * unit.duration) / total))
  }

  private static func clipCoverage(
    _ coverage: Path,
    paint: InlineSVGCoveragePaint,
    in context: inout GraphicsContext
  ) {
    InlineAppleVectorCoveragePainter.clip(coverage: coverage, paint: paint, in: &context)
  }

  private static func drawCoverage(
    _ coverage: Path,
    paint: InlineSVGCoveragePaint,
    color: Color,
    in context: inout GraphicsContext
  ) {
    InlineAppleVectorCoveragePainter.draw(
      coverage: coverage, paint: paint, color: color, in: &context)
  }

  private static func strokeStyle(_ style: InlineSVGStrokeStyle) -> StrokeStyle {
    StrokeStyle(
      lineWidth: CGFloat(style.width),
      lineCap: {
        switch style.cap {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
      }(),
      lineJoin: {
        switch style.join {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
      }(),
      miterLimit: CGFloat(style.miterLimit)
    )
  }

  /// Document coordinate represented by the current context's local zero.
  /// Append adapters call the painter after translating to this atom origin;
  /// the material texture must therefore stay anchored to these coordinates.
  package static func documentOrigin(for positioned: PositionedInlineAtom) -> CGPoint {
    CGPoint(
      x: CGFloat(positioned.originX),
      y: CGFloat(
        positioned.baselineY - positioned.metrics.baselineOffset
          - positioned.metrics.ascent))
  }

  private static func makeTarget(
    id: String,
    positioned: PositionedInlineAtom,
    bounds: CGRect
  ) -> WritingMaterialTarget {
    let destination = WritingMaterialRect(
      validatedX: Double(bounds.minX), y: Double(bounds.minY),
      width: Double(max(bounds.width, 0)), height: Double(max(bounds.height, 0)))
    return WritingMaterialTarget(
      validatedTargetID: id,
      documentOriginX: positioned.originX,
      documentOriginY: Double(documentOrigin(for: positioned).y),
      destination: destination)
  }
}
