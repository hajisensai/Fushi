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
///   电台（`playStation`）例外：队列是整个电台、由 MusicKit 自己换歌，换歌时推 `nowPlaying`，
///   `skipToNext` 走 `skipToNextEntry()`。
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
    case "play", "playStation", "skipToNext", "pause", "resume", "stop", "seek":
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
        case "playStation":
          guard let stationId = args["stationId"] as? String, !stationId.isEmpty else {
            throw BridgeError.badArgs("stationId required")
          }
          let autoplay = (args["autoplay"] as? Bool) ?? true
          try await player.playStation(stationId: stationId, autoplay: autoplay)
        case "skipToNext":
          try await player.skipToNext()
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
///
/// 电台（`playStation`）例外：Apple 不公开电台的曲目列表，队列只能是整个电台、由 MusicKit 自己
/// 换歌。同一轮询里发现 `queue.currentEntry` 换了就推一次 `nowPlaying`（是歌曲时带 catalog id /
/// 时长，直播节目只有标题 / 副标题 / 封面）；电台只在队列空了（`currentEntry == nil`）时报
/// `ended`，每首歌之间的停顿不算播完。
@available(iOS 15.0, macOS 14.0, *)
@MainActor
final class AppleMusicPlayerCore {
  private let emit: ([String: Any]) -> Void
  private let player = ApplicationMusicPlayer.shared
  private var timer: Timer?

  /// 单曲：Dart 给的那首；电台：当前条目是歌曲时它的 catalog id（直播节目为 nil）。
  private var songId: String?
  /// 正在放的电台（`playStation` 成功后才置上）；单曲时为 nil。
  private var stationId: String?
  /// 电台里上一次报过 `nowPlaying` 的条目（`Queue.Entry.id`）。
  private var entryId: String?
  private var durationMs: Int?
  private var wasPlaying = false
  private var lastPositionMs = 0
  /// Dart 刚叫停 / 暂停、播放器还没再出声：这期间的「停下」不算播完。一观察到出声就复位
  /// （不管是 Dart resume，还是系统 Now Playing / 耳机线控恢复），之后的自然播完照常判。
  private var stopRequested = false
  /// 换曲 / 停止的请求序号。`play` 在 catalog 请求与 `prepareToPlay` 处挂起，MainActor 上后到的
  /// `play` / `stop` 可以先跑完；每个挂起点之后核对序号，已被取代就不再碰 `player.queue`。
  private var requestId = 0

  init(emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
  }

