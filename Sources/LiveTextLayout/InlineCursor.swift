import Foundation

/// UTF-16 range associated with one logical source atom.
public struct InlineSourceRange: Sendable, Hashable, Codable {
  public let startUTF16: Int
  public let endUTF16: Int

  public init(startUTF16: Int, endUTF16: Int) throws {
    guard startUTF16 >= 0, endUTF16 >= startUTF16 else {
      throw InlineLayoutError.invalidSourceRange
    }
    self.startUTF16 = startUTF16
    self.endUTF16 = endUTF16
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      startUTF16: values.decode(Int.self, forKey: .startUTF16),
      endUTF16: values.decode(Int.self, forKey: .endUTF16)
    )
  }

  private enum CodingKeys: String, CodingKey { case startUTF16, endUTF16 }

  public var lengthUTF16: Int { endUTF16 - startUTF16 }

  public func validateGraphemeBoundaries(in text: String) throws {
    guard endUTF16 <= text.utf16.count else { throw InlineLayoutError.invalidSourceRange }
    let start = String.Index(utf16Offset: startUTF16, in: text)
    let end = String.Index(utf16Offset: endUTF16, in: text)
    let startIsBoundary =
      start == text.startIndex || start == text.endIndex || text.indices.contains(start)
    let endIsBoundary = end == text.startIndex || end == text.endIndex || text.indices.contains(end)
    guard startIsBoundary, endIsBoundary else {
      throw InlineLayoutError.sourceRangeNotAtGraphemeBoundary(self)
    }
  }
}

/// Logical position in an inline document. The grapheme index is local to the atom.
public struct InlineCursor: Sendable, Hashable, Codable {
  public let atomIndex: Int
  public let graphemeIndex: Int

  public init(atomIndex: Int = 0, graphemeIndex: Int = 0) {
    self.atomIndex = atomIndex
    self.graphemeIndex = graphemeIndex
  }

  public static let zero = InlineCursor()
}
