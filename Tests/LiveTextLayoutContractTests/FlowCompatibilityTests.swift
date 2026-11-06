import Foundation
import LiveTextLayout
import Testing

struct FlowCompatibilityTests {
  @Test
  func inlinePreservesOrdinaryRegionAndSerializedGeometry() throws {
    let rect = try InlineFlowRect(x: 0, y: 0, width: 320, height: 200)
    let exclusion = try InlineFlowExclusion(
      id: "overlay", rect: InlineFlowRect(x: 100, y: 30, width: 20, height: 30))
    let ordinary = try InlineFlowRegion(rect: rect, exclusions: [exclusion], revision: 9)
    let inline = try InlineFlowRegion(
      rect: rect, exclusions: [exclusion], revision: 9, layoutStyle: .inline)
    #expect(inline == ordinary)
    let decoded = try JSONDecoder().decode(InlineFlowRegion.self, from: JSONEncoder().encode(inline))
    #expect(decoded == ordinary)
    #expect(throws: InlineLayoutError.self) {
      _ = try InlineFlowRegion(rect: rect, exclusions: [exclusion, exclusion], layoutStyle: .inline)
    }
  }

  @Test
  func magazineOverloadsShareValidationAndExclusions() throws {
    let rect = try InlineFlowRect(x: 0, y: 0, width: 320, height: 200)
    let media = try InlineMagazineMedia(
      id: "image", rect: InlineFlowRect(x: 0, y: 10, width: 48, height: 48))
    let style = try InlineMagazineStyle(minimumXMedia: [media], mediaGap: 5, minimumTextWidth: 40)
    let old = try InlineFlowRegion(rect: rect, revision: 3, layoutStyle: .magazine(style))
    let current = try InlineFlowRegion(rect: rect, revision: 3, magazineStyle: style)
    #expect(old == current)
    #expect(current.exclusions.count == 1)
    #expect(try InlineFlowRegion(rect: rect, layoutStyle: .standard)
      == InlineFlowRegion(rect: rect, magazineStyle: .standard))
    let narrow = try InlineFlowRect(x: 0, y: 0, width: 20, height: 200)
    #expect(throws: InlineLayoutError.self) {
      _ = try InlineFlowRegion(rect: narrow, layoutStyle: .magazine(style))
    }
    #expect(throws: InlineLayoutError.self) {
      _ = try InlineFlowRegion(rect: narrow, magazineStyle: style)
    }
  }
}
