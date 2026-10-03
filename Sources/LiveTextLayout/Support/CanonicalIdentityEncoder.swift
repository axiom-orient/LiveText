import Foundation

/// Package-owned deterministic `Encodable` representation for identities.
///
/// The encoding is not a persistence format. It exists only to make revisions
/// and receipt fingerprints independent from Foundation JSON formatting.
struct CanonicalIdentityEncoder {
  enum Failure: Error {
    case missingValue
    case duplicateKey(String)
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let box = CanonicalBox()
    try value.encode(to: CanonicalEncoder(box: box))
    guard let node = box.node else { throw Failure.missingValue }
    var data = Data()
    append(node, to: &data)
    return data
  }

  private static func append(_ node: CanonicalNode, to data: inout Data) {
    switch node {
    case .null:
      data.append(0x00)
    case .bool(let value):
      data.append(value ? 0x02 : 0x01)
    case .signed(let value):
      data.append(0x03)
      appendUInt64(UInt64(bitPattern: value), to: &data)
    case .unsigned(let value):
      data.append(0x04)
      appendUInt64(value, to: &data)
    case .float32(let bits):
      data.append(0x05)
      appendUInt32(bits, to: &data)
    case .float64(let bits):
      data.append(0x06)
      appendUInt64(bits, to: &data)
    case .string(let value):
      data.append(0x07)
      appendBytes(Data(value.utf8), to: &data)
    case .array(let storage):
      data.append(0x08)
      appendUInt64(UInt64(storage.values.count), to: &data)
      for value in storage.values { append(value, to: &data) }
    case .object(let storage):
      data.append(0x09)
      let entries = storage.values.sorted { lhs, rhs in
        lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
      }
      appendUInt64(UInt64(entries.count), to: &data)
      for (key, value) in entries {
        appendBytes(Data(key.utf8), to: &data)
        append(value, to: &data)
      }
    }
  }

