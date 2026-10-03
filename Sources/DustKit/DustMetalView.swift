#if os(iOS)
import CoreGraphics
import Dispatch
import MetalKit
import QuartzCore
import SwiftUI
import os

@MainActor
struct DustMetalView: UIViewRepresentable {
  let raster: DustRaster
  let progress: Float
  let preset: DustPreset
  let configuration: DustConfiguration
  let transition: DustTransition
  let onFailure: (@MainActor (DustRenderingError) -> Void)?
  let onPresented: (@MainActor () -> Void)?

  func makeUIView(context: Context) -> DustMetalHostView {
    DustMetalHostView()
  }

  func updateUIView(_ view: DustMetalHostView, context: Context) {
    view.update(
      raster: raster,
      progress: progress,
      preset: preset,
      configuration: configuration,
      transition: transition,
      onFailure: onFailure,
      onPresented: onPresented
    )
  }

  static func dismantleUIView(_ view: DustMetalHostView, coordinator: Void) {
    view.releaseResources()
  }
}

@MainActor
final class DustMetalHostView: UIView {
  private static let maximumDrawableRetryCount = 2

  private struct PendingPresentation {
    let raster: DustRaster
    let progress: Float
    let preset: DustPreset
    let configuration: DustConfiguration
    let transition: DustTransition
    let onFailure: (@MainActor (DustRenderingError) -> Void)?
    let onPresented: (@MainActor () -> Void)?
  }

