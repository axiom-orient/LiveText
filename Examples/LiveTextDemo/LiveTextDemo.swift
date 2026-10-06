import AppKit
import ChalkLineEffects
import LiveTextEffects
import LiveTextWritingUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct LiveTextDemo: App {
  init() {
    let exportIndex = CommandLine.arguments.firstIndex(of: "--export")
    let benchmarkIndex = CommandLine.arguments.firstIndex(of: "--benchmark")
    if let index = exportIndex ?? benchmarkIndex {
      do {
        guard CommandLine.arguments.indices.contains(index + 1) else {
          throw DemoExportError.missingExportDirectory
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        if benchmarkIndex != nil { try DemoBenchmark.run(to: directory) }
        else { try DemoExport.exportAll(to: directory) }
        print("Completed real SwiftUI output at \(directory.path)")
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("Export failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }
  }

  var body: some Scene {
    WindowGroup("LiveText 분필 실험실") { DemoStudio() }
      .defaultSize(width: 880, height: 780)
  }
}

@MainActor
private struct DemoStudio: View {
  @StateObject private var model = DemoModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("분필 실험실").font(.title2.bold())
      HStack {
        TextField("쓸 문장", text: $model.text).textFieldStyle(.roundedBorder)
          .accessibilityLabel("쓸 문장")
        Button("적용", action: model.apply).keyboardShortcut(.return, modifiers: [])
      }
      HStack {
        Picker("분필", selection: $model.chalk) {
          ForEach(WritingChalkStyle.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("텍스처", selection: $model.texture) {
          ForEach(WritingChalkTextureStyle.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Slider(value: $model.height, in: 36...120).frame(width: 110)
          .accessibilityLabel("글자 크기")
        Text("\(Int(model.height)) pt").monospacedDigit()
      }
      HStack {
        Picker("동작", selection: $model.animation) {
          Text("쓰기").tag(ChalkWritingAnimation.write)
          Text("앞부터 지우기").tag(ChalkWritingAnimation.eraseForward)
          Text("뒤부터 지우기").tag(ChalkWritingAnimation.eraseReverse)
        }.frame(width: 210)
        Button(model.playing ? "처음으로" : "재생") {
          model.playOrReset()
        }.disabled(model.contentValue == nil)
        Slider(value: $model.progress, in: 0...1).accessibilityLabel("진행률").disabled(model.playing)
        Text(model.playing ? "재생 중" : "\(Int(model.progress * 100))%")
          .monospacedDigit().frame(width: 52)
        Button("PNG 저장", action: save).disabled(model.contentValue == nil || model.playing)
      }
      ScrollView {
        switch model.content {
        case .success(let ready):
          VStack(alignment: .leading, spacing: 16) {
            Text("획 따라 쓰기").font(.headline)
            DemoBoard {
              ChalkWritingText(
                preparation: ready.preparation, style: ready.style, animation: model.animation,
                motion: .uniform, progress: model.playing ? nil : model.progress,
                onCompletion: model.completed)
                .id(model.playbackID)
                .frame(width: 680, height: 240)
            }
            Text("문서 렌더링 · 완성본").font(.headline)
            DemoBoard {
              LiveTextWritingRenderer(
                content: ready.scene.swiftUIContent,
                viewport: ready.scene.viewport, configuration: ready.configuration)
                .frame(width: 680, height: 100)
            }
          }
        case .failure(let error):
          Text("준비 실패: \(String(describing: error))").foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .padding(24)
    .frame(minWidth: 800, minHeight: 700)
  }

  private func save() {
    guard let ready = model.contentValue else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "LiveText.png"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try DemoExport.write(DemoSample(content: ready, progress: model.progress, animation: model.animation), to: url)
      model.status = "저장 완료: \(url.path)"
    } catch { model.status = "저장 실패: \(error)" }
  }
}
