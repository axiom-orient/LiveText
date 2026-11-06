import Foundation
import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineAssetCacheTests: XCTestCase {
  func testReplacementAndHitMoveKeysToNewestAndRemoveAllCountsEntries() throws {
    let first = try makeAsset(id: "first", label: "first-v1")
    let replacement = try makeAsset(id: "first", label: "first-v2")
    let second = try makeAsset(id: "second")
    let third = try makeAsset(id: "third")
    let fourth = try makeAsset(id: "fourth")
    let cache = try InlineAssetCache(maximumEntries: 2)

    XCTAssertNil(try cache.insert(first))
    XCTAssertNil(try cache.insert(second))
    XCTAssertNil(try cache.insert(replacement))
    XCTAssertEqual(cache.replacementCount, 1)
    XCTAssertEqual(try cache.insert(third)?.id, second.id)

    XCTAssertEqual(try cache.value(for: replacement.id, version: replacement.version), replacement)
    XCTAssertEqual(try cache.insert(fourth)?.id, third.id)
    XCTAssertEqual(try cache.remove(id: replacement.id, version: replacement.version), replacement)
    XCTAssertEqual(cache.removalCount, 1)
    XCTAssertNil(try cache.remove(id: replacement.id, version: replacement.version))

    cache.removeAll()
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.removalCount, 2)
    cache.removeAll()
    XCTAssertEqual(cache.removalCount, 2)
    XCTAssertThrowsError(try cache.value(for: first.id, version: -1)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .invalidMetric(name: "assetVersion", value: -1)
      )
    }
    XCTAssertThrowsError(try cache.remove(id: first.id, version: -1)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .invalidMetric(name: "assetVersion", value: -1)
      )
    }
  }

  func testFailedResolutionCandidatePreservesCacheStateAndEvictionOrder() throws {
    let first = try makeAsset(id: "first")
    let second = try makeAsset(id: "second")
    let third = try makeAsset(id: "third")
    let missingID = try InlineAssetID(rawValue: "missing")
    let missingMetrics = try InlineMetrics(advance: 1, ascent: 1, descent: 0)
    let document = try InlineDocument(atoms: [
      try .vector(InlineVectorAtom(id: "first-atom", asset: first)),
      try .vector(
        InlineVectorAtom(
          id: "missing-atom",
          assetID: missingID,
          metrics: missingMetrics
        )
      ),
    ])
    let cache = try InlineAssetCache(maximumEntries: 2)
    XCTAssertNil(try cache.insert(first))
    XCTAssertNil(try cache.insert(second))

    let before = CacheState(cache)
    XCTAssertThrowsError(
      try resolveInlineAssets(
        document: document,
        registry: .empty,
        provider: InlineEmptyAssetGeometryProvider(),
        cache: cache
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineAssetResolutionError,
        .missingGeometry(missingID, version: 1)
      )
    }
    XCTAssertEqual(CacheState(cache), before)

    XCTAssertEqual(try cache.insert(third)?.id, first.id)
  }

  func testConcurrentAccessPreservesBoundedCacheAndCounterInvariants() throws {
    let assets = try (0..<16).map { index in
      try makeAsset(id: "concurrent-\(index)")
    }
    let cache = try InlineAssetCache(maximumEntries: 8)
    let failures = FailureCounter()

    DispatchQueue.concurrentPerform(iterations: 8) { worker in
      for iteration in 0..<1_000 {
        let asset = assets[(worker * 1_000 + iteration) % assets.count]
        do {
          switch iteration % 3 {
          case 0:
            _ = try cache.insert(asset)
          case 1:
            _ = try cache.value(for: asset.id, version: asset.version)
          default:
            _ = try cache.remove(id: asset.id, version: asset.version)
          }
        } catch {
          failures.record()
        }
      }
    }

    XCTAssertEqual(failures.count, 0)
    XCTAssertGreaterThanOrEqual(cache.count, 0)
    XCTAssertLessThanOrEqual(cache.count, cache.maximumEntries)
    XCTAssertGreaterThanOrEqual(cache.hitCount, 0)
    XCTAssertGreaterThanOrEqual(cache.missCount, 0)
    XCTAssertGreaterThanOrEqual(cache.evictionCount, 0)
    XCTAssertGreaterThanOrEqual(cache.replacementCount, 0)
    XCTAssertGreaterThanOrEqual(cache.removalCount, 0)

    cache.removeAll()
    for asset in assets.prefix(cache.maximumEntries) {
      XCTAssertNil(try cache.insert(asset))
    }
    XCTAssertEqual(cache.count, cache.maximumEntries)
    XCTAssertEqual(
      try cache.insert(assets[cache.maximumEntries])?.id,
      assets[0].id
    )
  }

  private func makeAsset(id: String, label: String? = nil) throws -> InlineSVGAsset {
    let path = try InlineSVGBridge.parsePath("M0 0 L1 0")
    return try InlineSVGAsset(
      id: try InlineAssetID(rawValue: id),
      metrics: try InlineMetrics(advance: 1, ascent: 1, descent: 0),
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1),
      accessibilityLabel: label
    )
  }
}

private struct CacheState: Equatable {
  let count: Int
  let hitCount: Int
  let missCount: Int
  let evictionCount: Int
  let replacementCount: Int
  let removalCount: Int

  init(_ cache: InlineAssetCache) {
    count = cache.count
    hitCount = cache.hitCount
    missCount = cache.missCount
    evictionCount = cache.evictionCount
    replacementCount = cache.replacementCount
    removalCount = cache.removalCount
  }
}

private final class FailureCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func record() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}
