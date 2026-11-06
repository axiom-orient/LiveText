#if os(iOS)
  import LiveTextPresentation
  import SwiftUI
  import XCTest

  @MainActor
  final class InlineTerminalDustSourceControllerTests: XCTestCase {
    private func completedRequest(_ controller: InlineTerminalDustSourceController) -> UInt64? {
      guard case .ready(_, let requestID) = controller.state else { return nil }
      return requestID
    }

    private func waitUntilSettled(_ controller: InlineTerminalDustSourceController) async throws {
      for _ in 0..<200 {
        if !controller.isPreparing { return }
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTFail("The real SwiftUI snapshot did not settle within the test deadline")
    }

    func testReturningToCompletedRevisionCancelsPendingDifferentRevision() async throws {
      let controller = InlineTerminalDustSourceController()
      controller.prepare(revision: "A", size: CGSize(width: 20, height: 20), debounce: .zero) {
        Color.red
      }
      try await waitUntilSettled(controller)
      let originalRequest = try XCTUnwrap(completedRequest(controller))
      controller.prepare(
        revision: "B", size: CGSize(width: 20, height: 20), debounce: .milliseconds(30)
      ) {
        Color.blue
      }
      XCTAssertTrue(controller.isPreparing)
      controller.prepare(revision: "A", size: CGSize(width: 20, height: 20), debounce: .zero) {
        Color.red
      }
      XCTAssertFalse(controller.isPreparing)
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertEqual(completedRequest(controller), originalRequest)
      XCTAssertNil(controller.lastErrorMessage)
    }

    func testFailedCandidateRetainsCompletedSourceAndPublishesError() async throws {
      let controller = InlineTerminalDustSourceController()
      controller.prepare(revision: "A", size: CGSize(width: 20, height: 20), debounce: .zero) {
        Color.red
      }
      try await waitUntilSettled(controller)
      let originalRequest = try XCTUnwrap(completedRequest(controller))
      controller.prepare(revision: "invalid", size: .zero, debounce: .zero) { Color.blue }
      try await waitUntilSettled(controller)
      XCTAssertEqual(completedRequest(controller), originalRequest)
      XCTAssertNotNil(controller.lastErrorMessage)
    }

    func testResetPreventsDelayedSnapshotPublication() async throws {
      let controller = InlineTerminalDustSourceController()
      controller.prepare(
        revision: "A", size: CGSize(width: 20, height: 20), debounce: .milliseconds(30)
      ) {
        Color.red
      }
      controller.reset()
      try await Task.sleep(for: .milliseconds(80))
      guard case .idle = controller.state else { return XCTFail("reset must remain authoritative") }
      XCTAssertFalse(controller.isPreparing)
      XCTAssertNil(controller.lastErrorMessage)
    }

    func testIdenticalPendingRequestDoesNotRebuildOrRestartDebounce() async throws {
      let controller = InlineTerminalDustSourceController()
      var contentBuilds = 0
      for _ in 0..<5 {
        controller.prepare(
          revision: "A", size: CGSize(width: 20, height: 20), debounce: .milliseconds(30)
        ) {
          contentBuilds += 1
          return Color.red
        }
      }
      XCTAssertEqual(contentBuilds, 1)
      try await waitUntilSettled(controller)
      XCTAssertNotNil(completedRequest(controller))
    }

    func testCancellationKeepsCompletedSourceAndAllowsReplacement() async throws {
      let controller = InlineTerminalDustSourceController()
      controller.prepare(revision: "A", size: CGSize(width: 20, height: 20), debounce: .zero) {
        Color.red
      }
      try await waitUntilSettled(controller)
      let originalRequest = try XCTUnwrap(completedRequest(controller))
      controller.prepare(
        revision: "B", size: CGSize(width: 20, height: 20), debounce: .milliseconds(30)
      ) { Color.blue }
      controller.cancel()
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertEqual(completedRequest(controller), originalRequest)
      controller.prepare(revision: "B", size: CGSize(width: 20, height: 20), debounce: .zero) {
        Color.blue
      }
      try await waitUntilSettled(controller)
      XCTAssertNotEqual(completedRequest(controller), originalRequest)
      XCTAssertNotNil(completedRequest(controller))
    }

    func testInitialFailureCanRetrySameRevisionWithValidSize() async throws {
      let controller = InlineTerminalDustSourceController()
      controller.prepare(revision: "A", size: .zero, debounce: .zero) { Color.red }
      try await waitUntilSettled(controller)
      guard case .failed = controller.state else { return XCTFail("invalid size must fail") }
      XCTAssertNotNil(controller.lastErrorMessage)
      controller.prepare(revision: "A", size: CGSize(width: 20, height: 20), debounce: .zero) {
        Color.red
      }
      try await waitUntilSettled(controller)
      XCTAssertNotNil(completedRequest(controller))
      XCTAssertNil(controller.lastErrorMessage)
    }
  }
#endif
