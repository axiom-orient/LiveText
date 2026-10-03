import SwiftUI

extension View {
  @ViewBuilder
  func onChangeCompatible<Value: Equatable>(
    of value: Value,
    perform action: @escaping (Value) -> Void
  ) -> some View {
    if #available(iOS 17, macOS 14, *) {
      onChange(of: value) { _, newValue in
        action(newValue)
      }
    } else {
      onChange(of: value, perform: action)
    }
  }
}
