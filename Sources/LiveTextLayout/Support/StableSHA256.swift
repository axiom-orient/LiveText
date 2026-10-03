import Foundation

struct StableSHA256 {
  private static let initialState: [UInt32] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]

  private static let k: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
    0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
    0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
    0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
    0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
    0xc67178f2,
  ]

  private var state = initialState
  private var buffer = [UInt8]()
  private var messageLengthBytes: UInt64 = 0

  init() {
    buffer.reserveCapacity(64)
  }

  mutating func update(data: Data) {
    update(bytes: Array(data))
  }

  mutating func update(bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    messageLengthBytes &+= UInt64(bytes.count)
    var index = 0
    if !buffer.isEmpty {
      let needed = 64 - buffer.count
      let take = min(needed, bytes.count)
      buffer.append(contentsOf: bytes[0..<take])
      index += take
      if buffer.count == 64 {
        compress(buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    while index + 64 <= bytes.count {
      compress(Array(bytes[index..<index + 64]))
      index += 64
    }
    if index < bytes.count {
      buffer.append(contentsOf: bytes[index...])
    }
  }

  mutating func finalize() -> [UInt8] {
    let bitLength = messageLengthBytes &* 8
    buffer.append(0x80)
    if buffer.count > 56 {
      while buffer.count < 64 { buffer.append(0) }
      compress(buffer)
      buffer.removeAll(keepingCapacity: true)
    }
    while buffer.count < 56 { buffer.append(0) }
    buffer.append(contentsOf: [
      UInt8((bitLength >> 56) & 0xff),
      UInt8((bitLength >> 48) & 0xff),
      UInt8((bitLength >> 40) & 0xff),
      UInt8((bitLength >> 32) & 0xff),
      UInt8((bitLength >> 24) & 0xff),
      UInt8((bitLength >> 16) & 0xff),
      UInt8((bitLength >> 8) & 0xff),
      UInt8(bitLength & 0xff),
    ])
    compress(buffer)
    buffer.removeAll(keepingCapacity: true)

    var digest = [UInt8]()
    digest.reserveCapacity(32)
    for word in state {
      digest.append(UInt8((word >> 24) & 0xff))
      digest.append(UInt8((word >> 16) & 0xff))
      digest.append(UInt8((word >> 8) & 0xff))
      digest.append(UInt8(word & 0xff))
    }
    return digest
  }

  static func hash(data: Data) -> [UInt8] {
    var hasher = StableSHA256()
    hasher.update(data: data)
    return hasher.finalize()
  }

  private mutating func compress(_ chunk: [UInt8]) {
    precondition(chunk.count == 64)
    var w = [UInt32](repeating: 0, count: 64)
    for i in 0..<16 {
      let j = i * 4
      w[i] = (UInt32(chunk[j]) << 24) | (UInt32(chunk[j + 1]) << 16) | (UInt32(chunk[j + 2]) << 8) | UInt32(chunk[j + 3])
    }
    for i in 16..<64 {
      w[i] = smallSigma1(w[i - 2]) &+ w[i - 7] &+ smallSigma0(w[i - 15]) &+ w[i - 16]
    }

    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]

    for i in 0..<64 {
      let t1 = h &+ bigSigma1(e) &+ ch(e, f, g) &+ Self.k[i] &+ w[i]
      let t2 = bigSigma0(a) &+ maj(a, b, c)
      h = g
      g = f
      f = e
      e = d &+ t1
      d = c
      c = b
      b = a
      a = t1 &+ t2
    }

    state[0] = state[0] &+ a
    state[1] = state[1] &+ b
    state[2] = state[2] &+ c
    state[3] = state[3] &+ d
    state[4] = state[4] &+ e
    state[5] = state[5] &+ f
    state[6] = state[6] &+ g
    state[7] = state[7] &+ h
  }

  private func rotateRight(_ x: UInt32, by n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 - n))
  }

  private func ch(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
    (x & y) ^ ((~x) & z)
  }

  private func maj(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
    (x & y) ^ (x & z) ^ (y & z)
  }

  private func bigSigma0(_ x: UInt32) -> UInt32 {
    rotateRight(x, by: 2) ^ rotateRight(x, by: 13) ^ rotateRight(x, by: 22)
  }

  private func bigSigma1(_ x: UInt32) -> UInt32 {
    rotateRight(x, by: 6) ^ rotateRight(x, by: 11) ^ rotateRight(x, by: 25)
  }

  private func smallSigma0(_ x: UInt32) -> UInt32 {
    rotateRight(x, by: 7) ^ rotateRight(x, by: 18) ^ (x >> 3)
  }

  private func smallSigma1(_ x: UInt32) -> UInt32 {
    rotateRight(x, by: 17) ^ rotateRight(x, by: 19) ^ (x >> 10)
  }
}
