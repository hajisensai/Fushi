import Foundation

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

#if canImport(MusicKit)
import MusicKit
#endif

/// Apple Music 的 Apple 平台桥（MusicKit 方案 §3.1，P2）：`app.fushi.reader/apple_music`
/// method channel + `app.fushi.reader/apple_music/events` event channel，Dart 侧契约见
/// `lib/src/media/music/apple_music/apple_music_native_bridge.dart`。iOS 与 macOS 同一份实现。
///
/// - 授权：`MusicAuthorization.request()`（系统框，文案取 `NSAppleMusicUsageDescription`）。
///   developer token 由系统按 App ID（已勾 MusicKit 服务）自动生成，不用 Worker 代签的那枚。
/// - 订阅：`MusicSubscription.current`；账号地区：`MusicDataRequest.currentCountryCode`。
/// - 播放：`ApplicationMusicPlayer`，队列只放 Dart 指定的一首（Fushi 的队列是唯一真相）。
///   macOS 上 `ApplicationMusicPlayer` 要 14.0+，13.x 的 `play` 等回 `unsupported`
///   （Dart 侧按系统版本不建桥，正常走不到）。
/// - 进度：主线程 250 ms 轮询 `playbackTime` / `playbackStatus` 推给 Dart；自然播完以
///   「刚才在放、现在停了、且位置已到尾部或队列已空」判定，发一次 `ended`。
/// - 资料库：`DefaultMusicTokenProvider` 给 developer token 与配套的 Music-User-Token，由 Dart
///   直接调 `api.music.apple.com/v1/me/library/...`。
///
/// 失败一律 `FlutterError` 回 Dart，不装成功。
final class FushiAppleMusic: NSObject, FlutterStreamHandler {
  static let channelName = "app.fushi.reader/apple_music"
  static let eventChannelName = "app.fushi.reader/apple_music/events"

  /// channel 的 handler 闭包持有它；静态再留一份，防止被释放。
  private static var instance: FushiAppleMusic?

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let bridge = FushiAppleMusic()
    instance = bridge
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      bridge.handle(call, result: result)
    }
    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: binaryMessenger)
    events.setStreamHandler(bridge)
  }

  private var sink: FlutterEventSink?
  private var core: AnyObject?

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  fileprivate func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(event) }
  }

  // MARK: 方法分发

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(MusicKit)
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "accountState":
      run(result) { try await Self.accountState() }
    case "authorize":
      run(result) {
        _ = await MusicAuthorization.request()
        return try await Self.accountState()
      }
    case "userCredentials":
      run(result) {
        guard MusicAuthorization.currentStatus == .authorized else { return nil }
        let provider = DefaultMusicTokenProvider()
        let developerToken = try await provider.developerToken(options: [])
        let userToken = try await provider.userToken(for: developerToken, options: [])
        return ["developerToken": developerToken, "userToken": userToken]
      }
    case "play", "pause", "resume", "stop", "seek":
      run(result) { @MainActor [weak self] in
        guard #available(iOS 15.0, macOS 14.0, *) else {
          throw BridgeError.unsupported("ApplicationMusicPlayer needs macOS 14")
        }
        guard let self else { return nil }
        let player = self.playerCore()
        switch call.method {
        case "play":
          guard let songId = args["songId"] as? String, !songId.isEmpty else {
            throw BridgeError.badArgs("songId required")
          }
          let startMs = (args["startMs"] as? NSNumber)?.intValue ?? 0
          let autoplay = (args["autoplay"] as? Bool) ?? true
          try await player.play(songId: songId, startMs: startMs, autoplay: autoplay)
        case "pause":
          player.pause()
        case "resume":
          try await player.resume()
        case "stop":
          player.stop()
        case "seek":
          let ms = (args["positionMs"] as? NSNumber)?.intValue ?? 0
          player.seek(ms: ms)
        default:
          break
        }
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
    #else
    result(FlutterError(code: "unsupported", message: "MusicKit unavailable", details: nil))
    #endif
  }

  #if canImport(MusicKit)
  @available(iOS 15.0, macOS 14.0, *)
  @MainActor
  private func playerCore() -> AppleMusicPlayerCore {
    if let existing = core as? AppleMusicPlayerCore { return existing }
    let created = AppleMusicPlayerCore(emit: { [weak self] e in self?.emit(e) })
    core = created
    return created
  }

  /// 在主线程上跑一段 async 逻辑，把结果 / 错误交回 Flutter。
  private func run(
    _ result: @escaping FlutterResult,
    _ body: @escaping @MainActor () async throws -> Any?
  ) {
    Task { @MainActor in
      do {
        result(try await body())
      } catch let BridgeError.badArgs(message) {
        result(FlutterError(code: "bad_args", message: message, details: nil))
      } catch let BridgeError.notFound(message) {
        result(FlutterError(code: "not_found", message: message, details: nil))
      } catch let BridgeError.unsupported(message) {
        result(FlutterError(code: "unsupported", message: message, details: nil))
      } catch {
        result(FlutterError(code: "failed", message: String(describing: error), details: nil))
      }
    }
  }

  private static func wire(_ status: MusicAuthorization.Status) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
  }

  /// 授权 / 订阅 / 地区。读不到订阅（网络 / 未登录 Apple ID）时按不能整曲报。
  private static func accountState() async throws -> [String: Any] {
    let status = MusicAuthorization.currentStatus
    var out: [String: Any] = ["status": wire(status)]
    guard status == .authorized else { return out }
    if let sub = try? await MusicSubscription.current {
      out["canPlayCatalogContent"] = sub.canPlayCatalogContent
      out["canBecomeSubscriber"] = sub.canBecomeSubscriber
    }
    if #available(iOS 16.0, macOS 13.0, *) {
      if let code = try? await MusicDataRequest.currentCountryCode {
        out["storefront"] = code.lowercased()
      }
    }
    return out
  }
  #endif
}

