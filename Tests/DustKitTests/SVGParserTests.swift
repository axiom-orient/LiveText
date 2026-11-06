#if os(iOS)
import UIKit
import XCTest

@testable import DustKit

final class SVGParserTests: XCTestCase {
  func testBasicVectorDocumentRasterizes() throws {
    let data = Data(
      """
      <svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg">
        <g transform="translate(4 4)" fill="#ffffff">
          <rect x="0" y="0" width="20" height="20" rx="4"/>
          <path d="M24 0 L52 14 L24 28 Z" fill="rgb(255,0,0)"/>
        </g>
      </svg>
      """.utf8
    )
    let source = try DustSource(svgData: data, scale: 2)
    XCTAssertGreaterThan(source.size.width, 0)
    XCTAssertGreaterThan(source.size.height, 0)
  }

  func testViewBoxMapsIntoExplicitViewportWithNone() throws {
    let data = Data(
      """
      <svg width="24" height="12" viewBox="0 0 48 48"
           preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
        <rect x="0" y="0" width="48" height="48" fill="#fff"/>
      </svg>
      """.utf8
    )
    let source = try DustSource(svgData: data, scale: 2)
    XCTAssertEqual(source.size.width, 24, accuracy: 0.6)
    XCTAssertEqual(source.size.height, 12, accuracy: 0.6)
  }

  func testDefaultPreserveAspectRatioIsXMidYMidMeet() throws {
    let document = try DustSVGParser.parse(
      data: Data(
        """
        <svg width="24" height="24" viewBox="0 0 48 24" xmlns="http://www.w3.org/2000/svg">
          <rect width="48" height="24" fill="#fff"/>
        </svg>
        """.utf8
      )
    )
    XCTAssertEqual(document.preserveAspectRatio, .default)
    let transform = document.preserveAspectRatio.transform(
      viewBox: CGRect(x: 0, y: 0, width: 48, height: 24),
      viewport: CGSize(width: 24, height: 24)
    )
    XCTAssertEqual(transform.a, 0.5, accuracy: 0.0001)
    XCTAssertEqual(transform.d, 0.5, accuracy: 0.0001)
    XCTAssertEqual(transform.tx, 0, accuracy: 0.0001)
    XCTAssertEqual(transform.ty, 6, accuracy: 0.0001)
  }

