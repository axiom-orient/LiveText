#if os(iOS)
import XCTest

@testable import DustKit

final class ParticleGridPlannerTests: XCTestCase {
  func testUsesRequestedCellBelowLimit() {
    let grid = DustParticleGridPlanner.makeGrid(
      textureWidth: 120,
      textureHeight: 60,
      requestedCellSize: 2,
      maximumCount: 60_000
    )
    XCTAssertEqual(grid.columns, 60)
    XCTAssertEqual(grid.rows, 30)
    XCTAssertEqual(grid.count, 1_800)
    XCTAssertEqual(grid.cellSize, 2)
  }

  func testNeverExceedsMaximumParticleCount() {
    let grid = DustParticleGridPlanner.makeGrid(
      textureWidth: 4096,
      textureHeight: 4096,
      requestedCellSize: 1,
      maximumCount: 1_000
    )
    XCTAssertLessThanOrEqual(grid.count, 1_000)
    XCTAssertGreaterThan(grid.cellSize, 1)
  }

  func testInvalidInputsCollapseToSafeGrid() {
    let grid = DustParticleGridPlanner.makeGrid(
      textureWidth: 0,
      textureHeight: -1,
      requestedCellSize: 0,
      maximumCount: 0
    )
    XCTAssertEqual(grid.count, 1)
    XCTAssertEqual(grid.cellSize, 1)
  }

  func testSparseMaskUsesOnlyVisibleCells() {
    let width = 100
    let height = 20
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 5..<15 {
      for x in 45..<55 {
        rgba[(y * width + x) * 4 + 3] = 255
      }
    }
    let mask = DustAlphaMask(
      width: width,
      height: height,
      rgba: rgba,
      bytesPerRow: width * 4
    )
    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: mask,
      requestedCellSize: 1,
      maximumCount: 200
    )

    XCTAssertEqual(plan.count, 100)
    XCTAssertEqual(plan.grid.cellSize, 1)
    XCTAssertEqual(plan.particles.map(\.gridIndex), plan.particles.map(\.gridIndex).sorted())
  }

  func testTransparentAreaDoesNotCoarsenVisibleParticles() {
    let width = 1000
    let height = 1000
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 490..<510 {
      for x in 490..<510 {
        rgba[(y * width + x) * 4 + 3] = 255
      }
    }
    let mask = DustAlphaMask(
      width: width,
      height: height,
      rgba: rgba,
      bytesPerRow: width * 4
    )
    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: mask,
      requestedCellSize: 1,
      maximumCount: 500
    )

    XCTAssertEqual(plan.grid.cellSize, 1)
    XCTAssertEqual(plan.count, 400)
  }

  func testPlanRespectsMaximumForDenseContent() {
    let width = 20
    let height = 20
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for pixel in 0..<(width * height) {
      rgba[pixel * 4 + 3] = 255
    }
    let mask = DustAlphaMask(
      width: width,
      height: height,
      rgba: rgba,
      bytesPerRow: width * 4
    )
    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: mask,
      requestedCellSize: 1,
      maximumCount: 100
    )

    XCTAssertTrue(mask.isFullyOpaque)
    XCTAssertLessThanOrEqual(plan.count, 100)
    XCTAssertGreaterThan(plan.grid.cellSize, 1)
    XCTAssertTrue(plan.particles.allSatisfy { $0.edgeFactor == 0 })
  }

  func testEdgeFactorPreservesAntialiasedClassification() {
    var rgba = [UInt8](repeating: 0, count: 2 * 4)
    rgba[3] = 64
    rgba[7] = 255
    let mask = DustAlphaMask(width: 2, height: 1, rgba: rgba, bytesPerRow: 8)
    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: mask,
      requestedCellSize: 1,
      maximumCount: 2
    )

    XCTAssertEqual(plan.count, 2)
    XCTAssertGreaterThan(plan.particles[0].edgeFactor, plan.particles[1].edgeFactor)
    XCTAssertEqual(plan.particles[1].edgeFactor, 0, accuracy: 0.001)
  }
  func testNearlyOpaqueSparseContentCoarsensBeforeMetadataMaterialization() {
    let width = 100
    let height = 100
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    rgba[3] = 0
    let mask = DustAlphaMask(
      width: width,
      height: height,
      rgba: rgba,
      bytesPerRow: width * 4
    )

    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: mask,
      requestedCellSize: 1,
      maximumCount: 100
    )

    XCTAssertFalse(mask.isFullyOpaque)
    XCTAssertLessThanOrEqual(plan.count, 100)
    XCTAssertGreaterThan(plan.grid.cellSize, 1)
  }

  func testSparsePlanCellDoesNotExceedDenseRenderBoundAtMinimumCount() {
    let width = 2
    let height = 6
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    rgba[3] = 0
    let mask = DustAlphaMask(
      width: width,
      height: height,
      rgba: rgba,
      bytesPerRow: width * 4
    )
    let maximumGrid = DustParticleGridPlanner.makeGrid(
      textureWidth: width,
      textureHeight: height,
      requestedCellSize: 1,
      maximumCount: 1
    )

    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: mask,
      requestedCellSize: 1,
      maximumCount: 1
    )

    XCTAssertFalse(mask.isFullyOpaque)
    XCTAssertLessThanOrEqual(plan.count, 1)
    XCTAssertLessThanOrEqual(plan.grid.cellSize, maximumGrid.cellSize)
  }

}
#endif
