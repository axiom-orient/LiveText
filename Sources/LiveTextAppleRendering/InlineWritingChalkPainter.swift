import CoreGraphics
import LiveTextChalkRendering
import LiveTextEffects
import SwiftUI

/// LiveText adapter for the package-internal chalk engine.
package enum InlineWritingChalkPainter {
  public static func paint(
    mask: Path,
    target: WritingMaterialTarget,
    configuration: WritingChalkConfiguration,
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    ChalkMaskRenderer.paint(
      mask: mask,
      target: target,
      configuration: configuration,
      color: color,
      documentOriginAtContextZero: documentOriginAtContextZero,
      in: &context
    )
  }

}
