#if os(iOS)
import Metal
import UIKit
import XCTest

@testable import DustKit

final class RendererInitializationTests: XCTestCase {
  @MainActor
  func testRendererBuildsPipelinesTextureAndParticleMetadataWhenMetalExists() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal unavailable in this test environment")
    }

    let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { renderer in
      renderer.cgContext.setFillColor(UIColor.white.cgColor)
      renderer.cgContext.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
    }
    let source = try DustSource(image: image)
    let renderer = try DustRenderer()
    try renderer.update(
      raster: source.raster,
      progress: 0.5,
      preset: .softDust,
      configuration: try DustConfiguration(particleSize: 1, maximumParticleCount: 1_000),
      transition: .disintegrate,
      displayScale: 2
    )
  }

  func testParticleMetadataMatchesMetalLayout() {
    XCTAssertEqual(MemoryLayout<DustParticleMetadata>.stride, 8)
    XCTAssertEqual(MemoryLayout<DustParticleMetadata>.alignment, 4)
  }
}
#endif
