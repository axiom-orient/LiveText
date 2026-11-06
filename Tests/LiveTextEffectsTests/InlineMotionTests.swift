import LiveTextEffects
import XCTest

final class InlineMotionTests: XCTestCase {
  func testEveryPresetStartsAndSettlesExactlyAtIdentity() throws {
    for style in InlineMotionStyle.allCases {
      let configuration = try! InlineMotionConfiguration(style: style)
      XCTAssertEqual(
        try configuration.sample(
          phase: .zero,
          atomIndex: 3,
          atomCount: 9,
          atomHeight: 28,
          atomID: "atom"
        ),
        .identity
      )
      XCTAssertEqual(
        try configuration.sample(
          phase: .complete,
          atomIndex: 3,
          atomCount: 9,
          atomHeight: 28,
          atomID: "atom"
        ),
        .identity
      )
    }
  }

  func testReduceMotionSuppressesSpatialExpression() throws {
    let phase = try InlineMotionPhase(0.46)
    XCTAssertEqual(
      try InlineMotionConfiguration.excited.sample(
        phase: phase,
        atomIndex: 0,
        atomCount: 1,
        atomHeight: 40,
        atomID: "hero",
        reduceMotion: true
      ),
      .identity
    )
  }

  func testSurprisedPresetUsesAnticipationExplosionAndLanding() throws {
    let anticipation = try InlineMotionConfiguration.surprised.sample(
      phase: InlineMotionPhase(0.12),
      atomIndex: 0,
      atomCount: 1,
      atomHeight: 40,
      atomID: "hero"
    )
    XCTAssertGreaterThan(anticipation.scaleX, 1.08)
    XCTAssertLessThan(anticipation.scaleY, 0.78)
    XCTAssertGreaterThan(anticipation.translationY, 2)

    let explosion = try InlineMotionConfiguration.surprised.sample(
      phase: InlineMotionPhase(0.30),
      atomIndex: 0,
      atomCount: 1,
      atomHeight: 40,
      atomID: "hero"
    )
    XCTAssertLessThan(explosion.scaleX, 0.86)
    XCTAssertGreaterThan(explosion.scaleY, 1.32)
    XCTAssertLessThan(explosion.translationY, -6)

    let landing = try InlineMotionConfiguration.surprised.sample(
      phase: InlineMotionPhase(0.52),
      atomIndex: 0,
      atomCount: 1,
      atomHeight: 40,
      atomID: "hero"
    )
    XCTAssertGreaterThan(landing.scaleX, 1.10)
    XCTAssertLessThan(landing.scaleY, 0.88)
    XCTAssertGreaterThan(landing.translationY, 1)
  }

  func testCartoonPresetsUseGroundedStableAnchors() throws {
    let phase = try InlineMotionPhase(0.30)
    for style in InlineMotionStyle.allCases where style != .none {
      let transform = try InlineMotionConfiguration(style: style).sample(
        phase: phase,
        atomIndex: 0,
        atomCount: 1,
        atomHeight: 40,
        atomID: "hero"
      )
      XCTAssertEqual(transform.anchorX, 0.5)
      XCTAssertTrue((0...1).contains(transform.anchorY))
      XCTAssertGreaterThanOrEqual(transform.anchorY, 0.70)
    }
  }

  func testEmotionProfilesUseDistinctTemporalCharacter() throws {
    let early = try InlineMotionPhase(0.12)
    let middle = try InlineMotionPhase(0.48)

    let surprised = try InlineMotionConfiguration.surprised.sample(
      phase: early, atomIndex: 0, atomCount: 1, atomHeight: 40, atomID: "hero")
    let thinking = try InlineMotionConfiguration.thinking.sample(
      phase: early, atomIndex: 0, atomCount: 1, atomHeight: 40, atomID: "hero")
    XCTAssertGreaterThan(abs(surprised.scaleY - 1), abs(thinking.scaleY - 1) * 8)

    let curiousEarly = try InlineMotionConfiguration.curious.sample(
      phase: early, atomIndex: 0, atomCount: 1, atomHeight: 40, atomID: "hero")
    let curiousMiddle = try InlineMotionConfiguration.curious.sample(
      phase: middle, atomIndex: 0, atomCount: 1, atomHeight: 40, atomID: "hero")
    XCTAssertLessThan(curiousEarly.rotationRadians * curiousMiddle.rotationRadians, 0)

    let excitedSecondLift = try InlineMotionConfiguration.excited.sample(
      phase: InlineMotionPhase(0.57),
      atomIndex: 0, atomCount: 1, atomHeight: 40, atomID: "hero")
    XCTAssertLessThan(excitedSecondLift.translationY, -2)
  }

