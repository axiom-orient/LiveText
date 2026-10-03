import Foundation

/// A finite, layout-space crop used by append renderers.
///
/// Viewports are deliberately explicit values.  They never use an infinite
/// extent as a stand-in for the whole document and a renderer must capture a
/// viewport before it is created.
public struct InlineRenderViewport: Sendable, Hashable, Codable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) throws {
    guard x.isFinite else {
      throw InlineLayoutError.invalidMetric(name: "viewport.x", value: x)
    }
    guard y.isFinite else {
      throw InlineLayoutError.invalidMetric(name: "viewport.y", value: y)
    }
    guard width.isFinite, width >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "viewport.width", value: width)
    }
    guard height.isFinite, height >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "viewport.height", value: height)
    }
    let maxX = x + width
    guard maxX.isFinite else {
      throw InlineLayoutError.invalidMetric(name: "viewport.maxX", value: maxX)
    }
    let maxY = y + height
    guard maxY.isFinite else {
      throw InlineLayoutError.invalidMetric(name: "viewport.maxY", value: maxY)
    }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public func intersects(_ layoutBounds: InlineHitRect) -> Bool {
    guard width > 0, height > 0,
      layoutBounds.width > 0, layoutBounds.height > 0,
      layoutBounds.minX.isFinite, layoutBounds.minY.isFinite,
      layoutBounds.maxX.isFinite, layoutBounds.maxY.isFinite
    else {
      return false
    }
    return layoutBounds.minX < x + width
      && x < layoutBounds.maxX
      && layoutBounds.minY < y + height
      && y < layoutBounds.maxY
  }

  /// Converts a point in the viewport-local coordinate system into
  /// layout-space.  Points on the max edge and every point in a zero-sized
  /// viewport are outside the half-open local rectangle.
  public func layoutPoint(fromLocal localPoint: InlineHitPoint) -> InlineHitPoint? {
    guard width > 0, height > 0,
      localPoint.x >= 0, localPoint.x < width,
      localPoint.y >= 0, localPoint.y < height
    else {
      return nil
    }
    let layoutX = x + localPoint.x
    let layoutY = y + localPoint.y
    precondition(
      layoutX.isFinite && layoutY.isFinite,
      "validated viewport/local point arithmetic must remain finite"
    )
    return InlineHitPoint(validatedX: layoutX, validatedY: layoutY)
  }

  /// Explicit finite viewport for the current public append snapshot.
  public static func wholeLayout(for snapshot: InlineAppendSnapshot) throws
    -> InlineRenderViewport
  {
    try InlineRenderViewport(
      x: 0,
      y: 0,
      width: snapshot.layoutWidth,
      height: snapshot.layoutHeight
    )
  }

  package static func wholeLayout(for projection: InlineAppendProjection) throws
    -> InlineRenderViewport
  {
    try InlineRenderViewport(
      x: 0,
      y: 0,
      width: projection.layoutWidth,
      height: projection.layoutHeight
    )
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(x, forKey: .x)
    try values.encode(y, forKey: .y)
    try values.encode(width, forKey: .width)
    try values.encode(height, forKey: .height)
  }

  private enum CodingKeys: String, CodingKey {
    case x, y, width, height
  }
}

/// Which conservative geometry union is used by a section query.
package enum InlineRenderSectionQueryKind: Sendable, Hashable {
  case paint
  case hit
}

