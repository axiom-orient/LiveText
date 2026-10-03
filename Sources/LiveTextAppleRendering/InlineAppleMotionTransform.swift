import CoreGraphics
import LiveTextEffects
import LiveTextLayout
import SwiftUI

/// Applies one already-sampled presentation transform around its normalized
/// logical-cell anchor. The caller chooses the coordinate offset; layout and hit
/// geometry remain untouched.
package func inlineAppleApplyMotion(
  _ motion: InlineMotionTransform,
  positioned: PositionedInlineAtom,
  coordinateOffsetX: Double = 0,
  coordinateOffsetY: Double = 0,
  in context: inout GraphicsContext
) {
  guard motion != .identity else { return }

  let top = positioned.baselineY - positioned.metrics.baselineOffset - positioned.metrics.ascent
  let anchorX = CGFloat(
    positioned.originX + positioned.width * motion.anchorX + coordinateOffsetX
  )
  let anchorY = CGFloat(
    top + positioned.height * motion.anchorY + coordinateOffsetY
  )

  var transform = CGAffineTransform(
    translationX: anchorX + CGFloat(motion.translationX),
    y: anchorY + CGFloat(motion.translationY)
  )
  transform = transform.rotated(by: CGFloat(motion.rotationRadians))
  transform = transform.scaledBy(x: CGFloat(motion.scaleX), y: CGFloat(motion.scaleY))
  transform = transform.translatedBy(x: -anchorX, y: -anchorY)

  context.concatenate(transform)
}

package func inlineAppleMotionOrdinal(
  atomID: String,
  in ordinals: [String: Int]
) -> Int {
  guard let ordinal = ordinals[atomID] else {
    preconditionFailure("validated render atom must have a semantic motion ordinal")
  }
  return ordinal
}
