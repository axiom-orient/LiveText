#if os(iOS)
import Foundation

struct DustAlphaMask: Sendable {
  let width: Int
  let height: Int
  let alphas: [UInt8]
  let visiblePixelCount: Int
  let isFullyOpaque: Bool

  init(
    width: Int,
    height: Int,
    rgba: [UInt8],
    bytesPerRow: Int,
    alphaThreshold: UInt8 = 1
  ) {
    let safeWidth = max(width, 0)
    let safeHeight = max(height, 0)
    self.width = safeWidth
    self.height = safeHeight

    let (pixelCount, pixelOverflow) = safeWidth.multipliedReportingOverflow(by: safeHeight)
    let (minimumBytesPerRow, rowOverflow) = safeWidth.multipliedReportingOverflow(by: 4)
    let (requiredBytes, byteOverflow) = bytesPerRow.multipliedReportingOverflow(by: safeHeight)
    guard !pixelOverflow, !rowOverflow, !byteOverflow, pixelCount > 0,
      bytesPerRow >= minimumBytesPerRow, rgba.count >= requiredBytes
    else {
      self.alphas = []
      self.visiblePixelCount = 0
      self.isFullyOpaque = false
      return
    }

    var alphas = [UInt8](repeating: 0, count: pixelCount)
    var visible = 0
    var fullyOpaque = true
    for y in 0..<safeHeight {
      let row = y * bytesPerRow
      for x in 0..<safeWidth {
        let alpha = rgba[row + x * 4 + 3]
        let index = y * safeWidth + x
        alphas[index] = alpha
        if alpha > alphaThreshold { visible += 1 }
        if alpha != 255 { fullyOpaque = false }
      }
    }

    self.alphas = alphas
    self.visiblePixelCount = visible
    self.isFullyOpaque = fullyOpaque
  }

  func forEachVisiblePixel(
    alphaThreshold: UInt8 = 1,
    _ body: (Int, UInt8) -> Void
  ) {
    for (index, alpha) in alphas.enumerated() where alpha > alphaThreshold {
      body(index, alpha)
    }
  }
}

struct DustParticleGrid: Equatable, Sendable {
  let columns: Int
  let rows: Int
  let cellSize: Float

  var count: Int { columns * rows }
}

/// Exact layout shared with the Metal `DustParticleMetadata` structure.
/// `gridIndex` preserves deterministic identity even when transparent cells
/// are compacted out of the draw buffer.
struct DustParticleMetadata: Equatable, Sendable {
  let gridIndex: UInt32
  let edgeFactor: Float
}

struct DustParticlePlan: Sendable {
  let grid: DustParticleGrid
  let particles: [DustParticleMetadata]

  var count: Int { particles.count }
}

enum DustParticleGridPlanner {
  static func makeGrid(
    textureWidth: Int,
    textureHeight: Int,
    requestedCellSize: Float,
    maximumCount: Int
  ) -> DustParticleGrid {
    let width = max(textureWidth, 1)
    let height = max(textureHeight, 1)
    let limit = max(maximumCount, 1)
    var cell = finiteCellSize(requestedCellSize)

    var grid = rawGrid(width: width, height: height, cellSize: cell)
    if exceeds(grid, limit: limit) {
      let multiplier = sqrt(Double(grid.count) / Double(limit))
      cell = max(cell * Float(multiplier), 1)
      grid = rawGrid(width: width, height: height, cellSize: cell)
    }
    while exceeds(grid, limit: limit) {
      cell += 0.25
      grid = rawGrid(width: width, height: height, cellSize: cell)
    }
    return grid
  }

