import LiveText
import LiveTextCore
import LiveTextLayout
import LiveTextEffects
import LiveTextSVG
import LiveTextApple
import LiveTextAppleRendering
import LiveTextSwiftUI
import LiveTextCanvas
import LiveTextWritingUI
import ChalkLineEffects
import LiveTextPresentation
import DustKit

public func makeStyle() throws -> ChalkWritingStyle {
  let material = try WritingChalkConfiguration(style: .fineLine)
  return try ChalkWritingStyle(configuration: material)
}

public func makeInlineConfiguration() throws -> InlineLiveTextLayoutConfiguration {
  try InlineLiveTextLayoutConfiguration(width: 320, layoutStyle: .inline)
}

public func makeInlineRegion() throws -> InlineFlowRegion {
  try InlineFlowRegion(
    rect: InlineFlowRect(x: 0, y: 0, width: 320, height: 200), layoutStyle: .inline)
}