/// Renderer-neutral immutable metadata for one retained layout line.
///
/// Renderers keep their platform paths and hit chunks separately; this value
/// is the only data the persistent index needs.  A section with no bounds is
/// retained by the renderer's ordered collection but is not inserted into the
/// AVL tree.
package struct InlineRenderSectionRecord: Sendable, Hashable {
  public let id: String
  public let lineIndex: Int
  public let paintBounds: InlineHitRect?
  public let hitBounds: InlineHitRect?
  fileprivate let broadPhaseBounds: InlineHitRect?

  public init(
    id: String,
    lineIndex: Int,
    paintBounds: InlineHitRect?,
    hitBounds: InlineHitRect?
  ) throws {
    guard !id.isEmpty, lineIndex >= 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    if let paintBounds { try Self.validate(bounds: paintBounds) }
    if let hitBounds { try Self.validate(bounds: hitBounds) }
    let broadPhaseBounds = try Self.union(paintBounds, hitBounds)
    self.id = id
    self.lineIndex = lineIndex
    self.paintBounds = paintBounds
    self.hitBounds = hitBounds
    self.broadPhaseBounds = broadPhaseBounds
  }

  fileprivate static func validate(bounds: InlineHitRect) throws {
    guard bounds.minX.isFinite, bounds.minY.isFinite,
      bounds.width.isFinite, bounds.width >= 0,
      bounds.height.isFinite, bounds.height >= 0,
      bounds.maxX.isFinite, bounds.maxY.isFinite
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
  }

  package static func union(
    _ lhs: InlineHitRect?, _ rhs: InlineHitRect?
  ) throws -> InlineHitRect? {
    if let lhs { try validate(bounds: lhs) }
    if let rhs { try validate(bounds: rhs) }
    let nonEmptyLHS = lhs.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    let nonEmptyRHS = rhs.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    switch (nonEmptyLHS, nonEmptyRHS) {
    case (nil, nil): return nil
    case (let value?, nil), (nil, let value?):
      return value.width > 0 && value.height > 0 ? value : nil
    case (let lhs?, let rhs?):
      let minX = min(lhs.minX, rhs.minX)
      let minY = min(lhs.minY, rhs.minY)
      let maxX = max(lhs.maxX, rhs.maxX)
      let maxY = max(lhs.maxY, rhs.maxY)
      guard maxX > minX, maxY > minY else { return nil }
      return try InlineHitRect(
        minX: minX, minY: minY, width: maxX - minX, height: maxY - minY)
    }
  }
}

/// Result of a persistent section-tree broad phase.  `nodeVisitCount` counts
/// only committed AVL nodes visited; returned-section enumeration and exact
/// hit-target checks are intentionally separate work.
package struct InlineRenderSectionQuery: Sendable, Hashable {
  public let sections: [InlineRenderSectionRecord]
  public let nodeVisitCount: Int

  public init(sections: [InlineRenderSectionRecord], nodeVisitCount: Int) {
    self.sections = sections
    self.nodeVisitCount = nodeVisitCount
  }
}

