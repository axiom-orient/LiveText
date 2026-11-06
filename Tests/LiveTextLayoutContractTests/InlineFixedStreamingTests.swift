import XCTest

@testable import LiveTextLayout

final class InlineFixedStreamingTests: XCTestCase {
  private struct UnusedShaper: InlineTextShaping {
    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      throw InlineLayoutError.unsupportedShaping("vector-only fixture invoked text shaping")
    }
  }

  private func preparedVectors(count: Int) throws -> PreparedInlineDocument {
    let atoms = try (0..<count).map { index in
      try InlineAtom.vector(
        InlineVectorAtom(
          id: "stream-vector-\(index)",
          assetID: InlineAssetID(rawValue: "stream-vector-\(index)"),
          metrics: InlineMetrics(advance: 1, ascent: 1, descent: 0)
        ))
    }
    return try InlinePreparation(shaper: UnusedShaper())
      .prepare(document: InlineDocument(atoms: atoms))
  }

  func testFixedDocumentStreamPublishesBoundedCompleteTails() async throws {
    let prepared = try preparedVectors(count: 4)
    let engine = try InlineLayoutEngine()
    var results: [InlineLayoutResult] = []

    for try await result in engine.stream(
      prepared: prepared,
      width: 1,
      maximumLinesPerYield: 1
    ) {
      try result.validate(for: prepared)
      XCTAssertLessThanOrEqual(result.lines.count, 1)
      results.append(result)
    }

    XCTAssertEqual(results.count, 4)
    XCTAssertNil(results.last?.continuation)
  }

  func testFixedDocumentStreamDoesNotProduceAheadOfDemand() async throws {
    let prepared = try preparedVectors(count: 8)
    let engine = try InlineLayoutEngine()
    let stream = engine.stream(
      prepared: prepared,
      width: 1,
      maximumLinesPerYield: 1
    )

    // A demand-driven stream must remain inert while nobody is awaiting
    // `next()`. Sleeping before consumption therefore cannot fill a hidden
    // buffer or lose layout tails.
    try await Task.sleep(for: .milliseconds(30))

    var delivered = 0
    for try await result in stream {
      try result.validate(for: prepared)
      delivered += 1
    }
    XCTAssertEqual(delivered, 8)
  }

  func testPrepareAndLayoutStreamDoesNotProduceAheadOfDemand() async throws {
    let atoms = try (0..<8).map { index in
      try InlineAtom.vector(
        InlineVectorAtom(
          id: "prepared-stream-vector-\(index)",
          assetID: InlineAssetID(rawValue: "prepared-stream-vector-\(index)"),
          metrics: InlineMetrics(advance: 1, ascent: 1, descent: 0)
        ))
    }
    let document = try InlineDocument(atoms: atoms)
    let preparation = InlinePreparation(shaper: UnusedShaper())
    let engine = try InlineLayoutEngine()
    let stream = preparation.prepareAndLayoutStream(
      document: document,
      engine: engine,
      width: 1,
      maximumLinesPerYield: 1
    )

    // Preparation and layout are both deferred until the first demand. This
    // regression specifically protects against the former eager producer race.
    try await Task.sleep(for: .milliseconds(30))

    var delivered = 0
    var revision: String?
    for try await value in stream {
      revision = revision ?? value.prepared.revision
      XCTAssertEqual(value.prepared.revision, revision)
      delivered += 1
    }
    XCTAssertEqual(delivered, 8)
  }

  func testFixedDocumentStreamConsumerCancellationTerminatesIteration() async throws {
    let prepared = try preparedVectors(count: 512)
    let engine = try InlineLayoutEngine()
    let stream = engine.stream(
      prepared: prepared,
      width: 1,
      maximumLinesPerYield: 1
    )

    let consumer = Task { () -> InlineLayoutError? in
      do {
        for try await _ in stream {}
        return nil
      } catch let error as InlineLayoutError {
        return error
      } catch is CancellationError {
        return .cancelled
      } catch {
        return nil
      }
    }
    consumer.cancel()

    let result = await consumer.value
    // AsyncThrowingStream cancellation is itself a terminal iterator state;
    // the standard library permits the awaiting iterator to resume with nil
    // instead of a producer-defined error. The stream has no detached
    // producer task, so termination cannot leave background layout work
    // running after the consumer stops requesting elements.
    XCTAssertNil(result)
  }
}
