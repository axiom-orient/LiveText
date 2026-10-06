import ChalkLineEffects
import Combine
import Foundation
import LiveTextEffects

/// Read input from one live reference at the action boundary. A captured View
/// value can still contain the previous picker selection during a fast apply.
@MainActor
final class DemoModel: ObservableObject {
  @Published var text = "한글 ABC"
  @Published var height = 72.0
  @Published var chalk = WritingChalkStyle.dryBrush
  @Published var texture = WritingChalkTextureStyle.fineGrain
  @Published var animation = ChalkWritingAnimation.write {
    didSet {
      guard animation != oldValue else { return }
      playing = false
      progress = 0
      playbackID = UUID()
    }
  }
  @Published var progress = 1.0
  @Published private(set) var playing = false
  @Published private(set) var playbackID = UUID()
  @Published private(set) var content: Result<DemoContent, Error> = Result { try DemoContent() }
  @Published var status = "텍스트와 재질을 바꾼 뒤 적용하세요."

  var contentValue: DemoContent? {
    if case .success(let value) = content { return value }
    return nil
  }

  func apply() {
    playing = false
    progress = 1
    playbackID = UUID()
    content = Result { try DemoContent(text: text, height: height, chalk: chalk, texture: texture) }
    status = contentValue == nil ? "입력을 확인하세요." : "적용 완료"
  }

  func playOrReset() {
    if playing { playing = false; progress = 0 }
    else { progress = 0; playbackID = UUID(); playing = true }
  }

  func completed() {
    playing = false
    progress = 1
    status = "재생 완료"
  }
}
