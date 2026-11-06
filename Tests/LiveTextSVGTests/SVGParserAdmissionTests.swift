import Foundation
import LiveTextSVG
import XCTest

final class SVGParserAdmissionTests: XCTestCase {
  private let path = "<path d=\"M1 1 L8 1 L8 8 Z\" fill=\"black\"/>"

  func testDeclarationsExternalReferencesAndExecutableContentAreRejected() {
    let sources = [
      "<!DOCTYPE svg [<!ENTITY external SYSTEM 'https://example.invalid/entity'>]><svg width=\"10\" height=\"10\">\(path)</svg>",
      "<svg width=\"10\" height=\"10\"><![CDATA[content]]>\(path)</svg>",
      "<svg width=\"10\" height=\"10\"><script>run()</script>\(path)</svg>",
      "<svg width=\"10\" height=\"10\"><use href=\"https://example.invalid/shape.svg\"/>\(path)</svg>",
      "<svg width=\"10\" height=\"10\" onload=\"run()\">\(path)</svg>",
      "<svg width=\"10\" height=\"10\"><path d=\"M1 1 L8 8\" fill=\"&external;\"/></svg>",
    ]
    for source in sources {
      XCTAssertThrowsError(try LiveTextSVGArtworkImporter.document(from: source))
      XCTAssertThrowsError(try LiveTextSVGImporter.document(from: source))
    }
  }

  func testInputElementAndDepthBudgetsAreAppliedBeforeReturningGeometry() throws {
    let source = "<svg width=\"10\" height=\"10\"><g>\(path)</g></svg>"
    let budgets = [
      try LiveTextSVGImportLimits(maximumInputBytes: source.utf8.count - 1),
      try LiveTextSVGImportLimits(maximumElements: 2),
      try LiveTextSVGImportLimits(maximumDepth: 2),
    ]
    for limits in budgets {
      XCTAssertThrowsError(try LiveTextSVGArtworkImporter.document(
        from: source, options: LiveTextSVGImportOptions(limits: limits))) { error in
        guard case .resourceLimitExceeded = error as? LiveTextSVGImportError else {
          return XCTFail("Expected bounded input rejection, got \(error)")
        }
      }
    }
  }

  func testLengthUnitsRemainValidAndNonfiniteNumbersAreRejected() throws {
    let artwork = try LiveTextSVGArtworkImporter.document(from:
      "<svg width=\"10px\" height=\"10px\">\(path)</svg>")
    XCTAssertEqual(artwork.size, try LiveTextSVGSize(width: 10, height: 10))
    for number in ["1e9999", "NaN", "Infinity"] {
      XCTAssertThrowsError(try LiveTextSVGArtworkImporter.document(from:
        "<svg width=\"10\" height=\"10\"><path d=\"M1 1 L\(number) 8\"/></svg>"))
    }
  }

  func testGeometryElementsCannotContainOtherGeometry() {
    for opening in [
      "path d=\"M1 1 L8 8\"",
      "circle cx=\"5\" cy=\"5\" r=\"3\"",
      "ellipse cx=\"5\" cy=\"5\" rx=\"3\" ry=\"2\"",
      "polyline points=\"1,1 8,1 8,8\"",
      "polygon points=\"1,1 8,1 8,8\"",
    ] {
      let name = opening.split(separator: " ")[0]
      let source = "<svg width=\"10\" height=\"10\"><\(opening)>\(path)</\(name)></svg>"
      XCTAssertThrowsError(try LiveTextSVGArtworkImporter.document(from: source))
      XCTAssertThrowsError(try LiveTextSVGImporter.document(from: source))
    }
  }
}