  func play(songId: String, startMs: Int, autoplay: Bool) async throws {
    requestId += 1
    let request = requestId
    stopRequested = true
    // 换曲期间不再推上一首的进度 / 结束（Dart 侧也按 songId 过滤，这里先止住）。
    self.songId = nil
    stationId = nil
    entryId = nil
    var catalogRequest = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(songId))
    catalogRequest.limit = 1
    let response = try await catalogRequest.response()
    guard request == requestId else { return }
    guard let song = response.items.first else {
      throw BridgeError.notFound("song \(songId) not in catalog")
    }
    player.queue = ApplicationMusicPlayer.Queue(for: [song])
    try await player.prepareToPlay()
    guard request == requestId else { return }
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
      guard request == requestId else { return }
    }
    startTimer()
    tick()
  }

  /// 放一个 catalog 电台：队列交给 MusicKit 自管。与 `play` 同样按 `requestId` 防后到先完成。
  func playStation(stationId: String, autoplay: Bool) async throws {
    requestId += 1
    let request = requestId
    stopRequested = true
    songId = nil
    self.stationId = nil
    entryId = nil
    var catalogRequest = MusicCatalogResourceRequest<Station>(
      matching: \.id, equalTo: MusicItemID(stationId))
    catalogRequest.limit = 1
    let response = try await catalogRequest.response()
    guard request == requestId else { return }
    guard let station = response.items.first else {
      throw BridgeError.notFound("station \(stationId) not in catalog")
    }
    player.queue = ApplicationMusicPlayer.Queue(for: [station])
    try await player.prepareToPlay()
    guard request == requestId else { return }
    self.stationId = stationId
    durationMs = nil
    lastPositionMs = 0
    wasPlaying = false
    stopRequested = false
    if autoplay {
      try await player.play()
      guard request == requestId else { return }
    }
    startTimer()
    tick()
  }

  /// 电台里换下一首（单曲队列不理会：Dart 侧只在电台时调）。
  func skipToNext() async throws {
    guard stationId != nil else { return }
    try await player.skipToNextEntry()
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
    requestId += 1
    stopRequested = true
    player.stop()
    songId = nil
    stationId = nil
    entryId = nil
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
    guard songId != nil || stationId != nil else { return }
    checkStationEntry()
    let songId = self.songId
    let status = player.state.playbackStatus
    let playing = status == .playing
    if playing && !wasPlaying {
      // 重新出声（停 → 播的边沿；只认边沿，刚 pause() 还没生效的那一拍不算）：之前那次叫停
      // 已经过去了（可能由系统 Now Playing / 线控恢复，Dart 不知道）。
      stopRequested = false
    }
    let positionMs = Int((player.playbackTime * 1000).rounded())
    var progress: [String: Any] = ["type": "progress", "positionMs": positionMs]
    if let songId { progress["songId"] = songId }
    if let durationMs { progress["durationMs"] = durationMs }
    if playing != wasPlaying {
      if wasPlaying && !playing && !stopRequested && reachedEnd() {
        // 自然播完：单曲位置到尾部或队列已空；电台只认队列已空。
        wasPlaying = false
        timer?.invalidate()
        timer = nil
        var ended: [String: Any] = ["type": "ended"]
        if let songId { ended["songId"] = songId }
        emit(ended)
        self.songId = nil
        stationId = nil
        entryId = nil
        return
      }
      wasPlaying = playing
      var changed: [String: Any] = ["type": "playing", "playing": playing]
      if let songId { changed["songId"] = songId }
      emit(changed)
    }
    if playing || positionMs != lastPositionMs {
      emit(progress)
    }
    lastPositionMs = positionMs
  }

  /// 电台：当前条目换了就推 `nowPlaying`（同时换掉 `songId` / `durationMs`，之后的进度按新曲报）。
  private func checkStationEntry() {
    guard stationId != nil, let entry = player.queue.currentEntry else { return }
    guard entry.id != entryId else { return }
    entryId = entry.id
    lastPositionMs = 0
    var event: [String: Any] = ["type": "nowPlaying"]
    if case .song(let song)? = entry.item {
      songId = song.id.rawValue
      durationMs = song.duration.map { Int(($0 * 1000).rounded()) }
      event["songId"] = song.id.rawValue
      event["title"] = song.title
      event["artist"] = song.artistName
      if let album = song.albumTitle { event["album"] = album }
      if let durationMs { event["durationMs"] = durationMs }
      if let url = song.artwork?.url(width: 600, height: 600) {
        event["artworkUrl"] = url.absoluteString
      }
    } else {
      // 直播节目 / 非歌曲条目：没有 catalog 曲目身份与时长。
      songId = nil
      durationMs = nil
      event["title"] = entry.title
      if let subtitle = entry.subtitle { event["artist"] = subtitle }
      if let url = entry.artwork?.url(width: 600, height: 600) {
        event["artworkUrl"] = url.absoluteString
      }
    }
    emit(event)
  }

  private func reachedEnd() -> Bool {
    if player.queue.currentEntry == nil { return true }
    // 电台每首之间也会短暂停下：只有队列空了才算结束。
    if stationId != nil { return false }
    guard let durationMs, durationMs > 0 else { return false }
    return lastPositionMs >= durationMs - 1500
  }
}
#endif
