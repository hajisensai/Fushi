import Foundation
import ImageIO
import WidgetKit

#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif

#if canImport(ActivityKit) && os(iOS)
  import ActivityKit
#endif

#if os(iOS)
  import AppIntents

  /// 只能在主 app 里声明（扩展里不可用）：后台续播接不住时把 app 带到前台。
  @available(iOS 17.0, *)
  extension FushiResumeAudiobookIntent: ForegroundContinuableIntent {}
#endif

/// 主屏小组件 / Live Activity / 菜单栏播放条的原生半边（主 app 进程）。
///
/// - 快照：`app.fushi.reader/widgets` 通道的 `updateSnapshot(json)`——与 Android
///   `WidgetChannel.kt` **同一个**方法、同一份 JSON（Dart `WidgetSnapshotPublisher`）。
///   [FushiWidgetSnapshotSink] 把封面拷进 App Group、写 `snapshot.json`、重载时间线。
/// - 活动：`app.fushi.reader/home_widgets` 通道。iOS 上 `start*` / `update*` / `end` 映射
///   ActivityKit（灵动岛 + 锁屏）；macOS 没有 Live Activity，同一组调用驱动菜单栏播放条
///   [FushiMenuBarActivities]。ActivityKit 的 update / end 都是异步的，这里排成**一条串行
///   队列**，保证按 Dart 发出的顺序执行（不会出现「先结束、后更新」）。
/// - 反方向：小组件 / Live Activity / 菜单栏按钮经 [FushiIntentRelay] 走 `home_widgets` 的
///   `action` 交给 Dart，Dart 返回是否接住。
final class FushiHomeWidgets {
  static let shared = FushiHomeWidgets()
  static let channelName = "app.fushi.reader/home_widgets"
  static let snapshotChannelName = "app.fushi.reader/widgets"

  private var channel: FlutterMethodChannel?
  private var snapshotChannel: FlutterMethodChannel?
  private let sink = FushiWidgetSnapshotSink()

  /// ActivityKit 操作的串行链（只在主线程上读写）。
  private var activityChain: Task<Void, Never>?

  #if os(macOS)
    private lazy var menuBar = FushiMenuBarActivities(
      onAction: { action in
        Task { _ = await FushiIntentRelay.send("playback", action) }
      },
      onOpen: { url in
        (NSApp.delegate as? AppDelegate)?.deliverUrl(url)
        NSApp.activate(ignoringOtherApps: true)
      })
  #endif

