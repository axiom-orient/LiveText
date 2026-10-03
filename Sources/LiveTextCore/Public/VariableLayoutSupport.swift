import Foundation

func resolveVariableLayoutStart(
  prepared: PreparedText,
  continuation: VariableLayoutContinuation?
) throws -> (cursor: LayoutCursor, index: Int) {
  guard let continuation else {
    return (LayoutCursor.zero, 0)
  }

  guard continuation.nextIndex >= 0 else {
    throw LiveTextCoreError.invalidFragmentConfiguration(
      "continuation nextIndex must be non-negative"
    )
  }

  switch try validateLayoutCursor(prepared: prepared, cursor: continuation.cursor) {
  case .endOfText:
    return (continuation.cursor, continuation.nextIndex)
  case .cursor(let cursor):
    return (cursor, continuation.nextIndex)
  }
}