  private let renderer: DustRenderer?
  private let metalView: MTKView?
  private let fallbackImageView = UIImageView()
  private let startupFailure: DustRenderingError?
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "DustKit",
    category: "DustRenderer"
  )
  private var lastReportedFailure: DustRenderingError?
  private var presentedRasterIdentity: ObjectIdentifier?
  private var fallbackRasterIdentity: ObjectIdentifier?
  private var drawableRetryBudget = 0
  private var drawableRetryScheduled = false
  private var gpuExecutionAllowed = true
  private var pendingPresentation: PendingPresentation?

  override init(frame: CGRect) {
    let renderer: DustRenderer?
    let metalView: MTKView?
    let startupFailure: DustRenderingError?

    do {
      let createdRenderer = try DustRenderer()
      renderer = createdRenderer
      metalView = MTKView(frame: .zero, device: createdRenderer.device)
      startupFailure = nil
    } catch let error as DustRenderingError {
      renderer = nil
      metalView = nil
      startupFailure = error
    } catch {
      renderer = nil
      metalView = nil
      startupFailure = .pipelineCreationFailed(
        operation: "startup", cause: error.localizedDescription)
    }

    self.renderer = renderer
    self.metalView = metalView
    self.startupFailure = startupFailure
    super.init(frame: frame)

    gpuExecutionAllowed = UIApplication.shared.applicationState == .active
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    backgroundColor = .clear
    isOpaque = false
    fallbackImageView.backgroundColor = .clear
    fallbackImageView.contentMode = .center
    fallbackImageView.isOpaque = false
    fallbackImageView.isAccessibilityElement = false
    addSubview(fallbackImageView)

    if let metalView, let renderer {
      metalView.delegate = renderer
      metalView.isPaused = true
      metalView.enableSetNeedsDisplay = true
      metalView.framebufferOnly = true
      metalView.colorPixelFormat = .bgra8Unorm_srgb
      metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
      metalView.backgroundColor = .clear
      metalView.isOpaque = false
      metalView.contentMode = .redraw
      (metalView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
      addSubview(metalView)
      bringSubviewToFront(fallbackImageView)
    }

    if gpuExecutionAllowed {
      renderer?.resumeGPUExecution()
    } else {
      renderer?.suspendGPUExecution()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    fallbackImageView.frame = bounds
    metalView?.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard gpuExecutionAllowed, window != nil, let metalView else { return }
    drawableRetryBudget = max(drawableRetryBudget, Self.maximumDrawableRetryCount)
    metalView.setNeedsDisplay()
  }

  func update(
    raster: DustRaster,
    progress: Float,
    preset: DustPreset,
    configuration: DustConfiguration,
    transition: DustTransition,
    onFailure: (@MainActor (DustRenderingError) -> Void)?,
    onPresented: (@MainActor () -> Void)?
  ) {
    let pending = PendingPresentation(
      raster: raster,
      progress: progress,
      preset: preset,
      configuration: configuration,
      transition: transition,
      onFailure: onFailure,
      onPresented: onPresented
    )
    pendingPresentation = pending

    let rasterIdentity = ObjectIdentifier(raster.image)
    if fallbackRasterIdentity != rasterIdentity {
      fallbackImageView.image = UIImage(
        cgImage: raster.image,
        scale: max(raster.scale, 1),
        orientation: .up
      )
      fallbackRasterIdentity = rasterIdentity
    }

    // Presentation authority follows the current raster, not renderer intent.
    // A new raster is visible immediately and stays above any stale Metal
    // contents until a GPU frame for the current source completes successfully.
    if presentedRasterIdentity != rasterIdentity {
      presentFallback()
    }

    guard gpuExecutionAllowed else {
      presentedRasterIdentity = nil
      presentFallback()
      return
    }

    apply(pending)
  }

  private func apply(_ pending: PendingPresentation) {
    let raster = pending.raster
    let progress = pending.progress
    let preset = pending.preset
    let configuration = pending.configuration
    let transition = pending.transition
    let onFailure = pending.onFailure
    let onPresented = pending.onPresented
    let rasterIdentity = ObjectIdentifier(raster.image)

    guard let renderer, let metalView else {
      presentedRasterIdentity = nil
      presentFallback()
      if let startupFailure {
        showFailure(startupFailure, onFailure: onFailure)
      }
      return
    }

    renderer.onFailure = { [weak self] failure in
      guard let self else { return }
      self.drawableRetryBudget = 0
      self.presentedRasterIdentity = nil
      self.presentFallback()
      self.showFailure(failure, onFailure: onFailure)
    }
    renderer.onFrameCompleted = { [weak self] in
      guard let self else { return }
      self.lastReportedFailure = nil
      self.drawableRetryBudget = 0
      let wasPresented = self.presentedRasterIdentity == rasterIdentity
      self.presentedRasterIdentity = rasterIdentity
      self.presentMetal()
      if !wasPresented {
        onPresented?()
      }
    }
    renderer.onDrawableUnavailable = { [weak self] in
      self?.scheduleDrawableRetry()
    }

    metalView.contentScaleFactor = window?.screen.scale ?? UIScreen.main.scale
    metalView.isHidden = false
    do {
      try renderer.update(
        raster: raster,
        progress: progress,
        preset: preset,
        configuration: configuration,
        transition: transition,
        displayScale: metalView.contentScaleFactor
      )
      if presentedRasterIdentity == rasterIdentity {
        presentMetal()
      } else {
        presentFallback()
      }
      drawableRetryBudget = Self.maximumDrawableRetryCount
      metalView.setNeedsDisplay()
    } catch let failure as DustRenderingError {
      renderer.releaseTransientResources()
      presentedRasterIdentity = nil
      presentFallback()
      showFailure(failure, onFailure: onFailure)
    } catch {
      renderer.releaseTransientResources()
      presentedRasterIdentity = nil
      presentFallback()
      showFailure(
        .commandEncodingFailed(operation: error.localizedDescription),
        onFailure: onFailure
      )
    }
  }

  func releaseResources() {
    NotificationCenter.default.removeObserver(self)
    pendingPresentation = nil
    gpuExecutionAllowed = false
    metalView?.isPaused = true
    metalView?.delegate = nil
    renderer?.onFailure = nil
    renderer?.onFrameCompleted = nil
    renderer?.onDrawableUnavailable = nil
    renderer?.suspendGPUExecution()
    renderer?.releaseTransientResources()
    drawableRetryBudget = 0
    drawableRetryScheduled = false
    presentedRasterIdentity = nil
    fallbackRasterIdentity = nil
    fallbackImageView.image = nil
  }

  private func scheduleDrawableRetry() {
    guard gpuExecutionAllowed, drawableRetryBudget > 0, !drawableRetryScheduled,
      let metalView, window != nil
    else { return }
    drawableRetryBudget -= 1
    drawableRetryScheduled = true
    DispatchQueue.main.async { [weak self, weak metalView] in
      guard let self else { return }
      self.drawableRetryScheduled = false
      guard self.gpuExecutionAllowed, let metalView, self.window != nil else { return }
      metalView.setNeedsDisplay()
    }
  }

  @objc private func applicationWillResignActive() {
    guard gpuExecutionAllowed else { return }
    gpuExecutionAllowed = false
    drawableRetryBudget = 0
    drawableRetryScheduled = false
    presentedRasterIdentity = nil
    renderer?.suspendGPUExecution()
    renderer?.releaseTransientResources()
    presentFallback()
  }

  @objc private func applicationDidBecomeActive() {
    guard !gpuExecutionAllowed else { return }
    gpuExecutionAllowed = true
    renderer?.resumeGPUExecution()
    guard window != nil, let pendingPresentation else { return }
    apply(pendingPresentation)
  }

  private func presentFallback() {
    fallbackImageView.isHidden = false
    bringSubviewToFront(fallbackImageView)
  }

  private func presentMetal() {
    guard let metalView else { return }
    metalView.isHidden = false
    bringSubviewToFront(metalView)
    fallbackImageView.isHidden = true
  }

  private func showFailure(
    _ failure: DustRenderingError,
    onFailure: (@MainActor (DustRenderingError) -> Void)?
  ) {
    guard lastReportedFailure != failure else { return }
    lastReportedFailure = failure
    logger.error("\(failure.localizedDescription, privacy: .public)")
    onFailure?(failure)
  }
}
#endif
