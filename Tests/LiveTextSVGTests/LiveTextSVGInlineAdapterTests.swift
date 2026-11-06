import Foundation
import LiveTextLayout
import LiveTextSVG
import XCTest

final class LiveTextSVGInlineAdapterTests: XCTestCase {
  private let metrics = try! InlineMetrics(advance: 10, ascent: 10, descent: 0)

  private func strokeSVG(_ body: String) -> String {
    "<svg width=\"10\" height=\"10\">\(body)</svg>"
  }

  func testOneDocumentProducesOneAssetAndOneVectorAtom() throws {
    let source = strokeSVG(
      "<path d=\"M1 1 L3 1\" stroke=\"black\" fill=\"none\"/>"
        + "<path d=\"M3 1 L5 1\" stroke=\"black\" fill=\"none\"/>"
    )
    let result = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: "line"),
      metrics: metrics,
      version: 1,
      accessibilityLabel: "two-segment line"
    )
    XCTAssertEqual(result.document.atoms.count, 1)
    XCTAssertEqual(result.asset.id.rawValue, "line")
    XCTAssertEqual(result.asset.accessibilityLabel, "two-segment line")
    XCTAssertEqual(result.asset.coveragePath, result.asset.trajectoryPath)
    guard case .vector(let vector) = result.document.atoms[0] else {
      return XCTFail("expected one vector atom")
    }
    XCTAssertEqual(vector.assetID, result.asset.id)
  }

  func testStrokePreservesSourceStyleAndUsesSelfTrajectory() throws {
    let source = strokeSVG(
      "<path d=\"M1 1 L3 1\" stroke=\"black\" stroke-width=\"2\" "
        + "stroke-linecap=\"square\" stroke-linejoin=\"bevel\" fill=\"none\"/>"
    )
    let result = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: "stroke"),
      metrics: metrics,
      version: 1
    )
    guard case .stroke(let paint) = result.asset.coveragePaint else {
      return XCTFail("expected stroke coverage")
    }
    XCTAssertEqual(paint.width, 2)
    XCTAssertEqual(paint.cap, .square)
    XCTAssertEqual(paint.join, .bevel)
    XCTAssertEqual(result.asset.trajectoryStyle, paint)
    XCTAssertEqual(result.asset.coveragePath, result.asset.trajectoryPath)
  }

  func testFillEvenOddRequiresAndUsesInteriorTrajectory() throws {
    let source = """
      <svg width="10" height="10" fill-rule="evenodd">
        <path d="M1 1 L9 1 L9 9 L1 9 Z" fill="black" stroke="none"/>
        <path data-live-text-role="trajectory" d="M2 2 L8 8" fill="none" stroke="black"
          stroke-width="1" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      """
    let result = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: "filled"),
      metrics: metrics,
      version: 2
    )
    guard case .fill(let rule) = result.asset.coveragePaint else {
      return XCTFail("expected fill coverage")
    }
    XCTAssertEqual(rule, .evenOdd)
    XCTAssertNotEqual(result.asset.coveragePath, result.asset.trajectoryPath)
    XCTAssertEqual(result.asset.trajectoryStyle.width, 1)
  }

  func testFillWithoutExplicitTrajectoryFailsTyped() throws {
    let source = strokeSVG("<path d=\"M1 1 L9 1 L9 9 L1 9 Z\" fill=\"black\" stroke=\"none\"/>")
    XCTAssertThrowsError(
      try LiveTextSVGInlineAdapter.convert(
        source: source,
        id: try InlineAssetID(rawValue: "filled"),
        metrics: metrics,
        version: 1)
    ) { error in
      XCTAssertEqual(error as? LiveTextSVGImportError, .missingTrajectory)
    }
  }

  func testMixedCoverageSemanticsAndStylesFailTyped() throws {
    let mixedPaint = strokeSVG(
      "<path d=\"M1 1 L3 1\" stroke=\"black\" fill=\"none\"/>"
        + "<path d=\"M4 4 L8 4 L8 8 L4 8 Z\" fill=\"black\" stroke=\"none\"/>"
    )
    XCTAssertThrowsError(
      try LiveTextSVGImporter.document(from: mixedPaint)
    ) { error in
      guard let importError = error as? LiveTextSVGImportError else {
        return XCTFail("expected importer error")
      }
      guard case .unsupportedSemantic = importError else {
        return XCTFail("expected mixed semantic error")
      }
    }

    let mixedStyle = strokeSVG(
      "<path d=\"M1 1 L3 1\" stroke=\"black\" stroke-width=\"1\" fill=\"none\"/>"
        + "<path d=\"M4 4 L8 4\" stroke=\"black\" stroke-width=\"2\" fill=\"none\"/>"
    )
    XCTAssertThrowsError(try LiveTextSVGImporter.document(from: mixedStyle)) { error in
      guard let importError = error as? LiveTextSVGImportError else {
        return XCTFail("expected importer error")
      }
      guard case .unsupportedSemantic = importError else {
        return XCTFail("expected mixed style error")
      }
    }
  }

  func testTransformAppliesToCoverageAndTrajectoryInOneCoordinateSystem() throws {
    let source = """
      <svg width="10" height="10" viewBox="0 0 5 5">
        <path d="M0.5 0.5 L4.5 0.5 L4.5 4.5 L0.5 4.5 Z" fill="black" stroke="none"/>
        <path data-live-text-role="trajectory" d="M1 1 L4 4" fill="none" stroke="black"
          stroke-width="0.5" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      """
    let result = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: "scaled"),
      metrics: metrics,
      version: 1
    )
    guard case .move(let coverageStart) = result.asset.coveragePath.commands[0],
      case .move(let trajectoryStart) = result.asset.trajectoryPath.commands[0]
    else { return XCTFail("expected paths to begin with move") }
    XCTAssertEqual(coverageStart.x, 1, accuracy: 1e-9)
    XCTAssertEqual(trajectoryStart.x, 2, accuracy: 1e-9)
    XCTAssertEqual(result.asset.trajectoryStyle.width, 1, accuracy: 1e-9)
    XCTAssertEqual(result.asset.coordinateBounds.maxX, 10)
    XCTAssertEqual(result.asset.coordinateBounds.maxY, 10)
  }

  func testInheritedGroupStyleTransformAndMultipleSubpathsRemainInOrder() throws {
    let source = """
      <svg width="10" height="10">
        <g transform="translate(1 2)" stroke="black" fill="none" stroke-width="2"
          stroke-linecap="round" stroke-linejoin="round">
          <path d="M0 0 L1 0 M2 0 L3 0"/>
        </g>
      </svg>
      """
    let result = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: "grouped"),
      metrics: metrics,
      version: 1
    )
    guard case .stroke(let paint) = result.asset.coveragePaint,
      case .move(let first) = result.asset.coveragePath.commands[0],
      case .move(let second) = result.asset.coveragePath.commands[2]
    else { return XCTFail("expected inherited multi-subpath stroke") }
    XCTAssertEqual(paint.width, 2)
    XCTAssertEqual(first.x, 1, accuracy: 1e-9)
    XCTAssertEqual(first.y, 2, accuracy: 1e-9)
    XCTAssertEqual(second.x, 3, accuracy: 1e-9)
    XCTAssertEqual(second.y, 2, accuracy: 1e-9)
  }

  func testNonSquareViewBoxMeetPreservesUniformScaleAndCentersOutput() throws {
    let source = """
      <svg width="20" height="10" viewBox="0 0 10 10">
        <path d="M0 0 L10 0" stroke="black" fill="none" stroke-width="2"/>
      </svg>
      """
    let result = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: "meet"),
      metrics: metrics,
      version: 1
    )
    guard case .move(let start) = result.asset.coveragePath.commands[0],
      case .line(let end) = result.asset.coveragePath.commands[1],
      case .stroke(let paint) = result.asset.coveragePaint
    else { return XCTFail("expected centered meet transform") }
    XCTAssertEqual(start.x, 5, accuracy: 1e-9)
    XCTAssertEqual(end.x, 15, accuracy: 1e-9)
    XCTAssertEqual(paint.width, 2, accuracy: 1e-9)
  }

  func testNonUniformPreserveAspectRatioNoneFailsExplicitly() throws {
    let source = """
      <svg width="10" height="20" viewBox="0 0 10 10" preserveAspectRatio="none">
        <path d="M0 0 L10 0" stroke="black" fill="none"/>
      </svg>
      """
    XCTAssertThrowsError(try LiveTextSVGImporter.document(from: source)) { error in
      XCTAssertEqual(error as? LiveTextSVGImportError, .nonUniformStrokeTransform)
    }
  }

  func testFinalCoverageOutputCommandCapFailsBeforeAdapterPathConstruction() throws {
    let subpathCount = 8_193
    let pathData = String(repeating: "M0 0 L1 1 ", count: subpathCount)
    let source = strokeSVG(
      "<path d=\"\(pathData)\" stroke=\"black\" fill=\"none\"/>"
    )
    let limits = try LiveTextSVGImportLimits(
      maximumPathCommands: 32_768,
      maximumNormalizedSegments: 32_768,
      maximumAttributeBytes: pathData.utf8.count
    )
    let options = LiveTextSVGImportOptions(limits: limits)
    XCTAssertThrowsError(
      try LiveTextSVGInlineAdapter.convert(
        source: source,
        id: try InlineAssetID(rawValue: "bounded"),
        metrics: metrics,
        version: 1,
        options: options)
    ) { error in
      guard
        case .resourceLimitExceeded(
          let resource, let actual, let limit
        ) = error as? LiveTextSVGImportError
      else {
        return XCTFail("expected importer output cap error")
      }
      XCTAssertEqual(resource, "coverage output commands")
      XCTAssertEqual(actual, subpathCount * 2)
      XCTAssertEqual(limit, LiveTextSVGImportedDocument.maximumOutputCommands)
    }
  }

  func testFinalExplicitTrajectoryOutputCommandCapIsIndependent() throws {
    let subpathCount = 8_193
    let trajectoryData = String(repeating: "M0 0 L1 1 ", count: subpathCount)
    let source = strokeSVG(
      "<path d=\"M1 1 L2 2\" stroke=\"black\" fill=\"none\"/>"
        + "<path data-live-text-role=\"trajectory\" d=\"\(trajectoryData)\" "
        + "stroke=\"black\" fill=\"none\"/>"
    )
    let limits = try LiveTextSVGImportLimits(
      maximumPathCommands: 32_768,
      maximumNormalizedSegments: 32_768,
      maximumAttributeBytes: trajectoryData.utf8.count
    )
    XCTAssertThrowsError(
      try LiveTextSVGInlineAdapter.convert(
        source: source,
        id: try InlineAssetID(rawValue: "bounded-trajectory"),
        metrics: metrics,
        version: 1,
        options: LiveTextSVGImportOptions(limits: limits))
    ) { error in
      guard
        case .resourceLimitExceeded(
          let resource, let actual, let limit
        ) = error as? LiveTextSVGImportError
      else {
        return XCTFail("expected trajectory output cap error")
      }
      XCTAssertEqual(resource, "trajectory output commands")
      XCTAssertEqual(actual, subpathCount * 2)
      XCTAssertEqual(limit, LiveTextSVGImportedDocument.maximumOutputCommands)
    }
  }

  func testNonBlackPaintAndUnsupportedRoleFailTyped() throws {
    let colored = strokeSVG(
      "<path d=\"M1 1 L3 1\" stroke=\"red\" fill=\"none\"/>"
    )
    XCTAssertThrowsError(try LiveTextSVGImporter.document(from: colored)) { error in
      guard let importError = error as? LiveTextSVGImportError else {
        return XCTFail("expected importer error")
      }
      guard case .unsupportedPaint = importError else {
        return XCTFail("expected unsupported pigment")
      }
    }
    let role = strokeSVG(
      "<path data-live-text-role=\"guide\" d=\"M1 1 L3 1\" stroke=\"black\" fill=\"none\"/>"
    )
    XCTAssertThrowsError(try LiveTextSVGImporter.document(from: role)) { error in
      guard let importError = error as? LiveTextSVGImportError else {
        return XCTFail("expected importer error")
      }
      guard case .unsupportedSemantic = importError else {
        return XCTFail("expected unsupported role")
      }
    }
  }

  func testInvalidVersionAndResourceLimitRemainExplicit() throws {
    let source = strokeSVG("<path d=\"M1 1 L3 1\" stroke=\"black\" fill=\"none\"/>")
    XCTAssertThrowsError(
      try LiveTextSVGInlineAdapter.convert(
        source: source,
        id: try InlineAssetID(rawValue: "line"),
        metrics: metrics,
        version: -1)
    ) { error in
      XCTAssertEqual(error as? LiveTextSVGInlineAdapterError, .invalidAssetVersion(-1))
    }
    let limits = try LiveTextSVGImportLimits(maximumInputBytes: 1)
    XCTAssertThrowsError(
      try LiveTextSVGInlineAdapter.convert(
        source: source,
        id: try InlineAssetID(rawValue: "line"),
        metrics: metrics,
        version: 1,
        options: LiveTextSVGImportOptions(limits: limits))
    ) { error in
      guard let importError = error as? LiveTextSVGImportError else {
        return XCTFail("expected importer error")
      }
      guard case .resourceLimitExceeded = importError else {
        return XCTFail("expected resource limit error")
      }
    }
  }

  func testImportOptionsCodableRequiresAllFields() throws {
    XCTAssertThrowsError(
      try JSONDecoder().decode(LiveTextSVGImportOptions.self, from: Data("{}".utf8))
    )
  }
}