  static func makePlan(
    alphaMask: DustAlphaMask,
    requestedCellSize: Float,
    maximumCount: Int
  ) -> DustParticlePlan {
    let limit = max(maximumCount, 1)
    var cell = finiteCellSize(requestedCellSize)
    let maximumGrid = makeGrid(
      textureWidth: alphaMask.width,
      textureHeight: alphaMask.height,
      requestedCellSize: cell,
      maximumCount: limit
    )
    let maximumCellSize = maximumGrid.cellSize

    if alphaMask.isFullyOpaque {
      let particles = (0..<maximumGrid.count).map {
        DustParticleMetadata(gridIndex: UInt32($0), edgeFactor: 0)
      }
      return .init(grid: maximumGrid, particles: particles)
    }

    while true {
      let grid = rawGrid(
        width: max(alphaMask.width, 1),
        height: max(alphaMask.height, 1),
        cellSize: cell
      )
      let maximumAlpha = cellMaximumAlpha(alphaMask: alphaMask, grid: grid)
      let visibleCells = maximumAlpha.reduce(into: 0) { count, alpha in
        if alpha > 1 { count += 1 }
      }
      if visibleCells <= limit {
        return .init(
          grid: grid,
          particles: particleMetadata(maximumAlpha: maximumAlpha)
        )
      }

      let multiplier = sqrt(Double(visibleCells) / Double(limit))
      let candidateCellSize = max(cell * Float(multiplier), cell + 0.25)
      // DustView derives its particle padding from the dense grid. Sparse
      // coarsening must never create a larger particle extent than that
      // render-bound cell, otherwise the Metal quad can exceed the layout
      // padding and be clipped at the edge.
      cell = min(candidateCellSize, maximumCellSize)
    }
  }

  private static func finiteCellSize(_ value: Float) -> Float {
    value.isFinite ? max(value, 1) : 1
  }

  private static func rawGrid(
    width: Int,
    height: Int,
    cellSize: Float
  ) -> DustParticleGrid {
    let cell = finiteCellSize(cellSize)
    return .init(
      columns: max(Int(ceil(Float(max(width, 1)) / cell)), 1),
      rows: max(Int(ceil(Float(max(height, 1)) / cell)), 1),
      cellSize: cell
    )
  }

  private static func exceeds(_ grid: DustParticleGrid, limit: Int) -> Bool {
    grid.rows > 0 && grid.columns > limit / grid.rows
  }

  private static func cellMaximumAlpha(
    alphaMask: DustAlphaMask,
    grid: DustParticleGrid
  ) -> [UInt8] {
    guard alphaMask.visiblePixelCount > 0, !alphaMask.alphas.isEmpty else { return [] }

    var maximumAlpha = [UInt8](repeating: 0, count: grid.count)
    alphaMask.forEachVisiblePixel { pixelIndex, alpha in
      let x = pixelIndex % alphaMask.width
      let y = pixelIndex / alphaMask.width
      let column = min(Int(Float(x) / grid.cellSize), grid.columns - 1)
      let row = min(Int(Float(y) / grid.cellSize), grid.rows - 1)
      let cellIndex = row * grid.columns + column
      if alpha > maximumAlpha[cellIndex] {
        maximumAlpha[cellIndex] = alpha
      }
    }
    return maximumAlpha
  }

  private static func particleMetadata(maximumAlpha: [UInt8]) -> [DustParticleMetadata] {
    var particles: [DustParticleMetadata] = []
    particles.reserveCapacity(
      maximumAlpha.reduce(into: 0) { count, alpha in
        if alpha > 1 { count += 1 }
      })
    for (index, alpha) in maximumAlpha.enumerated() where alpha > 1 {
      particles.append(
        .init(gridIndex: UInt32(index), edgeFactor: edgeFactor(for: alpha))
      )
    }
    return particles
  }

  /// CPU equivalent of `1 - smoothstep(0.32, 0.92, alpha)`.
  private static func edgeFactor(for alpha: UInt8) -> Float {
    let normalized = Float(alpha) / 255
    let t = min(max((normalized - 0.32) / 0.60, 0), 1)
    let smooth = t * t * (3 - 2 * t)
    return 1 - smooth
  }
}
#endif
