import Foundation
import LiveTextLayout
import XCTest

/// Guards the host-selection state-machine transitions that the effects
/// contract tests do not cover: the clear event (success and stale rejection)
/// and activation rejection of a zero-length hit. Inputs are pure
/// state-machine values; no layout or renderer is involved.
final class InlineSelectionClearTransitionTests: XCTestCase {
  private let profile = InlineTextUnitHitProfile.default

  /// The hit-index intentionally never emits whitespace targets under the
  /// default profile, so the rejection boundary is exercised with an
  /// explicitly decoded non-selectable hit instead of a fabricated one.
  private func decodedHit(atomID: String, startUTF16: Int, endUTF16: Int) throws
    -> InlineTextUnitHit
  {
    let object: [String: Any] = [
      "atomID": atomID,
      "unitKind": "word",
      "sourceRange": ["startUTF16": startUTF16, "endUTF16": endUTF16],
      "lineIndex": 0,
      "rect": ["minX": 0.0, "minY": 0.0, "width": 4.0, "height": 14.0],
    ]
    return try JSONDecoder().decode(
      InlineTextUnitHit.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func selectedState(preparationRevision: String) throws
    -> InlineTextUnitSelectionState
  {
    let state = try InlineTextUnitSelectionState(
      preparationRevision: preparationRevision, hitProfile: profile)
    let hit = try decodedHit(atomID: "word", startUTF16: 0, endUTF16: 4)
    return try state.applying(try state.activationEvent(for: hit))
  }

  func testClearEventOnSelectedStateReturnsEmptyStateWithSameIdentity() throws {
    let state = try selectedState(preparationRevision: "revision-1")
    XCTAssertNotNil(state.selected)

    let cleared = try state.applying(
      .clear(
        preparationRevision: "revision-1", hitProfile: profile))

    XCTAssertNil(cleared.selected)
    XCTAssertEqual(cleared.preparationRevision, "revision-1")
    XCTAssertEqual(cleared.hitProfile, profile)
  }

  func testStaleClearEventIsRejectedAndKeepsSelectionUnchanged() throws {
    let state = try selectedState(preparationRevision: "revision-1")
    let selected = try XCTUnwrap(state.selected)

    XCTAssertThrowsError(
      try state.applying(
        .clear(
          preparationRevision: "revision-2", hitProfile: profile))
    ) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "selection.clear")
      XCTAssertEqual(failure?.preparationRevision, "revision-1")
      XCTAssertEqual(failure?.targetID, selected.atomID)
      XCTAssertFalse(failure?.cause.isEmpty ?? true)
    }
    XCTAssertEqual(state.selected, selected, "a rejected clear must not mutate state")
  }

  func testActivationEventRejectsZeroLengthHitUnderDefaultProfile() throws {
    let state = try InlineTextUnitSelectionState(
      preparationRevision: "revision-1", hitProfile: profile)
    // The hit index never emits empty targets under the default profile; the
    // state machine still rejects one defensively because InlineSourceRange
    // permits zero length at construction.
    let empty = try decodedHit(atomID: "empty", startUTF16: 3, endUTF16: 3)

    XCTAssertThrowsError(try state.activationEvent(for: empty)) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "selection.activate")
      XCTAssertEqual(failure?.targetID, "empty")
      XCTAssertEqual(failure?.preparationRevision, "revision-1")
    }
    XCTAssertNil(state.selected, "a rejected activation must not mutate state")
  }
}
