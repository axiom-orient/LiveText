import LiveTextSVG
import XCTest

final class SVGArtworkOpacityTests: XCTestCase {
  private let overlapping = """
    <path d="M1 1 L7 1 L7 7 Z" fill="red"/>
    <path d="M3 3 L9 3 L9 9 Z" fill="blue"/>
    """

  func testContainerOpacityRequiringIsolatedCompositionIsRejected() {
    let sources = [
      "<svg width=\"10\" height=\"10\" opacity=\"0.5\">\(overlapping)</svg>",
      "<svg width=\"10\" height=\"10\"><g opacity=\"0.5\">\(overlapping)</g></svg>",
      "<svg width=\"10\" height=\"10\"><path d=\"M1 1 L8 1 L8 8 Z\" fill=\"red\" stroke=\"blue\" opacity=\"0.5\"/></svg>",
    ]
    for source in sources {
      XCTAssertThrowsError(try LiveTextSVGArtworkImporter.document(from: source)) { error in
        guard case .unsupportedSemantic = error as? LiveTextSVGImportError else {
          return XCTFail("Expected unsupported compositing, got \(error)")
        }
      }
    }
  }

  func testIndependentPaintOpacityRemainsRepresentable() throws {
    let source = """
      <svg width="10" height="10"><g opacity="1">
        <path d="M1 1 L8 1 L8 8 Z" fill="red" stroke="blue" fill-opacity="0.5" stroke-opacity="0.25"/>
      </g></svg>
      """
    let document = try LiveTextSVGArtworkImporter.document(from: source)
    guard case .fillAndStroke(let color, _, let stroke) = document.paths[0].paint else {
      return XCTFail("Expected fill and stroke")
    }
    XCTAssertEqual(color.alpha, 0.5)
    XCTAssertEqual(stroke.color?.alpha, 0.25)
    let single = try LiveTextSVGArtworkImporter.document(from:
      "<svg width=\"10\" height=\"10\"><path d=\"M1 1 L8 1 L8 8 Z\" fill=\"red\" opacity=\"0.5\"/></svg>")
    guard case .fill(let singleColor, _) = single.paths[0].paint else {
      return XCTFail("Expected fill")
    }
    XCTAssertEqual(singleColor.alpha, 0.5)
    let hidden = try LiveTextSVGArtworkImporter.document(from:
      "<svg width=\"10\" height=\"10\"><g opacity=\"0\">\(overlapping)</g></svg>")
    for path in hidden.paths {
      guard case .fill(let color, _) = path.paint else { return XCTFail("Expected fill") }
      XCTAssertEqual(color.alpha, 0)
    }
  }

  func testOpacityAndMiterLimitDoNotAcceptLengthUnits() {
    func source(_ attributes: String) -> String {
      "<svg width=\"10\" height=\"10\"><path d=\"M1 1 L8 1 L8 8 Z\" fill=\"none\" stroke=\"black\" \(attributes)/></svg>"
    }
    XCTAssertNoThrow(try LiveTextSVGArtworkImporter.document(from: source("")))
    XCTAssertNoThrow(try LiveTextSVGImporter.document(from: source("")))
    for attribute in [
      "opacity=\"0.5px\"", "fill-opacity=\"0.5px\"", "stroke-opacity=\"0.5px\"",
      "stroke-miterlimit=\"4px\"", "opacity=\",0.5,\"", "stroke-opacity=\"1,\"",
      "opacity=\"1px\"", "fill-opacity=\"1px\"", "stroke-opacity=\"1px\"",
    ] {
      XCTAssertThrowsError(try LiveTextSVGArtworkImporter.document(from: source(attribute)))
      XCTAssertThrowsError(try LiveTextSVGImporter.document(from: source(attribute)))
    }
  }
}