  func testUnsupportedGradientFailsExplicitly() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10" fill="url(#g)"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testUnknownVisualAttributeFailsClosed() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10" mix-blend-mode="multiply"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testUnknownInlineStylePropertyFailsClosed() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10" style="fill:#fff;mix-blend-mode:multiply"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testUnsupportedLengthUnitFailsInsteadOfTreatingPointsAsPixels() {
    let data = Data(
      """
      <svg width="24pt" height="24pt" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <rect width="24" height="24"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testPathSourceRasterizes() throws {
    let path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 30, height: 30)).cgPath
    let source = try DustSource(path: path, style: try DustPathStyle(fill: .white), scale: 2)
    XCTAssertGreaterThan(source.size.width, 0)
  }

  func testTextSourceRasterizesAndPreservesSemanticLabel() throws {
    let source = try DustSource(
      text: "Dust",
      font: .systemFont(ofSize: 30, weight: .semibold),
      color: .white,
      scale: 2
    )
    XCTAssertGreaterThan(source.size.width, 0)
    XCTAssertGreaterThan(source.size.height, 0)
    XCTAssertEqual(source.semanticLabel, "Dust")
  }

  func testIgnoredDefsDoesNotCorruptSiblingParsing() throws {
    let data = Data(
      """
      <svg viewBox="0 0 20 20" xmlns="http://www.w3.org/2000/svg">
        <defs><path id="unused" d="M0 0 L5 0 L5 5 Z"/></defs>
        <rect x="4" y="4" width="8" height="8" fill="#fff"/>
      </svg>
      """.utf8
    )
    let source = try DustSource(svgData: data, scale: 2)
    XCTAssertGreaterThan(source.size.width, 0)
    XCTAssertGreaterThan(source.size.height, 0)
  }

  func testUnsupportedGroupOpacityFailsRatherThanRenderingIncorrectly() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <g opacity="0.5"><rect width="10" height="10"/></g>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testPreserveAspectRatioWithoutViewBoxFails() {
    let data = Data(
      """
      <svg width="24" height="24" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
        <rect width="24" height="24"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }
  func testDeepIgnoredDefsDoesNotCorruptSiblingParsing() throws {
    let data = Data(
      """
      <svg viewBox="0 0 20 20" xmlns="http://www.w3.org/2000/svg">
        <defs><g><path id="unused" d="M0 0 L5 0 L5 5 Z"/></g></defs>
        <rect x="4" y="4" width="8" height="8" fill="#fff"/>
      </svg>
      """.utf8
    )
    let source = try DustSource(svgData: data, scale: 2)
    XCTAssertGreaterThan(source.size.width, 0)
  }

  func testOversizedViewportFailsBeforeRasterAllocation() {
    let data = Data(
      """
      <svg width="10000" height="10000" viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10" fill="#fff"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data, scale: 1))
  }

  func testOversizedSVGInputFailsBeforeParsing() {
    let data = Data(repeating: 0x20, count: DustResourceLimits.maximumSVGBytes + 1)
    XCTAssertThrowsError(try DustSource(svgData: data, scale: 1))
  }

  func testVisibilityVisibleOverridesInheritedVisibilityHidden() throws {
    let document = try DustSVGParser.parse(
      data: Data(
        """
        <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
          <g visibility="hidden"><rect width="10" height="10" visibility="visible"/></g>
        </svg>
        """.utf8
      )
    )
    XCTAssertEqual(document.shapes.count, 1)
    XCTAssertFalse(document.shapes[0].hidden)
  }

  func testDisplayNoneCannotBeOverriddenByDescendantInline() {
    XCTAssertThrowsError(
      try DustSVGParser.parse(
        data: Data(
          """
          <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
            <g display="none"><rect width="10" height="10" display="inline"/></g>
          </svg>
          """.utf8
        )
      )
    )
  }

  func testDocumentRootMustBeSVG() {
    let data = Data(
      """
      <g xmlns="http://www.w3.org/2000/svg">
        <svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>
      </g>
      """.utf8
    )
    XCTAssertThrowsError(try DustSVGParser.parse(data: data))
  }

  func testNestedSVGFailsClosed() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <svg viewBox="0 0 5 5"><rect width="5" height="5"/></svg>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSVGParser.parse(data: data))
  }

  func testDisplayInlineIsAccepted() throws {
    let document = try DustSVGParser.parse(
      data: Data(
        """
        <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
          <rect width="10" height="10" display="inline"/>
        </svg>
        """.utf8
      )
    )
    XCTAssertEqual(document.shapes.count, 1)
  }

  func testRootTransformFailsClosed() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" transform="scale(2)" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testCSSStyleTransformFailsClosed() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10" style="transform:scale(2);fill:#fff"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testNegativeStrokeWidthFailsExplicitly() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <path d="M0 0 L10 10" stroke="#fff" stroke-width="-1"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testSlicePreserveAspectRatioUsesMaximumUniformScale() throws {
    let value = try DustSVGParser.parse(
      data: Data(
        """
        <svg width="24" height="24" viewBox="0 0 48 24"
             preserveAspectRatio="xMidYMid slice" xmlns="http://www.w3.org/2000/svg">
          <rect width="48" height="24" fill="#fff"/>
        </svg>
        """.utf8
      )
    ).preserveAspectRatio
    let transform = value.transform(
      viewBox: CGRect(x: 0, y: 0, width: 48, height: 24),
      viewport: CGSize(width: 24, height: 24)
    )
    XCTAssertEqual(transform.a, 1, accuracy: 0.0001)
    XCTAssertEqual(transform.d, 1, accuracy: 0.0001)
    XCTAssertEqual(transform.tx, -12, accuracy: 0.0001)
    XCTAssertEqual(transform.ty, 0, accuracy: 0.0001)
  }

  func testExternalEntityAndDoctypeFailClosed() {
    let data = Data(
      """
      <!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <text>&xxe;</text>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testSVGDefaultMiterLimitMatchesSpecification() {
    XCTAssertEqual(DustSVGShape.defaultMiterLimit, 4)
  }

  func testOversizedStrokeWidthFailsBeforeCoreGraphicsDraw() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <path d="M0 0 L10 10" stroke="#fff" stroke-width="5000"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

  func testNonFiniteTransformResultFailsClosed() {
    let data = Data(
      """
      <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
        <rect width="10" height="10" transform="scale(1e308)"/>
      </svg>
      """.utf8
    )
    XCTAssertThrowsError(try DustSource(svgData: data))
  }

}
#endif
