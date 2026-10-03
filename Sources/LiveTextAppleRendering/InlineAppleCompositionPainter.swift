import SwiftUI

/// Single target-local composition-mask executor shared by static and append Apple renderers.
///
/// Reveal masks intersect before paint. Erase masks run with destination-out after paint. Keeping
/// both operations here prevents Canvas, SwiftUI, and append from drifting in ordering or blend
/// semantics while leaving composition planning in LiveTextLayout.
package enum InlineAppleCompositionPainter {
  package static func applyRevealMasks(
    _ masks: [InlineAppleSVGMask],
    in context: inout GraphicsContext
  ) {
    for mask in masks where mask.operation == .reveal {
      context.clip(to: mask.path, style: FillStyle(eoFill: true))
    }
  }

  package static func applyEraseMasks(
    _ masks: [InlineAppleSVGMask],
    in context: inout GraphicsContext
  ) {
    for mask in masks where mask.operation == .erase {
      var eraser = context
      eraser.blendMode = .destinationOut
      eraser.fill(mask.path, with: .color(.white), style: FillStyle(eoFill: true))
      eraser.blendMode = .normal
      context = eraser
    }
  }
}
