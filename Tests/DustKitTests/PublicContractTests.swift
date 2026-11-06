#if os(iOS)
import UIKit
import XCTest

@testable import DustKit

final class PublicContractTests: XCTestCase {
  func testEmptyTextFailsExplicitly() {
    XCTAssertThrowsError(try DustSource(text: "", font: .systemFont(ofSize: 20)))
  }

  func testEmptyPathFailsExplicitly() {
    XCTAssertThrowsError(try DustSource(path: CGMutablePath()))
  }

  func testEmptyImageFailsExplicitly() {
    XCTAssertThrowsError(try DustSource(image: UIImage()))
  }

  func testSnapshotSourcePreservesAuthoritativeCanvasBounds() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: 10, height: 8),
      format: format
    ).image { renderer in
      renderer.cgContext.setFillColor(UIColor.white.cgColor)
      renderer.cgContext.fill(CGRect(x: 4, y: 3, width: 1, height: 1))
    }
    let cgImage = try XCTUnwrap(image.cgImage)

    let source = try DustSource(
      snapshot: cgImage,
      scale: 1,
      semanticLabel: "authoritative"
    )

    XCTAssertEqual(source.size.width, 10, accuracy: 0.0001)
    XCTAssertEqual(source.size.height, 8, accuracy: 0.0001)
    XCTAssertEqual(source.raster.image.width, 10)
    XCTAssertEqual(source.raster.image.height, 8)
    XCTAssertEqual(source.semanticLabel, "authoritative")
    XCTAssertGreaterThan(source.raster.alphaMask.visiblePixelCount, 0)
  }

  func testSnapshotSourceRejectsInvalidScaleAndEmptyCoverage() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: 4, height: 4),
      format: format
    ).image { _ in }
    let cgImage = try XCTUnwrap(image.cgImage)

    XCTAssertThrowsError(try DustSource(snapshot: cgImage, scale: .nan))
    XCTAssertThrowsError(try DustSource(snapshot: cgImage, scale: 1))
  }

  func testConfigurationRejectsInvalidNumericBounds() {
    XCTAssertThrowsError(try DustConfiguration(distance: -1))
    XCTAssertThrowsError(try DustConfiguration(distance: .nan))
    XCTAssertThrowsError(
      try DustConfiguration(spreadRadians: DustConfiguration.maximumSpreadRadians + 0.1)
    )
    XCTAssertThrowsError(try DustConfiguration(spreadRadians: .nan))
    XCTAssertThrowsError(try DustConfiguration(particleSize: .infinity))
    XCTAssertThrowsError(try DustConfiguration(maximumParticleCount: 0))
    XCTAssertThrowsError(
      try DustConfiguration(
        maximumParticleCount: DustConfiguration.maximumSupportedParticleCount + 1)
    )
  }

  func testConfigurationIsNormalizedOnceAndImmutableByConstruction() throws {
    let configuration = try DustConfiguration(
      direction: .zero,
      distance: 120,
      particleSize: 1.25,
      seed: 7,
      maximumParticleCount: 10_000,
      spreadRadians: .pi / 3
    )
    XCTAssertEqual(configuration.distance, 120)
    XCTAssertEqual(configuration.spreadRadians ?? -1, .pi / 3, accuracy: 0.0001)
    XCTAssertEqual(configuration.particleSize, 1.25)
    XCTAssertEqual(configuration.seed, 7)
    XCTAssertEqual(configuration.maximumParticleCount, 10_000)
  }

  func testZeroDirectionFallsBackToPresetDirection() throws {
    let profile = DustMotionProfile.resolve(
      preset: .softDust,
      configuration: try DustConfiguration(direction: .zero)
    )
    XCTAssertGreaterThan(hypot(profile.direction.dx, profile.direction.dy), 0.99)
  }

  func testExplicitDirectionAlsoOwnsSourceAxis() throws {
    let profile = DustMotionProfile.resolve(
      preset: .softDust,
      configuration: try DustConfiguration(direction: .init(dx: 0, dy: 1))
    )

    XCTAssertEqual(profile.waveDirectionRadians, Float.pi / 2, accuracy: 0.0001)
  }

  func testZeroDirectionKeepsPresetSourceAxisWhenTravelFallsBack() throws {
    let profile = DustMotionProfile.resolve(
      preset: .softDust,
      configuration: try DustConfiguration(direction: .zero)
    )

    XCTAssertEqual(profile.waveDirectionRadians, 0, accuracy: 0.0001)
  }

  func testMotionPaddingOwnsMaximumDistanceVariation() {
    let profile = DustMotionProfile.resolve(
      preset: .softDust,
      configuration: .default
    )
    XCTAssertEqual(profile.maximumDistanceMultiplier, 1.28, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(
      profile.renderPadding(particleExtent: 1),
      ceil(profile.distance * 1.28 + abs(profile.gravity) + profile.flutter)
    )
  }

  func testRadialExpandUsesFullCircleAndAccountsForParticleGrowth() {
    let profile = DustMotionProfile.resolve(
      preset: .radialExpand,
      configuration: .default
    )

    XCTAssertEqual(profile.spreadRadians, .pi * 2, accuracy: 0.0001)
    XCTAssertEqual(profile.distance, 38, accuracy: 0.0001)
    XCTAssertGreaterThan(profile.endScale, 1)
    let expectedMinimumPadding = ceil(
      profile.distance * profile.maximumDistanceMultiplier
        + abs(profile.gravity)
        + profile.flutter
        + 10 * CGFloat(profile.endScale)
        + 1
    )
    XCTAssertGreaterThanOrEqual(
      profile.renderPadding(particleExtent: 10),
      expectedMinimumPadding
    )
  }

  func testConfigurationCanOverridePresetSpreadWithoutChangingPresetMotion() throws {
    let configuration = try DustConfiguration(
      distance: 240,
      spreadRadians: .pi / 2
    )
    let profile = DustMotionProfile.resolve(
      preset: .softDust,
      configuration: configuration
    )

    XCTAssertEqual(profile.distance, 240, accuracy: 0.0001)
    XCTAssertEqual(profile.spreadRadians, .pi / 2, accuracy: 0.0001)
  }

  func testTransitionsReverseMotionAndEndpointOwnership() {
    XCTAssertEqual(
      DustTransition.disintegrate.motionProgress(for: 0.25),
      0.25,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      DustTransition.assemble.motionProgress(for: 0.25),
      0.75,
      accuracy: 0.0001
    )
    XCTAssertTrue(DustTransition.disintegrate.drawsSource(at: 0))
    XCTAssertTrue(DustTransition.disintegrate.drawsParticles(at: 0.5))
    XCTAssertTrue(DustTransition.assemble.drawsParticles(at: 0))
    XCTAssertTrue(DustTransition.assemble.drawsSource(at: 1))
  }

  func testPathStyleRejectsNonFiniteStrokeWidth() {
    XCTAssertThrowsError(try DustPathStyle(stroke: .white, strokeWidth: .nan))
  }

  func testRasterBudgetFailsBeforeHugePathAllocation() throws {
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), transform: nil)
    XCTAssertThrowsError(
      try DustSource(path: path, style: try DustPathStyle(fill: .white), scale: 1)
    )
  }

  func testRenderingErrorsRemainTypedAndDescriptive() {
    let error = DustRenderingError.bufferCreationFailed(operation: "particle metadata")
    XCTAssertTrue(error.localizedDescription.contains("particle metadata"))
  }

  func testGPUExecutionFailurePreservesCause() {
    let error = DustRenderingError.commandExecutionFailed(cause: "device removed")
    XCTAssertTrue(error.localizedDescription.contains("device removed"))
  }
  func testConfigurationRejectsNonFiniteDirectionAndOversizedDistance() {
    XCTAssertThrowsError(
      try DustConfiguration(direction: CGVector(dx: CGFloat.infinity, dy: 0))
    )
    XCTAssertThrowsError(
      try DustConfiguration(distance: DustConfiguration.maximumTravelDistance + 1)
    )
  }

  func testPathStyleRejectsNegativeAndOversizedStrokeWidth() {
    XCTAssertThrowsError(try DustPathStyle(stroke: .white, strokeWidth: -1))
    XCTAssertThrowsError(
      try DustPathStyle(stroke: .white, strokeWidth: DustPathStyle.maximumStrokeWidth + 1)
    )
  }

  func testRasterLimitsRejectNonFiniteOrOversizedScaleBeforeAllocation() {
    XCTAssertThrowsError(
      try DustResourceLimits.validateRaster(
        size: CGSize(width: 100, height: 100),
        scale: .infinity,
        operation: "fixture"
      )
    )
    XCTAssertThrowsError(
      try DustResourceLimits.validateRaster(
        size: CGSize(width: 8192, height: 8192),
        scale: 1,
        operation: "fixture"
      )
    )
  }

  func testLayoutPolicyRoundTripsAsStablePublicContract() throws {
    for policy in DustLayoutPolicy.allCases {
      let data = try JSONEncoder().encode(policy)
      XCTAssertEqual(try JSONDecoder().decode(DustLayoutPolicy.self, from: data), policy)
    }
  }

}
#endif