enum BridgeError: Error {
  case badArgs(String)
  case notFound(String)
  case unsupported(String)
}

#if canImport(MusicKit)
/// `ApplicationMusicPlayer` 的单曲控制 + 进度轮询。
@available(iOS 15.0, macOS 14.0, *)
@MainActor
final class AppleMusicPlayerCore {
  private let emit: ([String: Any]) -> Void
  private let player = ApplicationMusicPlayer.shared
  private var timer: Timer?

  private var songId: String?
  private var durationMs: Int?
  private var wasPlaying = false
  private var lastPositionMs = 0
  /// Dart 叫停 / 暂停之后的「停下」不算播完。
  private var stopRequested = false

  init(emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
  }

  func play(songId: String, startMs: Int, autoplay: Bool) async throws {
    stopRequested = true
    var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(songId))
    request.limit = 1
    let response = try await request.response()
    guard let song = response.items.first else {
      throw BridgeError.notFound("song \(songId) not in catalog")
    }
    player.queue = ApplicationMusicPlayer.Queue(for: [song])
    try await player.prepareToPlay()
    if startMs > 0 {
      player.playbackTime = TimeInterval(startMs) / 1000
    }
    self.songId = songId
    durationMs = song.duration.map { Int(($0 * 1000).rounded()) }
    lastPositionMs = startMs
    wasPlaying = false
    stopRequested = false
    if autoplay {
      try await player.play()
    }
    startTimer()
    tick()
  }

  func pause() {
    stopRequested = true
    player.pause()
    tick()
  }

  func resume() async throws {
    stopRequested = false
    try await player.play()
    startTimer()
    tick()
  }

  func stop() {
    stopRequested = true
    player.stop()
    songId = nil
    timer?.invalidate()
    timer = nil
    if wasPlaying {
      wasPlaying = false
      emit(["type": "playing", "playing": false])
    }
  }

  func seek(ms: Int) {
    player.playbackTime = TimeInterval(max(0, ms)) / 1000
    lastPositionMs = max(0, ms)
    tick()
  }

  private func startTimer() {
    guard timer == nil else { return }
    let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func tick() {
    guard let songId else { return }
    let status = player.state.playbackStatus
    let playing = status == .playing
    let positionMs = Int((player.playbackTime * 1000).rounded())
    var progress: [String: Any] = ["type": "progress", "positionMs": positionMs, "songId": songId]
    if let durationMs { progress["durationMs"] = durationMs }
    if playing != wasPlaying {
      if wasPlaying && !playing && !stopRequested && reachedEnd() {
        // 自然播完：位置到尾部或队列已空。
        wasPlaying = false
        timer?.invalidate()
        timer = nil
        emit(["type": "ended", "songId": songId])
        self.songId = nil
        return
      }
      wasPlaying = playing
      emit(["type": "playing", "playing": playing, "songId": songId])
    }
    if playing || positionMs != lastPositionMs {
      emit(progress)
    }
    lastPositionMs = positionMs
  }

  private func reachedEnd() -> Bool {
    if player.queue.currentEntry == nil { return true }
    guard let durationMs, durationMs > 0 else { return false }
    return lastPositionMs >= durationMs - 1500
  }
}
#endif
