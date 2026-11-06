#if os(iOS)
import Foundation
import XCTest
@testable import DustKit

final class SVGContainmentTests: XCTestCase {
  func testPaintElementsCannotContainRenderedChildren() {
    for child in [
      "<rect width='5' height='5'/>",
      "<g><circle r='2'/></g>",
      "<a><path d='M0 0L2 2'/></a>",
    ] {
      let xml = "<svg><rect width='10' height='10'>\(child)</rect></svg>"
      XCTAssertThrowsError(try DustSVGParser.parse(data: Data(xml.utf8)), child)
    }
  }

  func testHiddenPaintElementsCannotActAsContainers() {
    let xml = """
      <svg><rect width='10' height='10' display='none'>
        <rect width='5' height='5'/>
      </rect></svg>
      """
    XCTAssertThrowsError(try DustSVGParser.parse(data: Data(xml.utf8)))
  }

  func testDescriptiveChildrenAndSiblingShapesRemainSupported() throws {
    let xml = """
      <svg><g><rect width='10' height='10'><title>Rectangle</title></rect>
        <a><circle cx='20' cy='5' r='4'/></a></g></svg>
      """
    let document = try DustSVGParser.parse(data: Data(xml.utf8))
    XCTAssertEqual(document.shapes.count, 2)
  }
}
#endif
