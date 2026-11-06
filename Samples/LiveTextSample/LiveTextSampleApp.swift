import SwiftUI

@main
struct LiveTextSampleApp: App {
  @State private var model = SampleModel()
  @State private var theme = SampleTheme()

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        SampleRootView()
      }
      .environment(model)
      .environment(theme)
    }
  }
}