/// Persistent height-balanced AVL index for committed line sections.
///
/// Nodes are immutable values.  Inserting a section copies only the search
/// path and rotations; an already-published root is never mutated.  Empty
/// sections remain in the renderer's ordered section collection but are
/// skipped here because they have no broad-phase geometry.
package struct InlineRenderSectionIndex: Sendable, Hashable {
  private indirect enum Node: Sendable, Hashable {
    case value(
      section: InlineRenderSectionRecord,
      left: Node?,
      right: Node?,
      height: Int,
      subtreeMinY: Double,
      subtreeMaxY: Double
    )
  }

  private var root: Node?

  public init() {
    self.root = nil
  }

  public init(sections: [InlineRenderSectionRecord]) throws {
    self.init()
    self = try inserting(sections)
  }

  public func inserting(_ sections: [InlineRenderSectionRecord]) throws
    -> InlineRenderSectionIndex
  {
    guard !sections.isEmpty else { return self }
    var candidate = self
    for section in sections {
      guard section.broadPhaseBounds != nil else { continue }
      candidate.root = try candidate.insert(candidate.root, section: section)
    }
    return candidate
  }

  public func query(
    viewport: InlineRenderViewport,
    kind: InlineRenderSectionQueryKind = .paint
  ) -> InlineRenderSectionQuery {
    guard viewport.width > 0, viewport.height > 0 else {
      return InlineRenderSectionQuery(sections: [], nodeVisitCount: 0)
    }
    let minX = viewport.x
    let maxX = viewport.x + viewport.width
    let minY = viewport.y
    let maxY = viewport.y + viewport.height
    var sections: [InlineRenderSectionRecord] = []
    var visits = 0
    collect(
      node: root,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      kind: kind,
      output: &sections,
      visits: &visits
    )
    return InlineRenderSectionQuery(sections: sections, nodeVisitCount: visits)
  }

  public func query(
    point: InlineHitPoint,
    kind: InlineRenderSectionQueryKind = .hit
  ) -> InlineRenderSectionQuery {
    var sections: [InlineRenderSectionRecord] = []
    var visits = 0
    collect(
      node: root,
      point: point,
      kind: kind,
      output: &sections,
      visits: &visits
    )
    return InlineRenderSectionQuery(sections: sections, nodeVisitCount: visits)
  }

  /// Test-only structural evidence for the persistent tree. This does not
  /// participate in paint or hit queries; it checks strict key ordering,
  /// cached height, subtree bounds, and AVL balance without exposing nodes.
  package func validateInvariantsForTesting() -> Bool {
    func validate(
      _ node: Node?,
      lower: InlineRenderSectionRecord?,
      upper: InlineRenderSectionRecord?
    ) -> (height: Int, minY: Double?, maxY: Double?, valid: Bool) {
      guard let node else {
        return (height: 0, minY: nil, maxY: nil, valid: true)
      }
      guard
        case .value(
          let section, let left, let right, let storedHeight, let storedMinY, let storedMaxY
        ) = node,
        let ownBounds = section.broadPhaseBounds,
        lower.map({ compare($0, section) < 0 }) ?? true,
        upper.map({ compare(section, $0) < 0 }) ?? true
      else {
        return (height: 0, minY: nil, maxY: nil, valid: false)
      }
      let leftResult = validate(left, lower: lower, upper: section)
      let rightResult = validate(right, lower: section, upper: upper)
      let expectedHeight = 1 + max(leftResult.height, rightResult.height)
      let expectedMinY = min(
        ownBounds.minY,
        leftResult.minY ?? .infinity,
        rightResult.minY ?? .infinity
      )
      let expectedMaxY = max(
        ownBounds.maxY,
        leftResult.maxY ?? -.infinity,
        rightResult.maxY ?? -.infinity
      )
      let valid =
        leftResult.valid && rightResult.valid
        && abs(leftResult.height - rightResult.height) <= 1
        && storedHeight == expectedHeight
        && storedMinY == expectedMinY
        && storedMaxY == expectedMaxY
      return (
        height: expectedHeight,
        minY: expectedMinY,
        maxY: expectedMaxY,
        valid: valid
      )
    }

    return validate(root, lower: nil, upper: nil).valid
  }

  private func insert(
    _ node: Node?, section: InlineRenderSectionRecord
  ) throws -> Node {
    guard let node else {
      return makeNode(section: section, left: nil, right: nil)
    }
    switch node {
    case .value(let current, let left, let right, _, _, _):
      let comparison = compare(section, current)
      guard comparison != 0 else {
        throw InlineLayoutError.invalidRenderPlan
      }
      if comparison < 0 {
        let nextLeft = try insert(left, section: section)
        return rebalance(makeNode(section: current, left: nextLeft, right: right))
      }
      let nextRight = try insert(right, section: section)
      return rebalance(makeNode(section: current, left: left, right: nextRight))
    }
  }

  private func collect(
    node: Node?,
    minX: Double,
    maxX: Double,
    minY: Double,
    maxY: Double,
    kind: InlineRenderSectionQueryKind,
    output: inout [InlineRenderSectionRecord],
    visits: inout Int
  ) {
    guard let node else { return }
    visits += 1
    switch node {
    case .value(let section, let left, let right, _, let subtreeMinY, let subtreeMaxY):
      guard subtreeMaxY > minY, subtreeMinY < maxY else { return }
      if let left {
        collect(
          node: left,
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          kind: kind,
          output: &output,
          visits: &visits
        )
      }
      if intersects(section, minX: minX, maxX: maxX, minY: minY, maxY: maxY, kind: kind) {
        output.append(section)
      }
      if let right {
        collect(
          node: right,
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          kind: kind,
          output: &output,
          visits: &visits
        )
      }
    }
  }

  private func collect(
    node: Node?,
    point: InlineHitPoint,
    kind: InlineRenderSectionQueryKind,
    output: inout [InlineRenderSectionRecord],
    visits: inout Int
  ) {
    guard let node else { return }
    visits += 1
    switch node {
    case .value(let section, let left, let right, _, let subtreeMinY, let subtreeMaxY):
      guard subtreeMinY <= point.y, point.y < subtreeMaxY else { return }
      if let left {
        collect(node: left, point: point, kind: kind, output: &output, visits: &visits)
      }
      if contains(section, point: point, kind: kind) {
        output.append(section)
      }
      if let right {
        collect(node: right, point: point, kind: kind, output: &output, visits: &visits)
      }
    }
  }

  private func intersects(
    _ section: InlineRenderSectionRecord,
    minX: Double,
    maxX: Double,
    minY: Double,
    maxY: Double,
    kind: InlineRenderSectionQueryKind
  ) -> Bool {
    guard let bounds = bounds(for: section, kind: kind),
      bounds.width > 0, bounds.height > 0
    else { return false }
    return bounds.minX < maxX && minX < bounds.maxX
      && bounds.minY < maxY && minY < bounds.maxY
  }

  private func contains(
    _ section: InlineRenderSectionRecord,
    point: InlineHitPoint,
    kind: InlineRenderSectionQueryKind
  ) -> Bool {
    guard let bounds = bounds(for: section, kind: kind),
      bounds.width > 0, bounds.height > 0
    else { return false }
    return point.x >= bounds.minX && point.x < bounds.maxX
      && point.y >= bounds.minY && point.y < bounds.maxY
  }

  private func bounds(
    for section: InlineRenderSectionRecord,
    kind: InlineRenderSectionQueryKind
  ) -> InlineHitRect? {
    switch kind {
    case .paint: return section.paintBounds
    case .hit: return section.hitBounds
    }
  }

  private func compare(
    _ lhs: InlineRenderSectionRecord,
    _ rhs: InlineRenderSectionRecord
  ) -> Int {
    if let lhsBounds = lhs.broadPhaseBounds, let rhsBounds = rhs.broadPhaseBounds,
      lhsBounds.minY != rhsBounds.minY
    {
      return lhsBounds.minY < rhsBounds.minY ? -1 : 1
    }
    if lhs.lineIndex != rhs.lineIndex {
      return lhs.lineIndex < rhs.lineIndex ? -1 : 1
    }
    if lhs.id == rhs.id { return 0 }
    return lhs.id < rhs.id ? -1 : 1
  }

  private func makeNode(
    section: InlineRenderSectionRecord,
    left: Node?,
    right: Node?
  ) -> Node {
    let leftHeight = height(left)
    let rightHeight = height(right)
    let ownBounds = section.broadPhaseBounds
    let minY = min(
      ownBounds?.minY ?? .infinity,
      minY(left) ?? .infinity,
      minY(right) ?? .infinity
    )
    let maxY = max(
      ownBounds?.maxY ?? -.infinity,
      maxY(left) ?? -.infinity,
      maxY(right) ?? -.infinity
    )
    return .value(
      section: section,
      left: left,
      right: right,
      height: 1 + max(leftHeight, rightHeight),
      subtreeMinY: minY,
      subtreeMaxY: maxY
    )
  }

  private func rebalance(_ node: Node) -> Node {
    guard case .value(let section, let left, let right, _, _, _) = node else {
      return node
    }
    let balance = height(left) - height(right)
    if balance > 1, let left {
      if height(leftRight(left)) > height(leftLeft(left)) {
        let rotatedLeft = rotateLeft(left)
        return rotateRight(makeNode(section: section, left: rotatedLeft, right: right))
      }
      return rotateRight(node)
    }
    if balance < -1, let right {
      if height(rightLeft(right)) > height(rightRight(right)) {
        let rotatedRight = rotateRight(right)
        return rotateLeft(makeNode(section: section, left: left, right: rotatedRight))
      }
      return rotateLeft(node)
    }
    return node
  }

  private func rotateLeft(_ node: Node) -> Node {
    guard case .value(let section, let left, let right, _, _, _) = node,
      let right,
      case .value(let pivot, let pivotLeft, let pivotRight, _, _, _) = right
    else { return node }
    return makeNode(
      section: pivot,
      left: makeNode(section: section, left: left, right: pivotLeft),
      right: pivotRight
    )
  }

  private func rotateRight(_ node: Node) -> Node {
    guard case .value(let section, let left, let right, _, _, _) = node,
      let left,
      case .value(let pivot, let pivotLeft, let pivotRight, _, _, _) = left
    else { return node }
    return makeNode(
      section: pivot,
      left: pivotLeft,
      right: makeNode(section: section, left: pivotRight, right: right)
    )
  }

  private func height(_ node: Node?) -> Int {
    guard let node else { return 0 }
    if case .value(_, _, _, let height, _, _) = node { return height }
    return 0
  }

  private func minY(_ node: Node?) -> Double? {
    guard let node else { return nil }
    if case .value(_, _, _, _, let minY, _) = node { return minY }
    return nil
  }

  private func maxY(_ node: Node?) -> Double? {
    guard let node else { return nil }
    if case .value(_, _, _, _, _, let maxY) = node { return maxY }
    return nil
  }

  private func leftLeft(_ node: Node) -> Node? {
    guard case .value(_, let left, _, _, _, _) = node else { return nil }
    return left
  }

  private func leftRight(_ node: Node) -> Node? {
    guard case .value(_, _, let right, _, _, _) = node else { return nil }
    return right
  }

  private func rightLeft(_ node: Node) -> Node? {
    guard case .value(_, let left, _, _, _, _) = node else { return nil }
    return left
  }

  private func rightRight(_ node: Node) -> Node? {
    guard case .value(_, _, let right, _, _, _) = node else { return nil }
    return right
  }
}

