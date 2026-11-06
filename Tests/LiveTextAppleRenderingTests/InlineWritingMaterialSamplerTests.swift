import LiveTextAppleRendering
import CoreGraphics
import LiveTextLayout
import XCTest

final class InlineWritingMaterialSamplerTests: XCTestCase {
  func testCommandMetadataPreservesNormalEightAndTenSampleRevealDistances() throws {
    let move = try InlinePathPoint(x: 0, y: 0)
    let lineEnd = try InlinePathPoint(x: 3, y: 4)
    let quadraticControl = try InlinePathPoint(x: 8, y: 10)
    let quadraticEnd = try InlinePathPoint(x: 12, y: 0)
    let cubicControl1 = try InlinePathPoint(x: 16, y: -7)
    let cubicControl2 = try InlinePathPoint(x: 21, y: 12)
    let cubicEnd = try InlinePathPoint(x: 25, y: 5)
    let commands: [InlinePathCommand] = [
      .move(move),
      .line(lineEnd),
      .quadratic(control: quadraticControl, to: quadraticEnd),
      .cubic(control1: cubicControl1, control2: cubicControl2, to: cubicEnd),
      .close,
    ]

    let metadata = try InlineWritingMaterialCommandMetadataCompiler.compile(
      commands: commands)

    // These values are the reference 8-sample quadratic and 10-sample cubic
    // polyline distances. Keep the tolerance tight enough to catch a sample
    // count or parameterization change while allowing de Casteljau's normal
    // floating-point evaluation order.
    let quadraticLength = 13.038097962874787
    let cubicLength = 17.670054882807865
    let closeLength = 25.495097567963924
    XCTAssertEqual(metadata[1]?.subpathID, 0)
    XCTAssertEqual(metadata[1]?.isClosed, true)
    XCTAssertEqual(metadata[1]?.startDistance ?? -1, 0, accuracy: 0.000_000_000_001)
    XCTAssertEqual(metadata[1]?.endDistance ?? -1, 5, accuracy: 0.000_000_000_001)
    XCTAssertEqual(metadata[2]?.startDistance ?? -1, 5, accuracy: 0.000_000_000_001)
    XCTAssertEqual(
      metadata[2]?.endDistance ?? -1,
      5 + quadraticLength,
      accuracy: 0.000_000_000_001)
    XCTAssertEqual(metadata[3]?.startDistance ?? -1, 18.038097962874787,
                   accuracy: 0.000_000_000_001)
    XCTAssertEqual(
      metadata[3]?.endDistance ?? -1,
      18.038097962874787 + cubicLength,
      accuracy: 0.000_000_000_001)
    XCTAssertEqual(metadata[4]?.startDistance ?? -1, 35.70815284568265,
                   accuracy: 0.000_000_000_001)
    XCTAssertEqual(
      metadata[4]?.endDistance ?? -1,
      35.70815284568265 + closeLength,
      accuracy: 0.000_000_000_001)
    XCTAssertEqual(metadata[4]?.subpathLength ?? -1, 61.20325041364657,
                   accuracy: 0.000_000_000_001)
  }

  func testCommandMetadataUsesFiniteDeCasteljauAndThrowsCheckedOverflow() throws {
    let greatest = Double.greatestFiniteMagnitude
    let extremeStart = try InlinePathPoint(x: greatest, y: 0)
    let extremeControl1 = try InlinePathPoint(x: greatest, y: 1)
    let extremeControl2 = try InlinePathPoint(x: greatest, y: 2)
    let extremeEnd = try InlinePathPoint(x: greatest, y: 3)

    // A Bernstein power-basis sum can round its positive coefficients above
    // one and produce +infinity at a finite sample. De Casteljau stays inside
    // the finite control-point hull and retains the valid three-point length.
    let curveMetadata = try InlineWritingMaterialCommandMetadataCompiler.compile(
      commands: [
        .move(extremeStart),
        .cubic(
          control1: extremeControl1,
          control2: extremeControl2,
          to: extremeEnd),
      ])
    XCTAssertEqual(curveMetadata[1]?.startDistance ?? -1, 0, accuracy: 0.000_000_000_001)
    XCTAssertEqual(curveMetadata[1]?.endDistance ?? -1, 3, accuracy: 0.000_000_000_001)
    XCTAssertEqual(curveMetadata[1]?.subpathLength ?? -1, 3, accuracy: 0.000_000_000_001)

    let negativeExtreme = try InlinePathPoint(x: -greatest, y: 0)
    XCTAssertThrowsError(
      try InlineWritingMaterialCommandMetadataCompiler.compile(
        commands: [.move(negativeExtreme), .line(extremeStart)]
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineWritingMaterialCommandMetadataError,
        .distanceOverflow(commandIndex: 1))
    }
  }

