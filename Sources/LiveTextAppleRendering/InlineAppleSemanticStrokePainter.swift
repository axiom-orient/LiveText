import LiveTextLayout
import LiveTextEffects
import SwiftUI

/// One scalar point in a revealed semantic brush centerline.
package struct InlineAppleSemanticBrushPoint: Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// One deterministic dry-brush streak emitted from a semantic stroke.
package struct InlineAppleSemanticBrushStreak: Hashable, Sendable {
  public let start: InlineAppleSemanticBrushPoint
  public let end: InlineAppleSemanticBrushPoint
  public let width: Double
  public let opacity: Double
  public let phase: Double

  public init(
    start: InlineAppleSemanticBrushPoint,
    end: InlineAppleSemanticBrushPoint,
    width: Double,
    opacity: Double,
    phase: Double
  ) {
    self.start = start
    self.end = end
    self.width = width
    self.opacity = opacity
    self.phase = phase
  }
}

/// The complete deterministic brush recipe for one semantic unit at one
/// reveal sample. It contains no random generator or mutable frame state.
/// `coverage` controls pigment opacity; `streakScale` controls the number,
/// length, and width of streaks; `seed` controls their stable placement and
/// phase through the configuration supplied to `makeBrushRecipe`.
package struct InlineAppleSemanticBrushRecipe: Hashable, Sendable {
  public let progress: Double
  public let pigmentOpacity: Double
  public let bodyWidth: Double
  public let dabRadius: Double
  public let centerline: [InlineAppleSemanticBrushPoint]
  public let streaks: [InlineAppleSemanticBrushStreak]
  public let phase: Double

  public var isDab: Bool { centerline.count == 1 }

  public init(
    progress: Double,
    pigmentOpacity: Double,
    bodyWidth: Double,
    dabRadius: Double,
    centerline: [InlineAppleSemanticBrushPoint],
    streaks: [InlineAppleSemanticBrushStreak],
    phase: Double
  ) {
    self.progress = progress
    self.pigmentOpacity = pigmentOpacity
    self.bodyWidth = bodyWidth
    self.dabRadius = dabRadius
    self.centerline = centerline
    self.streaks = streaks
    self.phase = phase
  }
}

