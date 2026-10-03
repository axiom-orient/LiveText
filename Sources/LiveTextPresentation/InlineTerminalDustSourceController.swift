#if os(iOS)
  import DustKit
  import LiveTextAppleRendering
  import SwiftUI

  @MainActor
  public enum InlineTerminalDustSourceState {
    case idle
    case preparing(requestID: UInt64)
    case ready(DustSource, requestID: UInt64)
    case failed(message: String, requestID: UInt64)

    public var source: DustSource? {
      guard case .ready(let source, _) = self else { return nil }
      return source
    }

    public var errorMessage: String? {
      guard case .failed(let message, _) = self else { return nil }
      return message
    }
  }

  /// Owns the optional terminal raster handoff from a composed SwiftUI surface to DustKit.
  ///
  /// LiveText and any intermediate material/layer effects remain authoritative for layout and
  /// presentation. This controller only snapshots a supplied visual revision once and publishes the
  /// resulting `DustSource` back as state.
  ///
  /// Publication is candidate-first: when a new visual revision is being prepared, an already-ready
  /// source stays authoritative until the replacement snapshot has been fully rasterized and accepted
  /// by DustKit. Cancellation, failure, and stale completion never erase or replace that source.
  @MainActor
  public final class InlineTerminalDustSourceController: ObservableObject {
    @Published public private(set) var state: InlineTerminalDustSourceState = .idle
    @Published public private(set) var isPreparing = false
    @Published public private(set) var lastErrorMessage: String?

    private struct RequestKey: Hashable {
      let revision: AnyHashable
      let width: CGFloat
      let height: CGFloat
      let scale: CGFloat
      let semanticLabel: String?
    }

    private var lastCompletedKey: RequestKey?
    private var activeKey: RequestKey?
    private var currentRequestID: UInt64 = 0
    private var task: Task<Void, Never>?

    public init() {}

    deinit { task?.cancel() }

    public func cancel() {
      task?.cancel()
      task = nil
      activeKey = nil
      isPreparing = false
      if case .preparing = state {
        state = .idle
      }
    }

    public func reset() {
      cancel()
      lastCompletedKey = nil
      lastErrorMessage = nil
      state = .idle
    }

    public func prepare<Content: View>(
      revision: AnyHashable,
      size: CGSize,
      scale: CGFloat = 1,
      semanticLabel: String? = nil,
      debounce: Duration = .milliseconds(120),
      @ViewBuilder content: () -> Content
    ) {
      let key = RequestKey(
        revision: revision,
        width: size.width,
        height: size.height,
        scale: scale,
        semanticLabel: semanticLabel
      )

      if lastCompletedKey == key, state.source != nil {
        // A -> preparing B -> A is a new desired-state decision, not a no-op.
        // Otherwise B can still publish after the caller has returned to A.
        if activeKey != nil { cancel() }
        lastErrorMessage = nil
        return
      }
      // SwiftUI may re-evaluate a view multiple times while the same candidate
      // is debouncing. Restarting that identical request would starve publication.
      if activeKey == key, isPreparing {
        return
      }

      let retainedSource = state.source
      task?.cancel()
      currentRequestID &+= 1
      let requestID = currentRequestID
      activeKey = key
      isPreparing = true
      lastErrorMessage = nil
      if retainedSource == nil {
        state = .preparing(requestID: requestID)
      }
      let erased = AnyView(content())

      task = Task { @MainActor [weak self] in
        if debounce > .zero {
          do {
            try await Task.sleep(for: debounce)
          } catch {
            return
          }
        }
        guard !Task.isCancelled, let self,
          self.currentRequestID == requestID, self.activeKey == key
        else { return }
        do {
          let snapshot = try InlineApplePresentationSnapshotter.snapshot(
            content: erased,
            size: size,
            scale: scale
          )
          let source = try DustSource(
            snapshot: snapshot.image,
            scale: snapshot.scale,
            semanticLabel: semanticLabel
          )
          guard self.currentRequestID == requestID, self.activeKey == key else { return }
          self.lastCompletedKey = key
          self.activeKey = nil
          self.isPreparing = false
          self.lastErrorMessage = nil
          self.state = .ready(source, requestID: requestID)
        } catch is CancellationError {
          // Cancellation is an expected supersession path. The retained source,
          // if any, remains authoritative and no failure is published.
        } catch {
          guard self.currentRequestID == requestID, self.activeKey == key else { return }
          self.activeKey = nil
          self.isPreparing = false
          let message = error.localizedDescription
          self.lastErrorMessage = message
          if retainedSource == nil {
            self.state = .failed(message: message, requestID: requestID)
          }
        }
      }
    }
  }
#endif