  func testSixteenThousandCubicCommandsStayBounded() throws {
    let commandCount = 16_384
    let pieces = (0..<commandCount).map { index in
      let x = CGFloat(index)
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x, y: 0))
      path.addCurve(
        to: CGPoint(x: x + 1, y: 0),
        control1: CGPoint(x: x + 0.25, y: 1),
        control2: CGPoint(x: x + 0.75, y: -1)
      )
      return InlineWritingMaterialPathPiece(
        path: path,
        subpathID: 0,
        startDistance: Double(index),
        endDistance: Double(index + 1),
        subpathLength: Double(commandCount),
        isClosed: false,
        commandIndex: index
      )
    }
    let start = ContinuousClock.now
    let segments = InlineWritingMaterialSampler.segments(pieces: pieces)
    XCTAssertLessThanOrEqual(
      segments.count,
      InlineWritingMaterialSampler.maximumSegments
    )
    XCTAssertEqual(segments.count, InlineWritingMaterialSampler.maximumSegments)
    XCTAssertEqual(segments.first?.commandIndex, 0)
    XCTAssertEqual(segments.last?.commandIndex, commandCount - 1)
    let terminal = try XCTUnwrap(segments.last)
    XCTAssertEqual(terminal.endDistance, Double(commandCount), accuracy: 0.001)
    XCTAssertEqual(Double(terminal.end.x), Double(commandCount), accuracy: 0.001)
    let units = try (0..<commandCount).map { index in
      try InlineRenderRevealVectorUnit(
        commandIndex: index,
        startTime: Double(index),
        duration: 1
      )
    }
    let activation = try InlineRenderRevealVectorActivation(
      atomID: "cubic-stress",
      assetID: try InlineAssetID(rawValue: "cubic-stress"),
      assetVersion: 0,
      units: units
    )
    let visible = InlineWritingMaterialSampler.visibleSegments(
      segments,
      activation: activation,
      time: activation.duration - 0.5
    )
    let elapsed = start.duration(to: .now)
    XCTAssertLessThanOrEqual(visible.count, segments.count)
    XCTAssertGreaterThan(visible.count, 0)
    print("sampler_16384_cubic_reveal_elapsed=\(elapsed)")
  }

  func testActiveCubicRevealIsOneContinuousSourcePrefix() throws {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addCurve(
      to: CGPoint(x: 100, y: 0),
      control1: CGPoint(x: 33, y: 0),
      control2: CGPoint(x: 67, y: 0)
    )
    let pieces = [InlineWritingMaterialPathPiece(
      path: path,
      subpathID: 0,
      startDistance: 0,
      endDistance: 100,
      subpathLength: 100,
      isClosed: false,
      commandIndex: 0
    )]
    let full = InlineWritingMaterialSampler.segments(pieces: pieces)
    let activation = try InlineRenderRevealVectorActivation(
      atomID: "curve",
      assetID: try InlineAssetID(rawValue: "curve"),
      assetVersion: 0,
      units: [try InlineRenderRevealVectorUnit(commandIndex: 0, startTime: 0, duration: 1)]
    )
    let visible = InlineWritingMaterialSampler.visibleSegments(
      full,
      activation: activation,
      time: 0.5
    )

    XCTAssertGreaterThan(visible.count, 0)
    XCTAssertLessThan(visible.count, full.count)
    XCTAssertEqual(visible.first?.start, full.first?.start)
    let terminal = try XCTUnwrap(visible.last)
    XCTAssertEqual(terminal.endDistance, 50, accuracy: 0.001)
    XCTAssertEqual(Double(terminal.end.x), 50, accuracy: 0.75)
    for pair in zip(visible, visible.dropFirst()) {
      XCTAssertEqual(pair.0.end, pair.1.start)
    }
  }

  func testWholeAssetBudgetKeepsSubpathFairnessAndClosedClosure() {
    func linePiece(
      start: CGPoint,
      end: CGPoint,
      subpathID: Int,
      startDistance: Double,
      endDistance: Double,
      subpathLength: Double,
      isClosed: Bool,
      commandIndex: Int
    ) -> InlineWritingMaterialPathPiece {
      let path = CGMutablePath()
      path.move(to: start)
      path.addLine(to: end)
      return InlineWritingMaterialPathPiece(
        path: path,
        subpathID: subpathID,
        startDistance: startDistance,
        endDistance: endDistance,
        subpathLength: subpathLength,
        isClosed: isClosed,
        commandIndex: commandIndex
      )
    }

    let pieces = [
      linePiece(
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0),
        subpathID: 0, startDistance: 0, endDistance: 10,
        subpathLength: 10, isClosed: false, commandIndex: 0),
      linePiece(
        start: CGPoint(x: 20, y: 0), end: CGPoint(x: 20, y: 1),
        subpathID: 1, startDistance: 0, endDistance: 1,
        subpathLength: 4, isClosed: true, commandIndex: 1),
      linePiece(
        start: CGPoint(x: 20, y: 1), end: CGPoint(x: 19, y: 1),
        subpathID: 1, startDistance: 1, endDistance: 2,
        subpathLength: 4, isClosed: true, commandIndex: 2),
      linePiece(
        start: CGPoint(x: 19, y: 1), end: CGPoint(x: 19, y: 0),
        subpathID: 1, startDistance: 2, endDistance: 3,
        subpathLength: 4, isClosed: true, commandIndex: 3),
      linePiece(
        start: CGPoint(x: 19, y: 0), end: CGPoint(x: 20, y: 0),
        subpathID: 1, startDistance: 3, endDistance: 4,
        subpathLength: 4, isClosed: true, commandIndex: 4),
    ]

    let segments = InlineWritingMaterialSampler.segments(
      pieces: pieces, maximumSegments: 5)
    XCTAssertEqual(segments.count, 5)
    XCTAssertTrue(segments.contains { $0.subpathID == 0 })
    let closed = segments.filter { $0.subpathID == 1 }
    XCTAssertEqual(closed.count, 4)
    XCTAssertEqual(closed.last?.end, closed.first?.start)
    XCTAssertEqual(closed.last?.endDistance ?? -1, 4, accuracy: 0.001)
  }

  func testTooManyDrawablePiecesReturnExplicitEmptyFailure() {
    func linePiece(commandIndex: Int) -> InlineWritingMaterialPathPiece {
      let path = CGMutablePath()
      path.move(to: CGPoint(x: commandIndex, y: 0))
      path.addLine(to: CGPoint(x: commandIndex + 1, y: 0))
      return InlineWritingMaterialPathPiece(
        path: path,
        subpathID: commandIndex,
        startDistance: 0,
        endDistance: 1,
        subpathLength: 1,
        isClosed: false,
        commandIndex: commandIndex
      )
    }

    let pieces = (0..<3).map(linePiece)
    XCTAssertTrue(
      InlineWritingMaterialSampler.segments(pieces: pieces, maximumSegments: 2).isEmpty,
      "the package-internal sampler must not return a partial plan when its command cap cannot reserve every piece"
    )
    let accepted = InlineWritingMaterialSampler.segments(
      pieces: pieces, maximumSegments: 3)
    XCTAssertEqual(accepted.map(\.commandIndex), [0, 1, 2])
  }

  func testClosedCommandPieceRetainsItsDrawableEdgeAtOneSegmentBudget() {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 10, y: 0))
    path.closeSubpath()
    let piece = InlineWritingMaterialPathPiece(
      path: path,
      subpathID: 0,
      startDistance: 10,
      endDistance: 20,
      subpathLength: 20,
      isClosed: true,
      commandIndex: 3
    )

    let segments = InlineWritingMaterialSampler.segments(
      pieces: [piece], maximumSegments: 1)
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments.first?.commandIndex, 3)
    XCTAssertNotEqual(segments.first?.start, segments.first?.end)
  }

  func testManySubpathsAllocateWithinBudgetAndRepresentEveryCommand() {
    let groupCount = 6_000
    let start = ContinuousClock.now
    let pieces = (0..<groupCount).map { index in
      let x = CGFloat(index * 2)
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x, y: 0))
      path.addCurve(
        to: CGPoint(x: x + 1, y: 0),
        control1: CGPoint(x: x + 0.25, y: 1),
        control2: CGPoint(x: x + 0.75, y: -1)
      )
      return InlineWritingMaterialPathPiece(
        path: path,
        subpathID: index,
        startDistance: 0,
        endDistance: 1,
        subpathLength: 1,
        isClosed: false,
        commandIndex: index
      )
    }
    let segments = InlineWritingMaterialSampler.segments(pieces: pieces)
    let elapsed = start.duration(to: .now)
    XCTAssertLessThanOrEqual(
      segments.count,
      InlineWritingMaterialSampler.maximumSegments
    )
    XCTAssertEqual(segments.count, InlineWritingMaterialSampler.maximumSegments)
    XCTAssertEqual(Set(segments.map(\.commandIndex)).count, groupCount)
    XCTAssertEqual(
      Set(segments.map(\.commandIndex)),
      Set(0..<groupCount)
    )
    print("sampler_6000_subpath_elapsed=\(elapsed)")
  }

  func testImbalancedEightThousandShortAndLongCubicsKeepCommandRevealCoverage() throws {
    let shortCount = 8_000
    let longCount = 8_000
    let commandCount = shortCount + longCount
    let shortLength = 1.0
    let longLength = 100.0
    let totalLength = Double(shortCount) * shortLength + Double(longCount) * longLength
    var distance = 0.0
    var pieces: [InlineWritingMaterialPathPiece] = []
    pieces.reserveCapacity(commandCount + 1)

    // A move-only element is intentionally not represented as a piece. This
    // sentinel also verifies that command IDs below describe only drawables.
    let moveOnly = CGMutablePath()
    moveOnly.move(to: CGPoint(x: -10, y: -10))
    pieces.append(InlineWritingMaterialPathPiece(
      path: moveOnly,
      subpathID: -1,
      startDistance: 0,
      endDistance: 0,
      subpathLength: totalLength,
      isClosed: false,
      commandIndex: -1
    ))

    for index in 0..<commandCount {
      let length = index < shortCount ? shortLength : longLength
      let x = CGFloat(distance)
      let y = index.isMultiple(of: 2) ? CGFloat(6) : CGFloat(-6)
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x, y: y))
      path.addCurve(
        to: CGPoint(x: x + CGFloat(length), y: y),
        control1: CGPoint(x: x + CGFloat(length * 0.25), y: y + 1),
        control2: CGPoint(x: x + CGFloat(length * 0.75), y: y - 1)
      )
      pieces.append(InlineWritingMaterialPathPiece(
        path: path,
        subpathID: 0,
        startDistance: distance,
        endDistance: distance + length,
        subpathLength: totalLength,
        isClosed: false,
        commandIndex: index
      ))
      distance += length
    }

    let segments = InlineWritingMaterialSampler.segments(pieces: pieces)
    let cap = InlineWritingMaterialSampler.maximumSegments
    XCTAssertEqual(segments.count, cap)
    XCTAssertEqual(segments.first?.commandIndex, 0)
    XCTAssertEqual(segments.last?.commandIndex, commandCount - 1)
    XCTAssertEqual(Set(segments.map(\.commandIndex)), Set(0..<commandCount))
    XCTAssertTrue(segments.allSatisfy { $0.commandIndex >= 0 })

    let units = try (0..<commandCount).map { index in
      try InlineRenderRevealVectorUnit(
        commandIndex: index,
        startTime: Double(index),
        duration: 1
      )
    }
    let activation = try InlineRenderRevealVectorActivation(
      atomID: "imbalanced-cubic-stress",
      assetID: try InlineAssetID(rawValue: "imbalanced-cubic-stress"),
      assetVersion: 0,
      units: units
    )
    let early = InlineWritingMaterialSampler.visibleSegments(
      segments, activation: activation, time: 0.5)
    XCTAssertEqual(early.map(\.commandIndex), [0])
    let middle = InlineWritingMaterialSampler.visibleSegments(
      segments, activation: activation, time: Double(shortCount) - 0.5)
    XCTAssertEqual(middle.last?.commandIndex, shortCount - 1)
    XCTAssertEqual(middle.count, shortCount)
    let final = InlineWritingMaterialSampler.visibleSegments(
      segments, activation: activation, time: activation.duration - 0.5)
    XCTAssertEqual(final.count, cap)
    XCTAssertEqual(final.last?.commandIndex, commandCount - 1)
  }
}