/// Validates one append section's line geometry against the prepared atoms it
/// references.  This is deliberately line-local: adapters can reject forged
/// geometry without rebuilding a full prepared-document snapshot.
package func validateInlineRenderLine(
  _ line: InlineLayoutLine,
  preparedAtoms: [PreparedInlineDocument.Atom]
) throws {
  var atomsByID: [String: PreparedInlineDocument.Atom] = [:]
  atomsByID.reserveCapacity(preparedAtoms.count)
  for atom in preparedAtoms {
    let id: String
    switch atom {
    case .text(let text): id = text.atom.id
    case .vector(let vector): id = vector.atom.id
    case .image(let image): id = image.atom.id
    }
    guard atomsByID.updateValue(atom, forKey: id) == nil else {
      throw InlineLayoutError.duplicateIdentifier(id)
    }
  }

  var totalWidth = 0.0
  for positioned in line.atoms {
    guard positioned.lineIndex == line.index,
      let prepared = atomsByID[positioned.atomID]
    else { throw InlineLayoutError.invalidRenderPlan }
    switch (prepared, positioned.kind) {
    case (.text(let text), .text):
      guard positioned.scale == 1,
        let range = positioned.sourceRange,
        range.startUTF16 >= text.sourceRange.startUTF16,
        range.endUTF16 <= text.sourceRange.endUTF16
      else { throw InlineLayoutError.invalidRenderPlan }
      try text.validateSourceRangeBoundaries(range)
      var expectedWidth = 0.0
      for index in InlineSourceRangeSearch.overlappingIndices(
        in: text.shaped.graphemeRanges, with: range)
      {
        expectedWidth += text.shaped.graphemeAdvances[index]
      }
      let expectedHeight = text.metrics.ascent + text.metrics.descent
      guard abs(positioned.width - expectedWidth) <= 1.0 / 64.0,
        abs(positioned.metrics.advance - expectedWidth) <= 1.0 / 64.0,
        abs(positioned.metrics.ascent - text.metrics.ascent) <= 1.0 / 64.0,
        abs(positioned.metrics.descent - text.metrics.descent) <= 1.0 / 64.0,
        abs(positioned.metrics.baselineOffset - text.atom.style.baselineOffset)
          <= 1.0 / 64.0,
        abs(positioned.height - expectedHeight) <= 1.0 / 64.0
      else { throw InlineLayoutError.invalidRenderPlan }
      totalWidth += positioned.width
    case (.vector(let vector), .vector):
      let expectedAdvance = vector.atom.metrics.advance * positioned.scale
      let expectedAscent = vector.atom.metrics.ascent * positioned.scale
      let expectedDescent = vector.atom.metrics.descent * positioned.scale
      let expectedBaselineOffset = vector.atom.metrics.baselineOffset * positioned.scale
      guard positioned.sourceRange == nil,
        abs(positioned.width - expectedAdvance) <= 1.0 / 64.0,
        abs(positioned.metrics.advance - expectedAdvance) <= 1.0 / 64.0,
        abs(positioned.metrics.ascent - expectedAscent) <= 1.0 / 64.0,
        abs(positioned.metrics.descent - expectedDescent) <= 1.0 / 64.0,
        abs(positioned.metrics.baselineOffset - expectedBaselineOffset) <= 1.0 / 64.0,
        abs(positioned.height - expectedAscent - expectedDescent) <= 1.0 / 64.0
      else { throw InlineLayoutError.invalidRenderPlan }
      totalWidth += positioned.width
    case (.image(let image), .image):
      let expectedAdvance = image.atom.metrics.advance
      let expectedAscent = image.atom.metrics.ascent
      let expectedDescent = image.atom.metrics.descent
      let expectedBaselineOffset = image.atom.metrics.baselineOffset
      guard positioned.scale == 1,
        positioned.sourceRange == nil,
        abs(positioned.width - expectedAdvance) <= 1.0 / 64.0,
        abs(positioned.metrics.advance - expectedAdvance) <= 1.0 / 64.0,
        abs(positioned.metrics.ascent - expectedAscent) <= 1.0 / 64.0,
        abs(positioned.metrics.descent - expectedDescent) <= 1.0 / 64.0,
        abs(positioned.metrics.baselineOffset - expectedBaselineOffset) <= 1.0 / 64.0,
        abs(positioned.height - expectedAscent - expectedDescent) <= 1.0 / 64.0
      else { throw InlineLayoutError.invalidRenderPlan }
      totalWidth += positioned.width
    default:
      throw InlineLayoutError.invalidRenderPlan
    }
  }
  guard abs(line.width - totalWidth) <= 1.0 / 64.0 else {
    throw InlineLayoutError.invalidRenderPlan
  }
}
