import LiveTextEffects
import XCTest

final class EffectBudgetAllocationTests: XCTestCase {
  func testDenseSourceOrderAndMaterialCapsArePreserved() {
    XCTAssertEqual(WritingMaterialPlan.boundedMarkAllocations(
      requestedCounts: [100, 100, 100], maximumMarks: 10), [3, 3, 4])
    XCTAssertEqual(ColoredPencilFillPlan.boundedHatchAllocations(
      requestedCounts: [100, 100, 100], maximumHatches: 10), [3, 3, 4])
    XCTAssertEqual(WritingMaterialPlan.boundedMarkAllocations(
      requestedCounts: [.max], maximumMarks: .max), [WritingMaterialPlan.maximumMarksPerTarget])
    let pencil = ColoredPencilFillPlan.boundedHatchAllocations(
      requestedCounts: [.max, .max], maximumHatches: .max)
    XCTAssertEqual(pencil, [Int.max / 2, Int.max - Int.max / 2])
  }

  func testEmptyTargetsDoNotConsumeOrRedirectMaterialBudget() {
    for budget in [1, 2, 6, 16, 20] {
      let dense = WritingMaterialPlan.boundedMarkAllocations(
        requestedCounts: [8, 8], maximumMarks: budget)
      let sparse = WritingMaterialPlan.boundedMarkAllocations(
        requestedCounts: [0, 8, 0, 0, 8, 0], maximumMarks: budget)
      XCTAssertEqual(sparse, [0, dense[0], 0, 0, dense[1], 0])
      XCTAssertLessThanOrEqual(sparse.reduce(0, +), budget)
    }
  }

  func testEmptyTargetsDoNotConsumeOrRedirectPencilBudget() {
    for budget in [1, 2, 6, 16, 20] {
      let dense = ColoredPencilFillPlan.boundedHatchAllocations(
        requestedCounts: [8, 8], maximumHatches: budget)
      let sparse = ColoredPencilFillPlan.boundedHatchAllocations(
        requestedCounts: [0, 8, 0, 0, 8, 0], maximumHatches: budget)
      XCTAssertEqual(sparse, [0, dense[0], 0, 0, dense[1], 0])
      XCTAssertLessThanOrEqual(sparse.reduce(0, +), budget)
    }
  }

  func testEmptyAndNonpositiveRequestsRemainEmpty() {
    for budget in [-1, 0, 8] {
      XCTAssertEqual(WritingMaterialPlan.boundedMarkAllocations(
        requestedCounts: [-1, 0, 0], maximumMarks: budget), [0, 0, 0])
      XCTAssertEqual(ColoredPencilFillPlan.boundedHatchAllocations(
        requestedCounts: [-1, 0, 0], maximumHatches: budget), [0, 0, 0])
    }
  }
}
