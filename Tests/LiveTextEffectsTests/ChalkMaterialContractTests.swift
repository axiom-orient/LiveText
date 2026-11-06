import Foundation
import LiveTextEffects
import XCTest

final class ChalkMaterialContractTests: XCTestCase {
  func testSixChalkStylesShareOneConfigurationContract() throws {
    let presets: [(WritingChalkStyle, WritingChalkConfiguration)] = [
      (.fineLine, .fineLine),
      (.dryBrush, .dryBrush),
      (.powderFill, .powderFill),
      (.diagonalHatch, .diagonalHatch),
      (.crossHatch, .crossHatch),
      (.smudged, .smudged),
    ]
    XCTAssertEqual(WritingChalkStyle.allCases.count, 6)
    for (style, configuration) in presets {
      XCTAssertEqual(configuration.style, style)
      let data = try JSONEncoder().encode(configuration)
      XCTAssertEqual(
        try JSONDecoder().decode(WritingChalkConfiguration.self, from: data), configuration)
    }
  }

  func testHistoricalChalkConfigurationWithoutStyleDecodesAsFineLine() throws {
    let historical = """
      {
        "seed": 844184410571,
        "grainAmount": 0.58,
        "erosionAmount": 0.16,
        "grainScale": 3.5,
        "edgeRoughness": 0.14,
        "textureStyle": "fineGrain"
      }
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(WritingChalkConfiguration.self, from: historical)
    XCTAssertEqual(decoded.style, .fineLine)
    XCTAssertEqual(decoded.textureStyle, .fineGrain)
  }

  func testWithStylePreservesStrengthAndSubstrate() {
    let source = WritingChalkConfiguration.legible
    let changed = source.withStyle(.crossHatch)
    XCTAssertEqual(changed.style, .crossHatch)
    XCTAssertEqual(changed.seed, source.seed)
    XCTAssertEqual(changed.grainAmount, source.grainAmount)
    XCTAssertEqual(changed.erosionAmount, source.erosionAmount)
    XCTAssertEqual(changed.grainScale, source.grainScale)
    XCTAssertEqual(changed.edgeRoughness, source.edgeRoughness)
    XCTAssertEqual(changed.textureStyle, source.textureStyle)
  }

  func testChalkMaterialSeedIncludesTopologyAndSubstrateIdentity() throws {
    let fine = WritingMaterial.chalk(
      try WritingChalkConfiguration(textureStyle: .fineGrain, style: .fineLine))
    let dry = WritingMaterial.chalk(
      try WritingChalkConfiguration(textureStyle: .fineGrain, style: .dryBrush))
    let photo = WritingMaterial.chalk(
      try WritingChalkConfiguration(textureStyle: .photographic, style: .fineLine))
    XCTAssertNotEqual(fine.seed, dry.seed)
    XCTAssertNotEqual(fine.seed, photo.seed)
  }
}