  func install(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: binaryMessenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    let snapshotChannel = FlutterMethodChannel(
      name: Self.snapshotChannelName, binaryMessenger: binaryMessenger)
    self.snapshotChannel = snapshotChannel
    snapshotChannel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "updateSnapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let json = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: "updateSnapshot expects a JSON string", details: nil))
        return
      }
      self.sink.write(json: json) { error in
        DispatchQueue.main.async {
          if let error {
            result(FlutterError(code: "write_failed", message: error, details: nil))
          } else {
            WidgetCenter.shared.reloadAllTimelines()
            result(nil)
          }
        }
      }
    }
    FushiIntentRelay.handler = { [weak self] action, argument in
      await self?.sendToDart(action: action, argument: argument) ?? false
    }
    #if os(iOS)
      if #available(iOS 17.0, *) {
        FushiIntentRelay.continueInForeground = { url in
          FushiResumeAudiobookIntent(kind: nil, url: url).needsToContinueInForegroundError {
            await FushiIntentRelay.openInForeground(url)
          }
        }
      }
    #endif
    FushiIntentRelay.foregroundOpener = { url in
      await MainActor.run {
        #if os(iOS)
          (UIApplication.shared.delegate as? AppDelegate)?.deliverUrl(url)
        #else
          (NSApp.delegate as? AppDelegate)?.deliverUrl(url)
          NSApp.activate(ignoringOtherApps: true)
        #endif
      }
    }
  }

  // MARK: Dart → 原生

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "activitiesEnabled":
      result(activitiesEnabled())
    case "startPlayback":
      // 封面要先缩略进 App Group（扩展进程读不到 app 沙盒），文件 IO 不占主线程。
      sink.prepareActivityCover(args["attributes"]) { attributes in
        DispatchQueue.main.async { result(self.startPlayback(attributes: attributes, args)) }
      }
    case "updatePlayback":
      updatePlayback(args)
      result(nil)
    case "startTask":
      result(startTask(args))
    case "updateTask":
      updateTask(args)
      result(nil)
    case "endActivity":
      endActivity(
        id: args["id"] as? String, dismissAfter: args["dismissAfter"] as? Double,
        finalState: args["finalState"])
      result(nil)
    case "endAllActivities":
      endAllActivities { result(nil) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 原生 → Dart

  /// 交给 Dart，最多等 3 秒：Dart 回 true = 接住了（例如后台续播成功）。
  /// 引擎没就绪 / 没回话按 false 处理，调用方据此决定是否把 app 带到前台。
  private func sendToDart(action: String, argument: String?) async -> Bool {
    guard let channel else { return false }
    return await withCheckedContinuation { continuation in
      let lock = NSLock()
      var resumed = false
      func finish(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
      }
      DispatchQueue.main.async {
        channel.invokeMethod("action", arguments: ["action": action, "argument": argument as Any]) {
          reply in
          finish((reply as? Bool) ?? false)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
    }
  }

  // MARK: 活动

  private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  /// 排进串行链：等前一个操作做完再做这个（主线程调用）。
  private func enqueueActivity(_ operation: @escaping () async -> Void) {
    let previous = activityChain
    activityChain = Task {
      await previous?.value
      await operation()
    }
  }

  private func activitiesEnabled() -> Bool {
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        return ActivityAuthorizationInfo().areActivitiesEnabled
      }
      return false
    #else
      return true
    #endif
  }

  private func startPlayback(attributes: Any?, _ args: [String: Any]) -> String? {
    guard let info = decode(FushiPlaybackInfo.self, attributes),
      let state = decode(FushiPlaybackContent.self, args["state"])
    else { return nil }
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        guard activitiesEnabled() else { return nil }
        do {
          let activity = try Activity.request(
            attributes: FushiPlaybackAttributes(info),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
          return activity.id
        } catch {
          NSLog("[FushiHomeWidgets] playback activity request failed: \(error)")
        }
      }
      return nil
    #else
      return menuBar.startPlayback(info: info, state: state)
    #endif
  }

  private func updatePlayback(_ args: [String: Any]) {
    guard let id = args["id"] as? String,
      let state = decode(FushiPlaybackContent.self, args["state"])
    else { return }
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        enqueueActivity {
          for activity in Activity<FushiPlaybackAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
          }
        }
      }
    #else
      menuBar.updatePlayback(id: id, state: state)
    #endif
  }

  private func startTask(_ args: [String: Any]) -> String? {
    guard let info = decode(FushiTaskInfo.self, args["attributes"]),
      let state = decode(FushiTaskContent.self, args["state"])
    else { return nil }
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        guard activitiesEnabled() else { return nil }
        do {
          let activity = try Activity.request(
            attributes: FushiTaskAttributes(info),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
          return activity.id
        } catch {
          NSLog("[FushiHomeWidgets] task activity request failed: \(error)")
        }
      }
      return nil
    #else
      return menuBar.startTask(info: info, state: state)
    #endif
  }

  private func updateTask(_ args: [String: Any]) {
    guard let id = args["id"] as? String,
      let state = decode(FushiTaskContent.self, args["state"])
    else { return }
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        enqueueActivity {
          for activity in Activity<FushiTaskAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
          }
        }
      }
    #else
      menuBar.updateTask(id: id, state: state)
    #endif
  }

  /// `dismissAfter`：秒；nil = 立即消失（暂停太久 / 关书）；>0 = 留一会儿（转录完成）。
  /// `finalState`：非 nil 时作为最终内容一步结束（不另发 update）。
  private func endActivity(id: String?, dismissAfter: Double?, finalState: Any?) {
    guard let id else { return }
    let linger = max(0, dismissAfter ?? 0)
    let finalTask = decode(FushiTaskContent.self, finalState)
    let finalPlayback = decode(FushiPlaybackContent.self, finalState)
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        let policy: ActivityUIDismissalPolicy =
          linger > 0 ? .after(Date().addingTimeInterval(linger)) : .immediate
        enqueueActivity {
          for activity in Activity<FushiPlaybackAttributes>.activities where activity.id == id {
            let content = finalPlayback.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: policy)
          }
          for activity in Activity<FushiTaskAttributes>.activities where activity.id == id {
            let content = finalTask.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: policy)
          }
        }
      }
    #else
      _ = finalPlayback
      menuBar.end(id: id, after: linger, finalTask: finalTask)
    #endif
  }

  /// 冷启动时调用：上次进程被杀留下的活动对不上任何会话，一律收掉。**收到调用的这一刻**取
  /// 活动快照，只结束这一批（之后新起的活动不在里面）；全部结束后才回 Dart，Dart 等它再起新活动。
  private func endAllActivities(completion: @escaping () -> Void) {
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        let playback = Activity<FushiPlaybackAttributes>.activities
        let tasks = Activity<FushiTaskAttributes>.activities
        enqueueActivity {
          for activity in playback {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
          for activity in tasks {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
          DispatchQueue.main.async { completion() }
        }
        return
      }
      completion()
    #else
      menuBar.endAll()
      completion()
    #endif
  }
}

/// 主 app 进程里把 Dart 的快照 JSON 落进 App Group（扩展进程读不到 app 沙盒）。
///
/// - JSON 里任何一层的 `cover` 字段若是本机文件（绝对路径 / `file://`），缩略成最长边
///   [maxEdge] 的 JPEG 拷进 `home_widgets/covers/`，改写成相对路径；拿不到 / 远程地址一律改成
///   空串（小组件画类型图标）。文件名 = 源路径 + 修改时间 + 大小的稳定哈希：换了封面就换文件。
/// - `snapshot.json` 先写临时文件再原子替换；之后删掉本次快照与活动都没再引用的封面。
/// - 全部 IO 在一条串行队列上，按到达顺序执行。
final class FushiWidgetSnapshotSink {
  static let maxEdge = 512

