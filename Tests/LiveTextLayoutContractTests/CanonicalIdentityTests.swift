import Foundation
import XCTest

@testable import LiveTextLayout

final class CanonicalIdentityTests: XCTestCase {
  private struct Fixture: Encodable {
    let optional: String?
    let parts: [String]
    let count: UInt64
    let value: Double
  }

  func testCanonicalIdentityDistinguishesNilEmptyAndFramingAmbiguity() throws {
    let nilValue = try CanonicalIdentityEncoder.encode(
      Fixture(optional: nil, parts: ["ab", "c"], count: 1, value: -0.0)
    )
    let emptyValue = try CanonicalIdentityEncoder.encode(
      Fixture(optional: "", parts: ["ab", "c"], count: 1, value: -0.0)
    )
    let concatenationCollision = try CanonicalIdentityEncoder.encode(
      Fixture(optional: nil, parts: ["a", "bc"], count: 1, value: -0.0)
    )
    let positiveZero = try CanonicalIdentityEncoder.encode(
      Fixture(optional: nil, parts: ["ab", "c"], count: 1, value: 0.0)
    )

    XCTAssertNotEqual(nilValue, emptyValue)
    XCTAssertNotEqual(nilValue, concatenationCollision)
    XCTAssertNotEqual(nilValue, positiveZero)
  }

  func testCanonicalIdentityKnownVectorIsStable() throws {
    let fixture = Fixture(optional: "ko", parts: ["A", "한"], count: 42, value: 1.25)
    let encoded = try CanonicalIdentityEncoder.encode(fixture)
    XCTAssertEqual(
      encoded.map { String(format: "%02x", $0) }.joined(),
      "0900000000000000040000000000000005636f756e7404000000000000002a00000000000000086f7074696f6e616c0700000000000000026b6f0000000000000005706172747308000000000000000207000000000000000141070000000000000003ed959c000000000000000576616c7565063ff4000000000000"
    )
    XCTAssertEqual(
      StableSHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
      "72e82dabcb9787f8338cec29d80c084515216f4c4ae16dd0c806bb5aec02e56e"
    )
  }

  func testCanonicalIdentityIsStableAcrossRepeatedEncoding() throws {
    let fixture = Fixture(optional: "ko", parts: ["A", "한"], count: 42, value: 1.25)
    let first = try CanonicalIdentityEncoder.encode(fixture)
    let second = try CanonicalIdentityEncoder.encode(fixture)
    XCTAssertEqual(first, second)
    XCTAssertEqual(StableSHA256.hash(data: first), StableSHA256.hash(data: second))
  }
}
