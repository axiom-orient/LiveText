import Foundation

/// Deterministic, bounded LRU cache for validated vector assets.
/// The cache retains the newest version under an identity/version key and never
/// silently evicts: insertion reports the evicted asset explicitly.
public final class InlineAssetCache: @unchecked Sendable {
  public static let maximumCapacity = 4_096

  public struct Key: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
      case id, version
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        id: values.decode(InlineAssetID.self, forKey: .id),
        version: values.decode(Int.self, forKey: .version)
      )
    }

    public let id: InlineAssetID
    public let version: Int
    public init(id: InlineAssetID, version: Int) throws {
      guard version >= 0 else {
        throw InlineLayoutError.invalidMetric(name: "assetVersion", value: Double(version))
      }
      self.id = id
      self.version = version
    }

    fileprivate init(validatedAsset asset: InlineSVGAsset) {
      precondition(asset.version >= 0, "InlineSVGAsset version invariant was violated")
      self.id = asset.id
      self.version = asset.version
    }
  }

  public let maximumEntries: Int
  private final class Node {
    let key: Key
    var value: InlineSVGAsset
    weak var previous: Node?
    var next: Node?

    init(key: Key, value: InlineSVGAsset) {
      self.key = key
      self.value = value
    }
  }

  private var nodes: [Key: Node] = [:]
  private var oldest: Node?
  private var newest: Node?
  private var hits = 0
  private var misses = 0
  private var evictions = 0
  private var replacements = 0
  private var removals = 0
  private let lock = NSLock()

  public init(maximumEntries: Int = 128) throws {
    guard maximumEntries > 0 else {
      throw InlineLayoutError.assetCacheLimitExceeded(actual: maximumEntries, limit: 1)
    }
    self.maximumEntries = min(maximumEntries, Self.maximumCapacity)
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return nodes.count
  }

  public var hitCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return hits
  }

  public var missCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return misses
  }

  public var evictionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return evictions
  }

  public var replacementCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return replacements
  }

  public var removalCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return removals
  }

  @discardableResult
  public func insert(_ asset: InlineSVGAsset) throws -> InlineSVGAsset? {
    let key = try Key(id: asset.id, version: asset.version)
    lock.lock()
    defer { lock.unlock() }
    return insertUnlocked(asset, key: key)
  }

  /// Reads a cache entry without changing hit/miss counters or LRU order.
  /// Append adapters use this while building a fallible candidate so a failed
  /// candidate cannot mutate externally observable cache state.
  package func peek(id: InlineAssetID, version: Int) throws -> InlineSVGAsset? {
    let key = try Key(id: id, version: version)
    lock.lock()
    defer { lock.unlock() }
    return nodes[key]?.value
  }

  /// Publishes a validated resolution candidate atomically. All validation
  /// happens before the lock is acquired; the locked section is non-throwing,
  /// so callers can publish only after every fallible operation owned by their
  /// candidate has succeeded, without a partial cache transition.
  package func publish(
    assets: [InlineSVGAsset],
    hits: [Key] = [],
    misses: [Key] = []
  ) {
    // Validate and key the complete batch before acquiring the lock. The
    // locked section below therefore cannot discover an invalid asset halfway
    // through and leave a partially published batch.
    var keyedAssets: [(Key, InlineSVGAsset)] = []
    keyedAssets.reserveCapacity(assets.count)
    for asset in assets {
      keyedAssets.append((Key(validatedAsset: asset), asset))
    }
    lock.lock()
    defer { lock.unlock() }
    for key in hits {
      guard let node = nodes[key] else { continue }
      self.hits += 1
      moveToNewest(node)
    }
    for _ in misses {
      self.misses += 1
    }
    for (key, asset) in keyedAssets {
      _ = insertUnlocked(asset, key: key)
    }
  }

  public func value(for id: InlineAssetID, version: Int) throws -> InlineSVGAsset? {
    let key = try Key(id: id, version: version)
    lock.lock()
    defer { lock.unlock() }
    guard let node = nodes[key] else {
      misses += 1
      return nil
    }
    hits += 1
    moveToNewest(node)
    return node.value
  }

  @discardableResult
  public func remove(id: InlineAssetID, version: Int) throws -> InlineSVGAsset? {
    let key = try Key(id: id, version: version)
    lock.lock()
    defer { lock.unlock() }
    guard let node = nodes.removeValue(forKey: key) else { return nil }
    unlink(node)
    removals += 1
    return node.value
  }

  public func removeAll() {
    lock.lock()
    removals += nodes.count
    nodes.removeAll(keepingCapacity: true)
    oldest = nil
    newest = nil
    lock.unlock()
  }

  private func appendAsNewest(_ node: Node) {
    node.previous = newest
    node.next = nil
    newest?.next = node
    newest = node
    if oldest == nil { oldest = node }
  }

  private func moveToNewest(_ node: Node) {
    guard newest !== node else { return }
    unlink(node)
    appendAsNewest(node)
  }

  private func unlink(_ node: Node) {
    if let previous = node.previous {
      previous.next = node.next
    } else {
      oldest = node.next
    }
    if let next = node.next {
      next.previous = node.previous
    } else {
      newest = node.previous
    }
    node.previous = nil
    node.next = nil
  }

  private func insertUnlocked(
    _ asset: InlineSVGAsset,
    key: Key
  ) -> InlineSVGAsset? {
    if let node = nodes[key] {
      node.value = asset
      replacements += 1
      moveToNewest(node)
      return nil
    }

    let node = Node(key: key, value: asset)
    nodes[key] = node
    appendAsNewest(node)
    guard nodes.count > maximumEntries, let victim = oldest else { return nil }
    unlink(victim)
    evictions += 1
    nodes.removeValue(forKey: victim.key)
    return victim.value
  }
}