  private let queue = DispatchQueue(label: "app.fushi.widgets.snapshot")
  /// 最近一次起的播放活动用的封面（同一时刻只有一个播放活动；prune 时保留）。只在 [queue] 上读写。
  private var activityCover: String?
  /// 上一份快照引用的封面；只在 [queue] 上读写。
  private var snapshotCovers: Set<String> = []

  /// [completion] 在 [queue] 上回调：nil = 成功，否则是错误说明。
  func write(json: String, completion: @escaping (String?) -> Void) {
    queue.async {
      guard let dir = FushiAppGroup.widgetsDirectory else {
        // 没签 App Group：小组件本来就读不到，什么都不写（不是错误）。
        completion(nil)
        return
      }
      guard let data = json.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data)
      else {
        completion("snapshot is not valid JSON")
        return
      }
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var used: Set<String> = []
        let rewritten = self.rewriteCovers(root, in: dir, used: &used)
        let out = try JSONSerialization.data(withJSONObject: rewritten)
        let target = dir.appendingPathComponent("snapshot.json")
        let tmp = dir.appendingPathComponent("snapshot.json.tmp")
        try out.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
          _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } else {
          try FileManager.default.moveItem(at: tmp, to: target)
        }
        self.snapshotCovers = used
        self.prune(in: dir)
        completion(nil)
      } catch {
        completion("\(error)")
      }
    }
  }

  /// 起播放活动前：把 `attributes.cover`（本机绝对路径）换成 App Group 里的相对路径。
  /// [completion] 在 [queue] 上回调，参数是改写后的 attributes。
  func prepareActivityCover(_ attributes: Any?, completion: @escaping (Any?) -> Void) {
    queue.async {
      guard var map = attributes as? [String: Any] else {
        completion(attributes)
        return
      }
      if let dir = FushiAppGroup.widgetsDirectory, let path = map["cover"] as? String,
        let rel = self.coverFile(for: path, in: dir)
      {
        map["cover"] = rel
        self.activityCover = rel
      } else {
        map["cover"] = NSNull()
        self.activityCover = nil
      }
      completion(map)
    }
  }

  private func rewriteCovers(_ value: Any, in dir: URL, used: inout Set<String>) -> Any {
    if var map = value as? [String: Any] {
      for (key, child) in map {
        if key == "cover", let path = child as? String {
          let rel = path.isEmpty ? nil : coverFile(for: path, in: dir)
          if let rel { used.insert(rel) }
          map[key] = rel ?? ""
        } else {
          map[key] = rewriteCovers(child, in: dir, used: &used)
        }
      }
      return map
    }
    if let list = value as? [Any] {
      return list.map { rewriteCovers($0, in: dir, used: &used) }
    }
    return value
  }

  /// 本机封面 → `covers/<hash>.jpg`（已存在就直接用）；失败 / 非本机文件为 nil。
  private func coverFile(for path: String, in dir: URL) -> String? {
    let source: URL
    if path.hasPrefix("file://") {
      guard let url = URL(string: path), url.isFileURL else { return nil }
      source = url
    } else if path.hasPrefix("/") {
      source = URL(fileURLWithPath: path)
    } else {
      return nil
    }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
      let size = attrs[.size] as? NSNumber, size.intValue > 0
    else { return nil }
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let name = "\(Self.stableHash("\(source.path)|\(mtime)|\(size.intValue)")).jpg"
    let rel = "covers/\(name)"
    let coversDir = dir.appendingPathComponent("covers", isDirectory: true)
    let target = coversDir.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: target.path) { return rel }
    do {
      try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
      let thumb = CGImageSourceCreateThumbnailAtIndex(
        image, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: Self.maxEdge,
        ] as CFDictionary)
    else { return nil }
    let tmp = coversDir.appendingPathComponent("\(name).tmp")
    guard
      let destination = CGImageDestinationCreateWithURL(
        tmp as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: tmp)
      return nil
    }
    do {
      try FileManager.default.moveItem(at: tmp, to: target)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      // 并发写同名文件时对方已经写好了。
      return FileManager.default.fileExists(atPath: target.path) ? rel : nil
    }
    return rel
  }

  private func prune(in dir: URL) {
    let coversDir = dir.appendingPathComponent("covers", isDirectory: true)
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: coversDir.path)
    else { return }
    var keep = snapshotCovers
    if let activityCover { keep.insert(activityCover) }
    for name in names where !keep.contains("covers/\(name)") && !name.hasSuffix(".tmp") {
      try? FileManager.default.removeItem(at: coversDir.appendingPathComponent(name))
    }
  }

  /// FNV-1a 64 位（进程间稳定；Swift 的 `hashValue` 每次启动都换种子，不能用来起文件名）。
  static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}
