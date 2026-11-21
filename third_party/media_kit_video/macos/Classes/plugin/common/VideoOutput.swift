#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false

  #if os(iOS)
    // Fushi (decision 42UUu_kcwD, video background audio): iOS kills an app that
    // submits OpenGL ES work after it entered the background
    // (gpus_ReturnNotPermittedKillClient), but this class renders on the worker
    // thread whenever libmpv signals a new frame. All GL work is therefore
    // suspended while the app is in the background and resumed (plus one redraw)
    // when it returns. `gpuLock` only wraps the GL calls themselves, never the
    // `DispatchQueue.main.sync` hops, so the main thread taking it in the
    // notification handler just waits for the in-flight frame and cannot
    // deadlock.
    private let gpuLock = NSLock()
    private var gpuSuspended: Bool = false  // guarded by gpuLock
    private var lifecycleObservers: [NSObjectProtocol] = []
  #endif

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    #if os(iOS)
      observeApplicationLifecycle()
    #endif

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    #if os(iOS)
      for observer in lifecycleObservers {
        NotificationCenter.default.removeObserver(observer)
      }
    #endif

    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  #if os(iOS)
    private func observeApplicationLifecycle() {
      if Thread.isMainThread {
        gpuSuspended = UIApplication.shared.applicationState == .background
      }
      let center = NotificationCenter.default
      // queue: nil -> delivered synchronously on the posting (main) thread, i.e.
      // inside applicationDidEnterBackground, before the app may be suspended.
      lifecycleObservers.append(
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          guard let that = self else { return }
          that.gpuLock.lock()
          that.gpuSuspended = true
          that.gpuLock.unlock()
        }
      )
      lifecycleObservers.append(
        center.addObserver(
          forName: UIApplication.willEnterForegroundNotification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          guard let that = self else { return }
          that.gpuLock.lock()
          that.gpuSuspended = false
          that.gpuLock.unlock()
          // Frames skipped in the background left the texture stale.
          that.updateCallback()
        }
      )
    }

    /// Returns false (and holds no lock) while the app is in the background.
    private func beginGpuWork() -> Bool {
      gpuLock.lock()
      if gpuSuspended {
        gpuLock.unlock()
        return false
      }
      return true
    }

    private func endGpuWork() {
      gpuLock.unlock()
    }
  #endif

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    } else {
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      #if os(iOS)
        if !beginGpuWork() {
          return
        }
      #endif
      currentSize = size

      texture.resize(size)
      #if os(iOS)
        endGpuWork()
      #endif
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    #if os(iOS)
      if !beginGpuWork() {
        return
      }
    #endif
    texture.render(size)
    #if os(iOS)
      endGpuWork()
    #endif
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}