  func testStaggerUsesStableDocumentOrderInsteadOfStartingAllAtomsTogether() throws {
    let phase = try InlineMotionPhase(0.08)
    let first = try InlineMotionConfiguration.happy.sample(
      phase: phase, atomIndex: 0, atomCount: 5, atomHeight: 40, atomID: "first")
    let last = try InlineMotionConfiguration.happy.sample(
      phase: phase, atomIndex: 4, atomCount: 5, atomHeight: 40, atomID: "last")

    XCTAssertNotEqual(first, .identity)
    XCTAssertEqual(last, .identity)
  }

  func testSamplingIsDeterministicAndDirectionUsesStableIdentity() throws {
    let phase = try InlineMotionPhase(0.53)
    let configuration = InlineMotionConfiguration.curious
    let first = try configuration.sample(
      phase: phase, atomIndex: 0, atomCount: 2, atomHeight: 32, atomID: "a")
    let repeated = try configuration.sample(
      phase: phase, atomIndex: 0, atomCount: 2, atomHeight: 32, atomID: "a")
    let other = try configuration.sample(
      phase: phase, atomIndex: 0, atomCount: 2, atomHeight: 32, atomID: "b")
    XCTAssertEqual(first, repeated)
    XCTAssertNotEqual(first.rotationRadians, other.rotationRadians)
  }

  func testAllSamplesStayFiniteAndWithinSafetyEnvelope() throws {
    let styles = InlineMotionStyle.allCases
    for style in styles {
      let configuration = try InlineMotionConfiguration(style: style)
      for step in 0...100 {
        let phase = try InlineMotionPhase(Double(step) / 100)
        let transform = try configuration.sample(
          phase: phase,
          atomIndex: 7,
          atomCount: 13,
          atomHeight: 64,
          atomID: "stress-\(style.rawValue)"
        )
        XCTAssertTrue(transform.translationX.isFinite)
        XCTAssertTrue(transform.translationY.isFinite)
        XCTAssertTrue(transform.scaleX.isFinite)
        XCTAssertTrue(transform.scaleY.isFinite)
        XCTAssertTrue(transform.rotationRadians.isFinite)
        XCTAssertTrue(transform.anchorX.isFinite)
        XCTAssertTrue(transform.anchorY.isFinite)
        XCTAssertTrue((0.60...1.40).contains(transform.scaleX))
        XCTAssertTrue((0.60...1.40).contains(transform.scaleY))
        XCTAssertTrue((0...1).contains(transform.anchorX))
        XCTAssertTrue((0...1).contains(transform.anchorY))
      }
    }
  }

  func testDecodedConfigurationRejectsNoncanonicalValues() throws {
    let encoded = try JSONEncoder().encode(InlineMotionConfiguration.excited)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["intensity"] = 4.0
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineMotionConfiguration.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    )

    object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["stagger"] = -0.1
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineMotionConfiguration.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    )
  }

  func testInvalidPhaseIntensityAndStaggerAreRejected() {
    XCTAssertThrowsError(try InlineMotionPhase(-0.01))
    XCTAssertThrowsError(try InlineMotionPhase(.nan))
    XCTAssertThrowsError(try InlineMotionConfiguration(style: .happy, intensity: 1.01))
    XCTAssertThrowsError(try InlineMotionConfiguration(style: .happy, stagger: 0.46))
    XCTAssertThrowsError(
      try InlineMotionConfiguration.happy.sample(
        phase: .zero, atomIndex: 0, atomCount: 0, atomHeight: 20, atomID: "a"))
    XCTAssertThrowsError(
      try InlineMotionConfiguration.happy.sample(
        phase: .zero, atomIndex: -1, atomCount: 1, atomHeight: 20, atomID: "a"))
    XCTAssertThrowsError(
      try InlineMotionConfiguration.happy.sample(
        phase: .zero, atomIndex: 0, atomCount: 1, atomHeight: .nan, atomID: "a"))
  }
}