/// Shared frame-time paint operations for prepared handwriting strokes.
/// Preparation and compilation provide immutable paths and unit identities;
/// this helper only samples activation and paints the resulting geometry.
@MainActor
package enum InlineAppleSemanticStrokePainter {
  public static func visibleEntries(
    _ entries: [InlineTextPaintEntry],
    activation: InlineRenderRevealTextActivation?,
    time: Double
  ) -> [InlineTextPaintEntry] {
    entries.filter { entry in
      switch entry.kind {
      case .semanticStroke:
        guard let activation else { return true }
        guard let unitID = entry.writingUnitID else { return false }
        return activation.progress(at: time, unitID: unitID) > 0
      case .outline, .coreText:
        guard let activation else { return true }
        return activation.progress(at: time, sourceRange: entry.sourceRange) > 0
      }
    }
  }

  public static func maskPath(
    _ entries: [InlineTextPaintEntry],
    activation: InlineRenderRevealTextActivation? = nil,
    time: Double = 0
  ) -> Path {
    var result = Path()
    for entry in entries {
      guard let path = paintedPath(entry, activation: activation, time: time) else { continue }
      if entry.kind == .semanticStroke {
        // A semantic dab already is its complete visible disk. Stroking it
        // would expand the disk by another half-width and turn the mask into
        // a ring. Multi-point strokes are centerlines and need one stroke to
        // become their visible paint geometry.
        if entry.semanticStrokePoints.count == 1 {
          result.addPath(path)
        } else {
          result.addPath(path.strokedPath(StrokeStyle(
            lineWidth: entry.semanticStrokeWidth, lineCap: .round, lineJoin: .round)))
        }
      } else {
        result.addPath(path)
      }
    }
    return result
  }

  public static func draw(
    _ entries: [InlineTextPaintEntry],
    color: Color,
    activation: InlineRenderRevealTextActivation? = nil,
    time: Double = 0,
    in context: inout GraphicsContext
  ) {
    for entry in entries where entry.kind == .semanticStroke {
      guard let path = paintedPath(entry, activation: activation, time: time) else { continue }
      if entry.semanticStrokePoints.count == 1 {
        // The single point is a filled brush dab, not an ellipse centerline.
        // Keep the same path that maskPath returns so direct and masked paint
        // have identical geometry.
        context.fill(path, with: .color(color))
      } else {
        context.stroke(
          path,
          with: .color(color),
          style: StrokeStyle(
            lineWidth: entry.semanticStrokeWidth, lineCap: .round, lineJoin: .round))
      }
    }
  }

  /// Builds the brush surface for one semantic stroke. All geometry and
  /// pigment values are pure functions of the prepared entry, activation
  /// sample, and validated brush configuration; this method never mutates
  /// state or consults a frame-time random source.
  package static func makeBrushRecipe(
    _ entry: InlineTextPaintEntry,
    configuration: WritingBrushConfiguration,
    activation: InlineRenderRevealTextActivation? = nil,
    time: Double = 0
  ) -> InlineAppleSemanticBrushRecipe? {
    guard entry.kind == .semanticStroke,
      let points = visiblePoints(entry.semanticStrokePoints, activation: activation,
                                 time: time, unitID: entry.writingUnitID)
    else { return nil }
    let progress = semanticProgress(
      entry, activation: activation, time: time)
    guard progress > 0 else { return nil }

    let width = max(0.01, Double(entry.semanticStrokeWidth))
    let pigmentOpacity = clamped(
      configuration.coverage * (0.70 + 0.30 * progress))
    let phase = fraction(
      seed: configuration.seed,
      unit: entry.writingUnitID?.rawValue
        ?? "(entry.sourceRange.startUTF16):(entry.sourceRange.endUTF16)",
      index: -1)
    let centerline = points.map {
      InlineAppleSemanticBrushPoint(x: Double($0.x), y: Double($0.y))
    }
    let radius = width * 0.5 * sqrt(progress)
    guard points.count > 1 else {
      return InlineAppleSemanticBrushRecipe(
        progress: progress,
        pigmentOpacity: pigmentOpacity,
        bodyWidth: width,
        dabRadius: radius,
        centerline: centerline,
        streaks: [],
        phase: phase)
    }

    let scale = min(8, max(0.25, configuration.streakScale))
    let streakCount = max(2, min(12, Int(ceil(scale))))
    var streaks: [InlineAppleSemanticBrushStreak] = []
    streaks.reserveCapacity(streakCount)
    let segmentCount = points.count - 1
    for index in 0..<streakCount {
      let segmentIndex = Int(seedValue(
        seed: configuration.seed, unit: entry.writingUnitID?.rawValue ?? "",
        index: index ^ 0x51) % UInt64(segmentCount))
      let start = points[segmentIndex]
      let end = points[segmentIndex + 1]
      let dx = end.x - start.x
      let dy = end.y - start.y
      let length = max(0.0001, hypot(dx, dy))
      let directionX = dx / length
      let directionY = dy / length
      let normalX = -directionY
      let normalY = directionX
      let placement = fraction(
        seed: configuration.seed,
        unit: entry.writingUnitID?.rawValue ?? "",
        index: index)
      let lengthFraction = min(1, 0.45 + scale * 0.055 + placement * 0.22)
      let lateral = (fraction(
        seed: configuration.seed,
        unit: entry.writingUnitID?.rawValue ?? "",
        index: index ^ 0xA7) - 0.5) * width * (0.42 + scale * 0.055)
      let offsetStart = -length * (1 - lengthFraction) * placement * 0.25
      let streakStart = CGPoint(
        x: start.x + directionX * offsetStart + normalX * lateral,
        y: start.y + directionY * offsetStart + normalY * lateral)
      let streakLength = length * lengthFraction
      let streakEnd = CGPoint(
        x: streakStart.x + directionX * streakLength,
        y: streakStart.y + directionY * streakLength)
      let streakWidth = max(0.16, width * (0.035 + scale * 0.010)
        * (0.70 + placement * 0.45))
      let streakOpacity = clamped(
        configuration.coverage * (0.24 + placement * 0.46) * (0.75 + progress * 0.25))
      streaks.append(InlineAppleSemanticBrushStreak(
        start: InlineAppleSemanticBrushPoint(x: Double(streakStart.x), y: Double(streakStart.y)),
        end: InlineAppleSemanticBrushPoint(x: Double(streakEnd.x), y: Double(streakEnd.y)),
        width: streakWidth,
        opacity: streakOpacity,
        phase: fraction(
          seed: configuration.seed ^ 0xB5,
          unit: entry.writingUnitID?.rawValue ?? "",
          index: index)))
    }
    return InlineAppleSemanticBrushRecipe(
      progress: progress,
      pigmentOpacity: pigmentOpacity,
      bodyWidth: width,
      dabRadius: radius,
      centerline: centerline,
      streaks: streaks,
      phase: phase)
  }

  /// Paints semantic entries using the shared brush recipe. Ordinary outline
  /// and Core Text entries are deliberately excluded; their existing native
  /// paths remain owned by the caller.
  package static func drawBrush(
    _ entries: [InlineTextPaintEntry],
    configuration: WritingBrushConfiguration,
    activation: InlineRenderRevealTextActivation? = nil,
    time: Double = 0,
    color: Color,
    in context: inout GraphicsContext
  ) {
    for entry in entries where entry.kind == .semanticStroke {
      guard let recipe = makeBrushRecipe(
        entry, configuration: configuration, activation: activation, time: time)
      else { continue }
      let pigment = color.opacity(recipe.pigmentOpacity)
      if recipe.isDab {
        guard let point = recipe.centerline.first else { continue }
        let radius = CGFloat(recipe.dabRadius)
        context.fill(
          Path(ellipseIn: CGRect(
            x: CGFloat(point.x) - radius,
            y: CGFloat(point.y) - radius,
            width: radius * 2,
            height: radius * 2)),
          with: .color(pigment))
      } else if let path = centerlinePath(recipe.centerline) {
        context.stroke(
          path,
          with: .color(pigment),
          style: StrokeStyle(
            lineWidth: CGFloat(recipe.bodyWidth), lineCap: .round, lineJoin: .round))
      }
      for streak in recipe.streaks {
        var path = Path()
        path.move(to: CGPoint(x: streak.start.x, y: streak.start.y))
        path.addLine(to: CGPoint(x: streak.end.x, y: streak.end.y))
        context.stroke(
          path,
          with: .color(color.opacity(streak.opacity)),
          style: StrokeStyle(
            lineWidth: CGFloat(streak.width), lineCap: .butt, lineJoin: .round))
      }
    }
  }

  private static func paintedPath(
    _ entry: InlineTextPaintEntry,
    activation: InlineRenderRevealTextActivation?,
    time: Double
  ) -> Path? {
    switch entry.kind {
    case .outline:
      // Native outlines are complete glyph geometry, so reveal controls only
      // whether the glyph has started.  A zero-progress frame must not feed a
      // full outline into a material mask.
      if let activation {
        guard activation.progress(at: time, sourceRange: entry.sourceRange) > 0 else {
          return nil
        }
      }
      return entry.outlinePath
    case .coreText:
      // Core Text entries (notably color glyphs) have no outline path.  They
      // remain owned by the native CGContext draw path and never become a
      // synthetic material mask.
      return nil
    case .semanticStroke:
      break
    }
    let progress: Double
    if let activation {
      guard let unitID = entry.writingUnitID else { return nil }
      progress = activation.progress(at: time, unitID: unitID)
    } else {
      // A missing schedule is the static complete frame. The semantic entry
      // still gets its canonical dab/centerline geometry below; it must not
      // fall back to the retained source path (a one-point centerline has no
      // area).
      progress = 1
    }
    guard progress > 0 else { return nil }
    let points = entry.semanticStrokePoints
    guard points.count > 1 else {
      guard let point = points.first else { return nil }
      // A one-point stroke is represented by a round brush dab.  Growing the
      // radius with the square root of progress keeps the covered disk area
      // proportional to reveal progress while retaining a strict partial
      // frame.  Returning the full dab for every progress greater than zero
      // made a semantic unit jump from invisible to complete.
      let fullRadius = entry.semanticStrokeWidth * 0.5
      let radius = fullRadius * CGFloat(sqrt(progress))
      return Path(ellipseIn: CGRect(
        x: point.x - radius,
        y: point.y - radius,
        width: radius * 2,
        height: radius * 2))
    }
    let scaled = progress * Double(points.count - 1)
    let completed = min(points.count - 1, Int(scaled.rounded(.down)))
    let local = min(1, max(0, scaled - Double(completed)))
    var result = Path()
    result.move(to: points[0])
    if completed > 0 {
      for point in points[1...completed] { result.addLine(to: point) }
    }
    if completed < points.count - 1 {
      let start = points[completed]
      let end = points[completed + 1]
      result.addLine(to: CGPoint(
        x: start.x + (end.x - start.x) * CGFloat(local),
        y: start.y + (end.y - start.y) * CGFloat(local)))
    }
    return result
  }

  private static func semanticProgress(
    _ entry: InlineTextPaintEntry,
    activation: InlineRenderRevealTextActivation?,
    time: Double
  ) -> Double {
    guard let activation else { return 1 }
    guard let unitID = entry.writingUnitID else { return 0 }
    return activation.progress(at: time, unitID: unitID)
  }

  private static func visiblePoints(
    _ points: [CGPoint],
    activation: InlineRenderRevealTextActivation?,
    time: Double,
    unitID: InlineRevealUnitID?
  ) -> [CGPoint]? {
    guard !points.isEmpty else { return nil }
    let progress: Double
    if let activation {
      guard let unitID else { return nil }
      progress = activation.progress(at: time, unitID: unitID)
    } else {
      progress = 1
    }
    guard progress > 0 else { return nil }
    guard points.count > 1 else { return [points[0]] }
    let scaled = min(1, progress) * Double(points.count - 1)
    let completed = min(points.count - 1, Int(scaled.rounded(.down)))
    let local = min(1, max(0, scaled - Double(completed)))
    var result = Array(points.prefix(completed + 1))
    guard completed < points.count - 1 else { return result }
    guard local > 0 else { return result }
    let start = points[completed]
    let end = points[completed + 1]
    result.append(CGPoint(
      x: start.x + (end.x - start.x) * CGFloat(local),
      y: start.y + (end.y - start.y) * CGFloat(local)))
    return result
  }

  private static func centerlinePath(
    _ points: [InlineAppleSemanticBrushPoint]
  ) -> Path? {
    guard points.count > 1, let first = points.first else { return nil }
    var path = Path()
    path.move(to: CGPoint(x: first.x, y: first.y))
    for point in points.dropFirst() {
      path.addLine(to: CGPoint(x: point.x, y: point.y))
    }
    return path
  }

  private static func clamped(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
  }

  private static func fraction(seed: UInt64, unit: String, index: Int) -> Double {
    let value = seedValue(seed: seed, unit: unit, index: index)
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }

  /// SplitMix-style arithmetic is used only as a stable coordinate hash. It
  /// is not a mutable random source and therefore produces the same recipe
  /// for the same semantic unit on every adapter and every frame.
  private static func seedValue(seed: UInt64, unit: String, index: Int) -> UInt64 {
    var value = seed ^ 0x9E37_79B9_7F4A_7C15
    for byte in unit.utf8 {
      value ^= UInt64(byte)
      value &*= 0x100_0000_01B3
    }
    value ^= UInt64(bitPattern: Int64(index)) &* 0xBF58_476D_1CE4_E5B9
    value ^= value >> 30
    value &*= 0xBF58_476D_1CE4_E5B9
    value ^= value >> 27
    value &*= 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
