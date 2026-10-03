import Foundation
import LiveTextEffects
import LiveTextLayout

/// The single Apple-side conversion from immutable source-distance material segments to
/// renderer-neutral variable-width writing geometry.
///
/// Callers must pass an already-selected visible segment prefix. This kernel performs no reveal
/// scheduling, layout, I/O, caching, or drawing; Canvas, SwiftUI, and append therefore share the
/// exact same pressure/taper geometry without duplicating the grouping algorithm.
package enum InlineAppleWritingMaterialGeometry {
  package static func make(
    segments: [InlineWritingMaterialSegment],
    material: WritingMaterial,
    destinationHeight: Double,
    offsetX: Double = 0,
    offsetY: Double = 0
  ) -> [WritingStrokeGeometry] {
    guard !segments.isEmpty else { return [] }

    var result: [WritingStrokeGeometry] = []
    result.reserveCapacity(segments.count / 4 + 1)
    var index = 0
    while index < segments.count {
      let subpathID = segments[index].subpathID
      var endIndex = index + 1
      while endIndex < segments.count, segments[endIndex].subpathID == subpathID {
        endIndex += 1
      }

      var samples: [WritingStrokeSample] = []
      var sourceDistances: [Double] = []
      samples.reserveCapacity(endIndex - index + 1)
      sourceDistances.reserveCapacity(endIndex - index + 1)

      func appendSample(x: Double, y: Double, distance: Double) {
        guard x.isFinite, y.isFinite, distance.isFinite else { return }
        if let last = samples.last,
          abs(last.x - x) < 0.01,
          abs(last.y - y) < 0.01
        {
          if let lastDistance = sourceDistances.last {
            sourceDistances[sourceDistances.count - 1] = max(lastDistance, distance)
          }
          return
        }
        samples.append(WritingStrokeSample(x: x, y: y))
        sourceDistances.append(distance)
      }

      for segment in segments[index..<endIndex] {
        appendSample(
          x: Double(segment.start.x) + offsetX,
          y: Double(segment.start.y) + offsetY,
          distance: segment.startDistance
        )
      }
      let last = segments[endIndex - 1]
      appendSample(
        x: Double(last.end.x) + offsetX,
        y: Double(last.end.y) + offsetY,
        distance: last.endDistance
      )

      guard samples.count > 1, let visibleLength = sourceDistances.last else {
        index = endIndex
        continue
      }
      let geometry = WritingStrokeGeometryPlan.geometry(
        samples: samples,
        isClosed: last.isClosed,
        material: material,
        destinationHeight: max(destinationHeight, 1),
        seedSalt: UInt64(truncatingIfNeeded: subpathID &+ 1)
          &* 0x9E37_79B9_7F4A_7C15,
        sourceDistances: sourceDistances,
        visibleLength: visibleLength
      )
      if !geometry.body.isEmpty {
        result.append(geometry)
      }
      index = endIndex
    }
    return result
  }
}