  private static func appendBytes(_ bytes: Data, to data: inout Data) {
    appendUInt64(UInt64(bytes.count), to: &data)
    data.append(bytes)
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt64(_ value: UInt64, to data: inout Data) {
    data.append(UInt8((value >> 56) & 0xff))
    data.append(UInt8((value >> 48) & 0xff))
    data.append(UInt8((value >> 40) & 0xff))
    data.append(UInt8((value >> 32) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }
}

private indirect enum CanonicalNode {
  case null
  case bool(Bool)
  case signed(Int64)
  case unsigned(UInt64)
  case float32(UInt32)
  case float64(UInt64)
  case string(String)
  case array(CanonicalArrayStorage)
  case object(CanonicalObjectStorage)
}

private final class CanonicalBox {
  var node: CanonicalNode?
}

private final class CanonicalArrayStorage {
  var values: [CanonicalNode] = []
}

private final class CanonicalObjectStorage {
  var values: [String: CanonicalNode] = [:]
}

private struct CanonicalEncoder: Encoder {
  let box: CanonicalBox
  let codingPath: [CodingKey]
  let userInfo: [CodingUserInfoKey: Any] = [:]

  init(box: CanonicalBox, codingPath: [CodingKey] = []) {
    self.box = box
    self.codingPath = codingPath
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let storage = CanonicalObjectStorage()
    box.node = .object(storage)
    return KeyedEncodingContainer(
      CanonicalKeyedContainer<Key>(storage: storage, codingPath: codingPath)
    )
  }

  func unkeyedContainer() -> UnkeyedEncodingContainer {
    let storage = CanonicalArrayStorage()
    box.node = .array(storage)
    return CanonicalUnkeyedContainer(storage: storage, codingPath: codingPath)
  }

  func singleValueContainer() -> SingleValueEncodingContainer {
    CanonicalSingleValueContainer(box: box, codingPath: codingPath)
  }
}

private func canonicalNode<T: Encodable>(
  _ value: T,
  codingPath: [CodingKey]
) throws -> CanonicalNode {
  let box = CanonicalBox()
  try value.encode(to: CanonicalEncoder(box: box, codingPath: codingPath))
  guard let node = box.node else { throw CanonicalIdentityEncoder.Failure.missingValue }
  return node
}

private struct CanonicalKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let storage: CanonicalObjectStorage
  var codingPath: [CodingKey]

  private func set(_ node: CanonicalNode, for key: Key) throws {
    guard storage.values.updateValue(node, forKey: key.stringValue) == nil else {
      throw CanonicalIdentityEncoder.Failure.duplicateKey(key.stringValue)
    }
  }

  mutating func encodeNil(forKey key: Key) throws { try set(.null, for: key) }
  mutating func encode(_ value: Bool, forKey key: Key) throws { try set(.bool(value), for: key) }
  mutating func encode(_ value: String, forKey key: Key) throws {
    try set(.string(value), for: key)
  }
  mutating func encode(_ value: Double, forKey key: Key) throws {
    try set(.float64(value.bitPattern), for: key)
  }
  mutating func encode(_ value: Float, forKey key: Key) throws {
    try set(.float32(value.bitPattern), for: key)
  }
  mutating func encode(_ value: Int, forKey key: Key) throws {
    try set(.signed(Int64(value)), for: key)
  }
  mutating func encode(_ value: Int8, forKey key: Key) throws {
    try set(.signed(Int64(value)), for: key)
  }
  mutating func encode(_ value: Int16, forKey key: Key) throws {
    try set(.signed(Int64(value)), for: key)
  }
  mutating func encode(_ value: Int32, forKey key: Key) throws {
    try set(.signed(Int64(value)), for: key)
  }
  mutating func encode(_ value: Int64, forKey key: Key) throws { try set(.signed(value), for: key) }
  mutating func encode(_ value: UInt, forKey key: Key) throws {
    try set(.unsigned(UInt64(value)), for: key)
  }
  mutating func encode(_ value: UInt8, forKey key: Key) throws {
    try set(.unsigned(UInt64(value)), for: key)
  }
  mutating func encode(_ value: UInt16, forKey key: Key) throws {
    try set(.unsigned(UInt64(value)), for: key)
  }
  mutating func encode(_ value: UInt32, forKey key: Key) throws {
    try set(.unsigned(UInt64(value)), for: key)
  }
  mutating func encode(_ value: UInt64, forKey key: Key) throws {
    try set(.unsigned(value), for: key)
  }

  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    try set(try canonicalNode(value, codingPath: codingPath + [key]), for: key)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let child = CanonicalObjectStorage()
    // Nested-container calls are generated in a structurally unique position.
    precondition(storage.values.updateValue(.object(child), forKey: key.stringValue) == nil)
    return KeyedEncodingContainer(
      CanonicalKeyedContainer<NestedKey>(storage: child, codingPath: codingPath + [key])
    )
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
    let child = CanonicalArrayStorage()
    precondition(storage.values.updateValue(.array(child), forKey: key.stringValue) == nil)
    return CanonicalUnkeyedContainer(storage: child, codingPath: codingPath + [key])
  }

  mutating func superEncoder() -> Encoder {
    CanonicalEncoder(box: CanonicalBox(), codingPath: codingPath)
  }

  mutating func superEncoder(forKey key: Key) -> Encoder {
    let child = CanonicalBox()
    let parentStorage = storage
    let keyString = key.stringValue
    return CanonicalReferencingEncoder(
      box: child,
      codingPath: codingPath + [key],
      publish: { node in parentStorage.values[keyString] = node }
    )
  }
}

private struct CanonicalUnkeyedContainer: UnkeyedEncodingContainer {
  let storage: CanonicalArrayStorage
  var codingPath: [CodingKey]
  var count: Int { storage.values.count }

