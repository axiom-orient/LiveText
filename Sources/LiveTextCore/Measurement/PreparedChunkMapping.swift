import Foundation

func mapAnalysisChunksToPreparedChunks(
  analysisChunks: [AnalysisChunk],
  preparedStartByAnalysisIndex: [Int],
  preparedEndSegmentIndex: Int
) -> [PreparedChunk] {
  var preparedChunks: [PreparedChunk] = []
  preparedChunks.reserveCapacity(analysisChunks.count)

  for chunk in analysisChunks {
    let startSegmentIndex =
      chunk.startSegmentIndex < preparedStartByAnalysisIndex.count
      ? preparedStartByAnalysisIndex[chunk.startSegmentIndex]
      : preparedEndSegmentIndex
    let endSegmentIndex =
      chunk.endSegmentIndex < preparedStartByAnalysisIndex.count
      ? preparedStartByAnalysisIndex[chunk.endSegmentIndex]
      : preparedEndSegmentIndex
    let consumedEndSegmentIndex =
      chunk.consumedEndSegmentIndex < preparedStartByAnalysisIndex.count
      ? preparedStartByAnalysisIndex[chunk.consumedEndSegmentIndex]
      : preparedEndSegmentIndex

    preparedChunks.append(
      PreparedChunk(
        startSegmentIndex: startSegmentIndex,
        endSegmentIndex: endSegmentIndex,
        consumedEndSegmentIndex: consumedEndSegmentIndex
      )
    )
  }

  return preparedChunks
}
