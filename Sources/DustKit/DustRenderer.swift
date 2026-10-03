#if os(iOS)
import DustKitResources
import MetalKit
import UIKit

@MainActor
final class DustRenderer: NSObject, MTKViewDelegate {
  struct SourceUniforms {
    var viewportAndImageOrigin: SIMD4<Float>
    var imageAndTextureSize: SIMD4<Float>
  }

  struct ParticleUniforms {
    var viewportAndImageOrigin: SIMD4<Float>
    var imageAndTextureSize: SIMD4<Float>
    var progressCellScaleEndScale: SIMD4<Float>
    var directionDistanceSpread: SIMD4<Float>
    var rotationStaggerGravityFlutter: SIMD4<Float>
    var fadeMorphShape: SIMD4<Float>
    var frequencyWaveDistanceMin: SIMD4<Float>
    var distanceMaxAndPadding: SIMD4<Float>
    var gridAndSeed: SIMD4<UInt32>
  }

  let device: MTLDevice
  var onFailure: (@MainActor (DustRenderingError) -> Void)?
  var onFrameCompleted: (@MainActor () -> Void)?
  var onDrawableUnavailable: (@MainActor () -> Void)?

  private let commandQueue: MTLCommandQueue
  private let sourcePipelineState: MTLRenderPipelineState
  private let particlePipelineState: MTLRenderPipelineState
  private let textureLoader: MTKTextureLoader

  private struct PlanKey: Equatable {
    let imageIdentity: ObjectIdentifier
    let requestedCellSize: Float
    let maximumCount: Int
  }

  private var texture: MTLTexture?
  private var textureIdentity: ObjectIdentifier?
  private var planKey: PlanKey?
  private var particlePlan: DustParticlePlan?
  private var particleMetadataBuffer: MTLBuffer?
  private var raster: DustRaster?
  private var progress: Float = 0
  private var motionProgress: Float = 0
  private var preset: DustPreset = .softDust
  private var configuration: DustConfiguration = .default
  private var transition: DustTransition = .disintegrate
  private var displayScale: CGFloat = 1
  private var gpuExecutionAllowed = true
  private var lastSubmittedCommandBuffer: MTLCommandBuffer?
  /// Publication epoch for the current source raster. Progress/configuration
  /// updates are presentation changes within the same source and must not
  /// invalidate an in-flight GPU completion that is still safe to publish.
  private var sourceGeneration: UInt64 = 0

