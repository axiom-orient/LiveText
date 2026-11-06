#if os(iOS)
import Metal
import DustKitResources
import XCTest

@testable import DustKit

final class ShaderLibraryTests: XCTestCase {
  @MainActor
  func testPackageContainsAllShaderEntryPoints() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal unavailable in this test environment")
    }
    let library = try device.makeDefaultLibrary(bundle: DustKitResourceBundle.bundle)
    XCTAssertNotNil(library.makeFunction(name: "dustSourceVertex"))
    XCTAssertNotNil(library.makeFunction(name: "dustSourceFragment"))
    XCTAssertNotNil(library.makeFunction(name: "dustParticleVertex"))
    XCTAssertNotNil(library.makeFunction(name: "dustParticleFragment"))
  }
}
#endif