  mutating func encodeNil() throws { storage.values.append(.null) }
  mutating func encode(_ value: Bool) throws { storage.values.append(.bool(value)) }
  mutating func encode(_ value: String) throws { storage.values.append(.string(value)) }
  mutating func encode(_ value: Double) throws { storage.values.append(.float64(value.bitPattern)) }
  mutating func encode(_ value: Float) throws { storage.values.append(.float32(value.bitPattern)) }
  mutating func encode(_ value: Int) throws { storage.values.append(.signed(Int64(value))) }
  mutating func encode(_ value: Int8) throws { storage.values.append(.signed(Int64(value))) }
  mutating func encode(_ value: Int16) throws { storage.values.append(.signed(Int64(value))) }
  mutating func encode(_ value: Int32) throws { storage.values.append(.signed(Int64(value))) }
  mutating func encode(_ value: Int64) throws { storage.values.append(.signed(value)) }
  mutating func encode(_ value: UInt) throws { storage.values.append(.unsigned(UInt64(value))) }
  mutating func encode(_ value: UInt8) throws { storage.values.append(.unsigned(UInt64(value))) }
  mutating func encode(_ value: UInt16) throws { storage.values.append(.unsigned(UInt64(value))) }
  mutating func encode(_ value: UInt32) throws { storage.values.append(.unsigned(UInt64(value))) }
  mutating func encode(_ value: UInt64) throws { storage.values.append(.unsigned(value)) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    storage.values.append(try canonicalNode(value, codingPath: codingPath))
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    let child = CanonicalObjectStorage()
    storage.values.append(.object(child))
    return KeyedEncodingContainer(
      CanonicalKeyedContainer<NestedKey>(storage: child, codingPath: codingPath)
    )
  }

  mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
    let child = CanonicalArrayStorage()
    storage.values.append(.array(child))
    return CanonicalUnkeyedContainer(storage: child, codingPath: codingPath)
  }

  mutating func superEncoder() -> Encoder {
    let parentStorage = storage
    let index = parentStorage.values.count
    let child = CanonicalBox()
    return CanonicalReferencingEncoder(
      box: child,
      codingPath: codingPath,
      publish: { node in
        if parentStorage.values.count == index {
          parentStorage.values.append(node)
        } else {
          parentStorage.values[index] = node
        }
      }
    )
  }
}

private struct CanonicalSingleValueContainer: SingleValueEncodingContainer {
  let box: CanonicalBox
  var codingPath: [CodingKey]

  mutating func encodeNil() throws { box.node = .null }
  mutating func encode(_ value: Bool) throws { box.node = .bool(value) }
  mutating func encode(_ value: String) throws { box.node = .string(value) }
  mutating func encode(_ value: Double) throws { box.node = .float64(value.bitPattern) }
  mutating func encode(_ value: Float) throws { box.node = .float32(value.bitPattern) }
  mutating func encode(_ value: Int) throws { box.node = .signed(Int64(value)) }
  mutating func encode(_ value: Int8) throws { box.node = .signed(Int64(value)) }
  mutating func encode(_ value: Int16) throws { box.node = .signed(Int64(value)) }
  mutating func encode(_ value: Int32) throws { box.node = .signed(Int64(value)) }
  mutating func encode(_ value: Int64) throws { box.node = .signed(value) }
  mutating func encode(_ value: UInt) throws { box.node = .unsigned(UInt64(value)) }
  mutating func encode(_ value: UInt8) throws { box.node = .unsigned(UInt64(value)) }
  mutating func encode(_ value: UInt16) throws { box.node = .unsigned(UInt64(value)) }
  mutating func encode(_ value: UInt32) throws { box.node = .unsigned(UInt64(value)) }
  mutating func encode(_ value: UInt64) throws { box.node = .unsigned(value) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    box.node = try canonicalNode(value, codingPath: codingPath)
  }
}

/// Encoder whose finalized child node is published into a parent container.
private final class CanonicalReferencingEncoder: Encoder {
  let box: CanonicalBox
  let codingPath: [CodingKey]
  let userInfo: [CodingUserInfoKey: Any] = [:]
  private let publish: (CanonicalNode) -> Void

  init(box: CanonicalBox, codingPath: [CodingKey], publish: @escaping (CanonicalNode) -> Void) {
    self.box = box
    self.codingPath = codingPath
    self.publish = publish
  }

  deinit {
    if let node = box.node { publish(node) }
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let storage = CanonicalObjectStorage()
    box.node = .object(storage)
    return KeyedEncodingContainer(
      CanonicalKeyedContainer<Key>(storage: storage, codingPath: codingPath)
    )
  }

  func unkeyedContainer() -> UnkeyedEncodingContainer {
    let storage = CanonicalArrayStorage()
    box.node = .array(storage)
    return CanonicalUnkeyedContainer(storage: storage, codingPath: codingPath)
  }

  func singleValueContainer() -> SingleValueEncodingContainer {
    CanonicalSingleValueContainer(box: box, codingPath: codingPath)
  }
}
