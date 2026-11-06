import LiveTextCore
import XCTest

final class LiveTextCoreAdmissionTests: XCTestCase {
  private struct FixtureSegmenter: WordSegmenting {
    func tokenize(_ text: String, localeIdentifier: String?) -> [WordToken] {
      guard !text.isEmpty else { return [] }
      return [WordToken(text: text, startUTF16: 0, isWordLike: true)]
    }
  }

  private struct FixtureMeasurer: SegmentMeasuring {
    func measure(_ request: SegmentMeasurementRequest) throws -> SegmentMeasurement {
      let graphemeCount = request.text.count
      let breakableAdvances: [Double]? =
        request.breakableMode == .none
        ? nil
        : Array(repeating: 1, count: graphemeCount)
      return SegmentMeasurement(
        width: Double(graphemeCount),
        containsCJK: false,
        breakableAdvances: breakableAdvances
      )
    }
  }

  private var engine: LiveTextEngine<FixtureSegmenter, FixtureMeasurer> {
    LiveTextEngine(segmenter: FixtureSegmenter(), measurer: FixtureMeasurer())
  }

  private func prepared(_ text: String = "ab") throws -> PreparedText {
    try engine.prepare(
      text,
      font: FontDescriptor(postScriptName: "LiveTextFixture", pointSize: 10)
    )
  }

  private func assertInvalidFragmentConfiguration(
    _ body: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      guard case .invalidFragmentConfiguration = error as? LiveTextCoreError else {
        return XCTFail(
          "expected invalidFragmentConfiguration, got \(error)", file: file, line: line)
      }
    }
  }

  func testFixedLayoutRejectsInvalidLineHeightAndHeightOverflowButAllowsZero() throws {
    let prepared = try prepared()

    for invalid in [Double.nan, Double.infinity, -Double.infinity, -1] {
      assertInvalidFragmentConfiguration {
        _ = try engine.layout(prepared: prepared, maxWidth: 1, lineHeight: invalid)
      }
      assertInvalidFragmentConfiguration {
        _ = try engine.layoutWithLines(prepared: prepared, maxWidth: 1, lineHeight: invalid)
      }
    }

    XCTAssertEqual(
      try engine.layout(prepared: prepared, maxWidth: 1, lineHeight: 0).height,
      0
    )
    assertInvalidFragmentConfiguration {
      _ = try engine.layout(
        prepared: prepared,
        maxWidth: 1,
        lineHeight: .greatestFiniteMagnitude
      )
    }
  }

  func testVariableLineRejectsNonFiniteHorizontalAndVerticalRangesAndIndexOverflow() throws {
    let prepared = try prepared("a")

    assertInvalidFragmentConfiguration {
      _ = try engine.layoutWithVariableLineConstraints(
        prepared: prepared,
        lineHeight: 1
      ) { _, _, _ in
        VariableLineFragmentConstraint(originX: .nan, maxWidth: 1)
      }
    }

    assertInvalidFragmentConfiguration {
      _ = try engine.layoutWithVariableLineConstraints(
        prepared: prepared,
        lineHeight: .greatestFiniteMagnitude,
        continuation: VariableLayoutContinuation(cursor: .zero, nextIndex: 2)
      ) { _, _, _ in
        XCTFail("provider must not run after vertical-range rejection")
        return VariableLineFragmentConstraint(originX: 0, maxWidth: 1)
      }
    }

    assertInvalidFragmentConfiguration {
      _ = try engine.layoutWithVariableLineConstraints(
        prepared: prepared,
        lineHeight: 0,
        continuation: VariableLayoutContinuation(cursor: .zero, nextIndex: Int.max)
      ) { _, _, _ in
        VariableLineFragmentConstraint(originX: 0, maxWidth: 1)
      }
    }
  }

  func testVariableRowRejectsNonFiniteHorizontalRangeAndIndexOverflow() throws {
    let prepared = try prepared("a")

    assertInvalidFragmentConfiguration {
      _ = try engine.layoutWithVariableRowFragments(
        prepared: prepared,
        lineHeight: 1
      ) { _, _, _ in
        [
          VariableLineFragmentConstraint(
            originX: .greatestFiniteMagnitude, maxWidth: .greatestFiniteMagnitude)
        ]
      }
    }

    assertInvalidFragmentConfiguration {
      _ = try engine.layoutWithVariableRowFragments(
        prepared: prepared,
        lineHeight: 0,
        continuation: VariableLayoutContinuation(cursor: .zero, nextIndex: Int.max)
      ) { _, _, _ in
        [VariableLineFragmentConstraint(originX: 0, maxWidth: 1)]
      }
    }
  }
}
