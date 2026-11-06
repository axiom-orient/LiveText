/// Distributes an admitted budget over positive requests in source order.
/// Empty targets keep their positions in the result without affecting the
/// density or fairness of the visible effect.
func allocateEffectBudget(requests: [Int], budget: Int) -> [Int] {
  var result = Array(repeating: 0, count: requests.count)
  guard budget > 0 else { return result }
  let activeIndices = requests.indices.filter { requests[$0] > 0 }
  guard !activeIndices.isEmpty else { return result }

  if activeIndices.count > budget {
    for slot in 0..<budget {
      let position = (Double(slot) + 0.5) * Double(activeIndices.count) / Double(budget)
      let activeIndex = min(activeIndices.count - 1, Int(position))
      result[activeIndices[activeIndex]] = 1
    }
    return result
  }

  var remaining = budget
  for (ordinal, index) in activeIndices.enumerated() {
    let fairShare = max(1, remaining / (activeIndices.count - ordinal))
    let count = min(requests[index], fairShare)
    result[index] = count
    remaining -= count
  }
  return result
}
