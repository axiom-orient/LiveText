import Foundation

enum CursorValidationResult {
  case endOfText
  case cursor(LayoutCursor)
}

func validateLayoutCursor(
  prepared: PreparedText,
  cursor: LayoutCursor
) throws -> CursorValidationResult {
  guard cursor.segmentIndex >= 0 else {
    throw LiveTextCoreError.invalidCursor(cursor, reason: "segmentIndex must be non-negative")
  }

  guard cursor.graphemeIndex >= 0 else {
    throw LiveTextCoreError.invalidCursor(cursor, reason: "graphemeIndex must be non-negative")
  }

  let segmentCount = prepared.segments.count
  guard cursor.segmentIndex <= segmentCount else {
    throw LiveTextCoreError.invalidCursor(
      cursor,
      reason: "segmentIndex must not exceed prepared segment count \(segmentCount)"
    )
  }

  if cursor.segmentIndex == segmentCount {
    guard cursor.graphemeIndex == 0 else {
      throw LiveTextCoreError.invalidCursor(
        cursor,
        reason: "end-of-text cursor must have graphemeIndex == 0"
      )
    }
    return .endOfText
  }

  guard cursor.graphemeIndex > 0 else {
    return .cursor(cursor)
  }

  guard let breakableAdvances = prepared.segments[cursor.segmentIndex].breakableAdvances else {
    throw LiveTextCoreError.invalidCursor(
      cursor,
      reason: "grapheme cursor requires a breakable segment at segmentIndex \(cursor.segmentIndex)"
    )
  }

  guard cursor.graphemeIndex < breakableAdvances.count else {
    throw LiveTextCoreError.invalidCursor(
      cursor,
      reason: "graphemeIndex must be less than breakable advance count \(breakableAdvances.count)"
    )
  }

  return .cursor(cursor)
}

func validatedCursor(
  prepared: PreparedText,
  cursor: LayoutCursor
) throws -> LayoutCursor? {
  switch try validateLayoutCursor(prepared: prepared, cursor: cursor) {
  case .endOfText:
    return nil
  case .cursor(let cursor):
    return cursor
  }
}

func validateCursorRange(
  prepared: PreparedText,
  start: LayoutCursor,
  end: LayoutCursor
) throws -> (start: LayoutCursor, end: LayoutCursor) {
  let validatedStart =
    try validatedCursor(prepared: prepared, cursor: start)
    ?? LayoutCursor(segmentIndex: prepared.segments.count, graphemeIndex: 0)
  let validatedEnd =
    try validatedCursor(prepared: prepared, cursor: end)
    ?? LayoutCursor(segmentIndex: prepared.segments.count, graphemeIndex: 0)

  guard
    (validatedStart.segmentIndex, validatedStart.graphemeIndex) <= (
      validatedEnd.segmentIndex, validatedEnd.graphemeIndex
    )
  else {
    throw LiveTextCoreError.invalidCursor(
      start,
      reason: "start cursor must not sort after end cursor \(end)"
    )
  }

  return (validatedStart, validatedEnd)
}
