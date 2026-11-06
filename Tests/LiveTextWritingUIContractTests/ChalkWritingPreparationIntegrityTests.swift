@testable import ChalkLineEffects
import Foundation
import XCTest

final class ChalkWritingPreparationIntegrityTests: XCTestCase {
  private struct WirePayload: Codable {
    let scene: StrokeWritingScene
    let timeline: WritingTimeline
  }

  func testValidSceneAndTimelineRoundTrip() throws {
    let fixture = try makeFixture()
    let preparation = try decodePreparation(scene: fixture.scene, timeline: fixture.timeline)
    let encoded = try JSONEncoder().encode(preparation)
    let decoded = try JSONDecoder().decode(ChalkWritingPreparation.self, from: encoded)

    XCTAssertEqual(decoded, preparation)
    XCTAssertEqual(decoded.scene, fixture.scene)
    XCTAssertEqual(decoded.timeline, fixture.timeline)
  }

  func testDecodedPreparationRejectsUnknownTimelineStrokeID() throws {
    let fixture = try makeFixture()
    var timings = fixture.timeline.strokes
    timings[0] = try replacing(timings[0], strokeID: "unknown-stroke")
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration, strokes: timings)
    )
  }

  func testDecodedPreparationRejectsRemovedTimelineStroke() throws {
    let fixture = try makeFixture()
    var timings = fixture.timeline.strokes
    timings.remove(at: 1)
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration, strokes: timings)
    )
  }

  func testDecodedPreparationRejectsExtraTimelineStroke() throws {
    let fixture = try makeFixture()
    var timings = fixture.timeline.strokes
    timings.append(
      try WritingStrokeTiming(
        layerIndex: timings.count,
        glyphIndex: 99,
        strokeIndex: 0,
        strokeID: "extra-stroke",
        startTime: fixture.timeline.duration,
        endTime: fixture.timeline.duration + 1
      )
    )
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration + 1, strokes: timings)
    )
  }

  func testDecodedPreparationRejectsReorderedTimelineIDs() throws {
    let fixture = try makeFixture()
    var timings = fixture.timeline.strokes
    let firstID = timings[0].strokeID
    timings[0] = try replacing(timings[0], strokeID: timings[1].strokeID)
    timings[1] = try replacing(timings[1], strokeID: firstID)
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration, strokes: timings)
    )
  }

  func testDecodedPreparationRejectsWrongSemanticIndexes() throws {
    let fixture = try makeFixture()

    var wrongLayer = fixture.timeline.strokes
    wrongLayer[wrongLayer.count - 1] = try replacing(
      wrongLayer[wrongLayer.count - 1], layerIndex: 99)
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration, strokes: wrongLayer)
    )

    var wrongGlyph = fixture.timeline.strokes
    wrongGlyph[0] = try replacing(
      wrongGlyph[0], glyphIndex: wrongGlyph[0].glyphIndex + 1)
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration, strokes: wrongGlyph)
    )

    var wrongStroke = fixture.timeline.strokes
    wrongStroke[1] = try replacing(
      wrongStroke[1], strokeIndex: wrongStroke[1].strokeIndex + 10)
    try assertInvalidDecodedTimeline(
      scene: fixture.scene,
      timeline: try WritingTimeline(duration: fixture.timeline.duration, strokes: wrongStroke)
    )
  }

  func testRenderPlanRejectsMissingStrokeInsteadOfPublishingPartialPlan() throws {
    let fixture = try makeFixture()
    var timings = fixture.timeline.strokes
    timings[2] = try replacing(timings[2], strokeID: "missing-stroke")
    let timeline = try WritingTimeline(duration: fixture.timeline.duration, strokes: timings)

    XCTAssertThrowsError(try ChalkWritingRenderPlan(scene: fixture.scene, timeline: timeline)) {
      error in
      XCTAssertEqual(error as? WritingCoreError, .invalidTimeline)
    }
  }

  private func assertInvalidDecodedTimeline(
    scene: StrokeWritingScene,
    timeline: WritingTimeline,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let data = try JSONEncoder().encode(WirePayload(scene: scene, timeline: timeline))
    XCTAssertThrowsError(
      try JSONDecoder().decode(ChalkWritingPreparation.self, from: data),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? WritingCoreError,
        .invalidTimeline,
        "decoded scene/timeline ownership must be exact",
        file: file,
        line: line
      )
    }
  }

  private func makeFixture() throws -> (scene: StrokeWritingScene, timeline: WritingTimeline) {
    let strokes = try [
      WritingStroke(id: "g4-s0", points: try makePoints(offset: 0)),
      WritingStroke(id: "g4-s1", points: try makePoints(offset: 10)),
      WritingStroke(id: "g9-s0", points: try makePoints(offset: 20)),
      WritingStroke(id: "g9-s1", points: try makePoints(offset: 30)),
    ]
    let firstGlyph = try StrokeGlyph(
      index: 4,
      cluster: "A",
      advance: 20,
      strokes: Array(strokes[0..<2])
    )
    let secondGlyph = try StrokeGlyph(
      index: 9,
      cluster: "B",
      advance: 20,
      strokes: Array(strokes[2..<4])
    )
    let scene = try StrokeWritingScene(
      text: "AB",
      size: try WritingSize(width: 100, height: 100),
      glyphs: [firstGlyph, secondGlyph],
      source: .custom(description: "integrity-test"),
      catalogVersion: "test"
    )
    let timings = try strokes.enumerated().map { index, stroke in
      try WritingStrokeTiming(
        layerIndex: index,
        glyphIndex: index < 2 ? 4 : 9,
        strokeIndex: index % 2,
        strokeID: stroke.id,
        startTime: Double(index),
        endTime: Double(index + 1)
      )
    }
    return (scene, try WritingTimeline(duration: 4, strokes: timings))
  }

  private func makePoints(offset: Double) throws -> [WritingPoint] {
    [
      try WritingPoint(x: offset, y: 0),
      try WritingPoint(x: offset + 1, y: 1),
    ]
  }

  private func decodePreparation(
    scene: StrokeWritingScene,
    timeline: WritingTimeline
  ) throws -> ChalkWritingPreparation {
    let data = try JSONEncoder().encode(WirePayload(scene: scene, timeline: timeline))
    return try JSONDecoder().decode(ChalkWritingPreparation.self, from: data)
  }

  private func replacing(
    _ timing: WritingStrokeTiming,
    layerIndex: Int? = nil,
    glyphIndex: Int? = nil,
    strokeIndex: Int? = nil,
    strokeID: String? = nil
  ) throws -> WritingStrokeTiming {
    try WritingStrokeTiming(
      layerIndex: layerIndex ?? timing.layerIndex,
      glyphIndex: glyphIndex ?? timing.glyphIndex,
      strokeIndex: strokeIndex ?? timing.strokeIndex,
      strokeID: strokeID ?? timing.strokeID,
      startTime: timing.startTime,
      endTime: timing.endTime
    )
  }
}
