import Foundation
import LiveTextEffects
import Testing
@testable import ChalkLineEffects
@testable import LiveTextChalkRendering

struct ChalkDefaultsAndCacheTests {
  @Test
  func newDefaultsUseDryBrushAndExplicitFineLineRemainsAvailable() throws {
    #expect(try WritingChalkConfiguration() == .default)
    #expect(WritingChalkConfiguration.default.style == .dryBrush)
    #expect(ChalkWritingStyle.chalk.configuration.style == .dryBrush)
    #expect(try WritingChalkConfiguration(style: .fineLine).style == .fineLine)
    #expect(WritingChalkConfiguration.classic.style == .fineLine)
    #expect(WritingChalkConfiguration.fineLine.style == .fineLine)
  }

  @Test
  func legacyEncodedStyleIsPreserved() throws {
    let original = WritingChalkConfiguration.classic
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "style")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(WritingChalkConfiguration.self, from: legacy) == original)
  }

  @Test
  func sharedPreparationRemainsDeterministicAcrossConcurrentReuseAndStyleChanges() async throws {
    let preparation = try ChalkWritingPreparation(text: "한글 ABC")
    let reference = try ChalkWritingPreparation(text: "한글 ABC")
      .renderPlanCache.contactPlan(style: .chalk)
    try await withThrowingTaskGroup(of: ChalkPreparedContactPlan?.self) { group in
      for index in 0..<24 {
        group.addTask {
          let style = try ChalkWritingStyle(color: index.isMultiple(of: 2) ? .chalkPink : .chalkBlue)
          return try preparation.renderPlanCache.contactPlan(style: style)
        }
      }
      for try await plan in group { #expect(plan?.strokes == reference?.strokes) }
    }
    let wide = try ChalkWritingStyle(lineWidthMultiplier: 2)
    let wider = try #require(try preparation.renderPlanCache.contactPlan(style: wide))
    #expect(wider.strokes != reference?.strokes)
    let restored = try preparation.renderPlanCache.contactPlan(style: .chalk)
    #expect(restored?.strokes == reference?.strokes)
  }
}
