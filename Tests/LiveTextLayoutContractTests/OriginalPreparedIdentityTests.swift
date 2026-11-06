import Foundation
import LiveTextLayout
import Testing

struct OriginalPreparedIdentityTests {
  // Exported by the original local implementation, before its domain string
  // changed in the published package. This is a persisted-data fixture.
  private let fixture = #"{"atoms":[],"document":{"atoms":[],"schemaVersion":3},"identityContext":{"limits":{"maximumAtoms":16384,"maximumCancellableAtomGlyphs":131072,"maximumCancellableAtomRuns":65536,"maximumCancellableAtomUTF16Units":65536,"maximumGlyphs":2000000,"maximumGraphemes":1000000,"maximumImageAtoms":4096,"maximumRuns":500000,"maximumTextUTF16Units":1000000,"maximumWritingPoints":1048576,"maximumWritingStrokes":65536},"mode":"full"},"revision":"1770afe12ee187c56460d07a3506d1f78748022e4fd4cc586f6c61411549c5de","totalGlyphs":0,"totalGraphemes":0,"totalImageAtoms":0,"totalRuns":0,"totalTextUTF16Units":0}"#

  @Test
  func originalRevisionSurvivesDecodeRoundTripAndLayout() throws {
    let data = Data(fixture.utf8)
    let prepared = try JSONDecoder().decode(PreparedInlineDocument.self, from: data)
    #expect(prepared.revision == "1770afe12ee187c56460d07a3506d1f78748022e4fd4cc586f6c61411549c5de")
    #expect(try JSONDecoder().decode(PreparedInlineDocument.self, from: JSONEncoder().encode(prepared)) == prepared)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 1)
    #expect(layout.preparationRevision == prepared.revision)
    _ = try InlineRenderPlan(prepared: prepared, layout: layout)

    var oldPayload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    oldPayload.removeValue(forKey: "identityContext")
    #expect(try JSONDecoder().decode(PreparedInlineDocument.self,
      from: JSONSerialization.data(withJSONObject: oldPayload)) == prepared)
    oldPayload["totalGlyphs"] = 1
    #expect(throws: InlineLayoutError.self) {
      _ = try JSONDecoder().decode(PreparedInlineDocument.self,
        from: JSONSerialization.data(withJSONObject: oldPayload))
    }
    oldPayload["totalGlyphs"] = 0
    oldPayload["revision"] = String(repeating: "0", count: 64)
    #expect(throws: InlineLayoutError.self) {
      _ = try JSONDecoder().decode(PreparedInlineDocument.self,
        from: JSONSerialization.data(withJSONObject: oldPayload))
    }
  }
}