  init(bundle: Bundle = DustKitResourceBundle.bundle) throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw DustRenderingError.metalUnavailable
    }
    guard let commandQueue = device.makeCommandQueue() else {
      throw DustRenderingError.commandQueueUnavailable
    }

    let library: MTLLibrary
    do {
      library = try device.makeDefaultLibrary(bundle: bundle)
    } catch {
      throw DustRenderingError.shaderLibraryUnavailable(cause: error.localizedDescription)
    }

    self.device = device
    self.commandQueue = commandQueue
    self.textureLoader = MTKTextureLoader(device: device)
    self.sourcePipelineState = try Self.makePipeline(
      device: device,
      library: library,
      vertexName: "dustSourceVertex",
      fragmentName: "dustSourceFragment",
      label: "source"
    )
    self.particlePipelineState = try Self.makePipeline(
      device: device,
      library: library,
      vertexName: "dustParticleVertex",
      fragmentName: "dustParticleFragment",
      label: "particle"
    )
    super.init()
  }

  func update(
    raster: DustRaster,
    progress: Float,
    preset: DustPreset,
    configuration: DustConfiguration,
    transition: DustTransition,
    displayScale: CGFloat
  ) throws {
    self.raster = raster
    let normalizedProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
    self.progress = normalizedProgress
    self.preset = preset
    self.configuration = configuration
    self.transition = transition
    self.motionProgress = transition.motionProgress(for: normalizedProgress)
    self.displayScale = displayScale.isFinite ? max(displayScale, 1) : 1

    let identity = ObjectIdentifier(raster.image)
    if textureIdentity != identity {
      // A different source invalidates callbacks from the previous raster.
      // Do this before texture creation so a failed replacement cannot later
      // publish an older GPU completion as the current source.
      sourceGeneration &+= 1
      do {
        let newTexture = try textureLoader.newTexture(
          cgImage: raster.image,
          options: [
            .SRGB: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
          ]
        )
        newTexture.label = "DustKit canonical source"
        texture = newTexture
        textureIdentity = identity
      } catch {
        texture = nil
        textureIdentity = nil
        throw DustRenderingError.textureCreationFailed(
          operation: "canonical source",
          cause: error.localizedDescription
        )
      }
    }

    guard transition.drawsParticles(at: self.progress) else {
      planKey = nil
      particlePlan = nil
      particleMetadataBuffer = nil
      return
    }

    let requestedCell = max(Float(configuration.particleSize * raster.scale), 1)
    let nextPlanKey = PlanKey(
      imageIdentity: identity,
      requestedCellSize: requestedCell,
      maximumCount: configuration.maximumParticleCount
    )
    guard planKey != nextPlanKey else { return }

    let plan = DustParticleGridPlanner.makePlan(
      alphaMask: raster.alphaMask,
      requestedCellSize: requestedCell,
      maximumCount: configuration.maximumParticleCount
    )
    guard !plan.particles.isEmpty else {
      throw DustRenderingError.bufferCreationFailed(operation: "nonempty particle metadata")
    }

    let buffer: MTLBuffer? = plan.particles.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress, bytes.count > 0 else { return nil }
      return device.makeBuffer(
        bytes: baseAddress,
        length: bytes.count,
        options: .storageModeShared
      )
    }
    guard let buffer else {
      throw DustRenderingError.bufferCreationFailed(operation: "particle metadata")
    }
    buffer.label = "DustKit particle metadata"

    particlePlan = plan
    particleMetadataBuffer = buffer
    planKey = nextPlanKey
  }

  func releaseTransientResources() {
    sourceGeneration &+= 1
    texture = nil
    textureIdentity = nil
    planKey = nil
    particlePlan = nil
    particleMetadataBuffer = nil
    raster = nil
    lastSubmittedCommandBuffer = nil
  }

  /// Stops future GPU submission and invalidates completions from work that
  /// belonged to the previous active lifecycle epoch. UIKit requires Metal
  /// clients to stop committing new command buffers once the app leaves the
  /// active foreground; waiting only until the most recent buffer is scheduled
  /// keeps already-committed work inside that boundary without waiting for GPU
  /// completion.
  func suspendGPUExecution() {
    guard gpuExecutionAllowed else { return }
    gpuExecutionAllowed = false
    sourceGeneration &+= 1
    lastSubmittedCommandBuffer?.waitUntilScheduled()
    lastSubmittedCommandBuffer = nil
  }

  func resumeGPUExecution() {
    gpuExecutionAllowed = true
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    view.setNeedsDisplay()
  }

  func draw(in view: MTKView) {
    guard gpuExecutionAllowed else { return }
    guard let raster, let texture else { return }
    guard let drawable = view.currentDrawable,
      let pass = view.currentRenderPassDescriptor
    else {
      onDrawableUnavailable?()
      return
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      report(.commandEncodingFailed(operation: "command buffer creation"))
      return
    }
    let generation = sourceGeneration
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      report(.commandEncodingFailed(operation: "render encoder creation"))
      return
    }

    let viewportWidth = Float(view.drawableSize.width)
    let viewportHeight = Float(view.drawableSize.height)
    guard viewportWidth > 0, viewportHeight > 0 else {
      encoder.endEncoding()
      return
    }

    let displayScaleFloat = Float(displayScale)
    let sourceScale = Float(max(raster.scale, 1))
    let textureToDisplay = displayScaleFloat / sourceScale
    let imageWidth = Float(texture.width) * textureToDisplay
    let imageHeight = Float(texture.height) * textureToDisplay
    let imageOriginX = (viewportWidth - imageWidth) * 0.5
    let imageOriginY = (viewportHeight - imageHeight) * 0.5

    if transition.drawsSource(at: progress) {
      var uniforms = SourceUniforms(
        viewportAndImageOrigin: .init(
          viewportWidth, viewportHeight, imageOriginX, imageOriginY
        ),
        imageAndTextureSize: .init(
          imageWidth, imageHeight, Float(texture.width), Float(texture.height)
        )
      )
      encoder.label = "DustKit assembled source encoder"
      encoder.setRenderPipelineState(sourcePipelineState)
      encoder.setVertexBytes(
        &uniforms,
        length: MemoryLayout<SourceUniforms>.stride,
        index: 0
      )
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    } else if transition.drawsParticles(at: progress) {
      guard let plan = particlePlan, let metadataBuffer = particleMetadataBuffer else {
        encoder.endEncoding()
        report(.commandEncodingFailed(operation: "particle plan is unavailable"))
        return
      }
      let profile = DustMotionProfile.resolve(preset: preset, configuration: configuration)
      let grid = plan.grid
      var uniforms = ParticleUniforms(
        viewportAndImageOrigin: .init(
          viewportWidth, viewportHeight, imageOriginX, imageOriginY
        ),
        imageAndTextureSize: .init(
          imageWidth, imageHeight, Float(texture.width), Float(texture.height)
        ),
        progressCellScaleEndScale: .init(
          motionProgress,
          grid.cellSize,
          textureToDisplay,
          profile.endScale
        ),
        directionDistanceSpread: .init(
          Float(profile.direction.dx),
          Float(profile.direction.dy),
          Float(profile.distance) * displayScaleFloat,
          profile.spreadRadians
        ),
        rotationStaggerGravityFlutter: .init(
          profile.rotationRadians,
          profile.stagger,
          Float(profile.gravity) * displayScaleFloat,
          Float(profile.flutter) * displayScaleFloat
        ),
        fadeMorphShape: .init(
          profile.fadeStart,
          profile.morphStart,
          profile.morphEnd,
          profile.particleRoundness
        ),
        frequencyWaveDistanceMin: .init(
          profile.driftFrequency,
          profile.microFrequency,
          profile.waveDirectionRadians,
          Float(profile.minimumDistanceMultiplier)
        ),
        distanceMaxAndPadding: .init(
          Float(profile.maximumDistanceMultiplier),
          0,
          0,
          transition == .assemble ? 1 : 0
        ),
        gridAndSeed: .init(
          UInt32(grid.columns),
          UInt32(grid.rows),
          configuration.seed,
          0
        )
      )

      encoder.label = "DustKit particle encoder"
      encoder.setRenderPipelineState(particlePipelineState)
      encoder.setVertexBytes(
        &uniforms,
        length: MemoryLayout<ParticleUniforms>.stride,
        index: 0
      )
      encoder.setVertexBuffer(metadataBuffer, offset: 0, index: 1)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: 6,
        instanceCount: plan.count
      )
    }

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.addCompletedHandler { [weak self] completedBuffer in
      let failureCause: String?
      if completedBuffer.status == .error {
        failureCause =
          completedBuffer.error?.localizedDescription ?? "unknown GPU execution failure"
      } else {
        failureCause = nil
      }

      Task { @MainActor [weak self] in
        guard let self, generation == self.sourceGeneration else { return }
        if let failureCause {
          self.report(.commandExecutionFailed(cause: failureCause))
        } else {
          self.onFrameCompleted?()
        }
      }
    }
    lastSubmittedCommandBuffer = commandBuffer
    commandBuffer.commit()
  }

  private func report(_ error: DustRenderingError) {
    onFailure?(error)
  }

  private static func makePipeline(
    device: MTLDevice,
    library: MTLLibrary,
    vertexName: String,
    fragmentName: String,
    label: String
  ) throws -> MTLRenderPipelineState {
    guard let vertex = library.makeFunction(name: vertexName) else {
      throw DustRenderingError.missingShader(name: vertexName)
    }
    guard let fragment = library.makeFunction(name: fragmentName) else {
      throw DustRenderingError.missingShader(name: fragmentName)
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "DustKit \(label) pipeline"
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

    guard let attachment = descriptor.colorAttachments[0] else {
      throw DustRenderingError.pipelineCreationFailed(
        operation: label,
        cause: "missing color attachment"
      )
    }
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    do {
      return try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      throw DustRenderingError.pipelineCreationFailed(
        operation: label,
        cause: error.localizedDescription
      )
    }
  }
}
#endif
