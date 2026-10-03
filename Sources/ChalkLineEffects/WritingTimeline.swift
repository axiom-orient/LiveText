import Foundation

public enum WritingTimelinePlanner {
  public static func makeTimeline(
    scene: StrokeWritingScene,
    options: WritingTimingOptions = .default
  ) throws -> WritingTimeline {
    var timings: [WritingStrokeTiming] = []
    var currentTime = 0.0
    var layerIndex = 0

    for (glyphOffset, glyph) in scene.glyphs.enumerated() {
      for (strokeIndex, stroke) in glyph.strokes.enumerated() {
        let duration = max(options.minimumStrokeDuration, stroke.length / options.pointsPerSecond)
        let start = currentTime
        let end = start + duration
        timings.append(
          try WritingStrokeTiming(
            layerIndex: layerIndex,
            glyphIndex: glyph.index,
            strokeIndex: strokeIndex,
            strokeID: stroke.id,
            startTime: start,
            endTime: end
          )
        )
        currentTime = end + options.interStrokeDelay
        layerIndex += 1
      }
      if glyphOffset + 1 < scene.glyphs.count, !glyph.strokes.isEmpty {
        currentTime += options.interGlyphDelay
      }
    }

    guard !timings.isEmpty else { throw WritingCoreError.emptyScene }
    return try WritingTimeline(
      duration: max(timings[timings.count - 1].endTime, 0.001), strokes: timings)
  }

  /// Core-only timeline input used by exact vector paths. It keeps path
  /// geometry out of the timeline contract while preserving one timing layer
  /// per pen stroke.
  static func makePathTimeline(
    strokeIDsAndLengths: [(id: String, length: Double)],
    options: WritingTimingOptions = .default
  ) throws -> WritingTimeline {
    guard !strokeIDsAndLengths.isEmpty else { throw WritingCoreError.emptyScene }
    var timings: [WritingStrokeTiming] = []
    timings.reserveCapacity(strokeIDsAndLengths.count)
    var currentTime = 0.0
    for (index, item) in strokeIDsAndLengths.enumerated() {
      guard item.length.isFinite, item.length >= 0 else {
        throw WritingCoreError.invalidNumber(field: "path.stroke.length", value: item.length)
      }
      let duration = max(options.minimumStrokeDuration, item.length / options.pointsPerSecond)
      let start = currentTime
      let end = start + duration
      timings.append(
        try WritingStrokeTiming(
          layerIndex: index,
          glyphIndex: 0,
          strokeIndex: index,
          strokeID: item.id,
          startTime: start,
          endTime: end
        )
      )
      currentTime = end + options.interStrokeDelay
    }
    return try WritingTimeline(
      duration: max(timings[timings.count - 1].endTime, 0.001),
      strokes: timings
    )
  }
}
