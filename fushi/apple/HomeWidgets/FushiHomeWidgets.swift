import Foundation
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

/// 主屏小组件 / Live Activity / 菜单栏播放条的原生半边（Dart 侧 `lib/src/platform/home_widgets/`）。
///
/// - 快照：Dart 问 `containerPath` 拿到 App Group 目录，自己写 `home_widgets/snapshot.json`
///   与封面，再调 `reloadWidgets`。没签 App Group 时 `containerPath` 回 nil，Dart 整段不写。
/// - 活动：iOS 上 `start*` / `update*` / `end` 直接映射 ActivityKit（灵动岛 + 锁屏）；macOS 没有
///   Live Activity，同一组调用驱动菜单栏播放条 [FushiMenuBarActivities]。
/// - 反方向：小组件 / Live Activity / 菜单栏按钮经 [FushiIntentRelay] 走本通道的 `action`
///   交给 Dart，Dart 返回是否接住。
final class FushiHomeWidgets {
  static let shared = FushiHomeWidgets()
  static let channelName = "app.fushi.reader/home_widgets"

  private var channel: FlutterMethodChannel?

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
    FushiIntentRelay.handler = { [weak self] action, argument in
      await self?.sendToDart(action: action, argument: argument) ?? false
    }
    #if os(iOS)
      if #available(iOS 17.0, *) {
        FushiIntentRelay.continueInForeground = { url in
          FushiResumeAudiobookIntent(url: url).needsToContinueInForegroundError {
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
    case "containerPath":
      guard let dir = FushiAppGroup.widgetsDirectory else {
        result(nil)
        return
      }
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      result(dir.path)
    case "reloadWidgets":
      WidgetCenter.shared.reloadAllTimelines()
      result(true)
    case "activitiesEnabled":
      result(activitiesEnabled())
    case "startPlayback":
      result(startPlayback(args))
    case "updatePlayback":
      updatePlayback(args)
      result(nil)
    case "startTask":
      result(startTask(args))
    case "updateTask":
      updateTask(args)
      result(nil)
    case "endActivity":
      endActivity(id: args["id"] as? String, dismissAfter: args["dismissAfter"] as? Double)
      result(nil)
    case "endAllActivities":
      endAllActivities()
      result(nil)
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

  private func startPlayback(_ args: [String: Any]) -> String? {
    guard let info = decode(FushiPlaybackInfo.self, args["attributes"]),
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
        guard
          let activity = Activity<FushiPlaybackAttributes>.activities.first(where: { $0.id == id })
        else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
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
        guard let activity = Activity<FushiTaskAttributes>.activities.first(where: { $0.id == id })
        else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
      }
    #else
      menuBar.updateTask(id: id, state: state)
    #endif
  }

  /// `dismissAfter`：秒；nil = 立即消失（暂停太久 / 关书）；>0 = 留一会儿（转录完成）。
  private func endActivity(id: String?, dismissAfter: Double?) {
    guard let id else { return }
    let linger = max(0, dismissAfter ?? 0)
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        let policy: ActivityUIDismissalPolicy =
          linger > 0 ? .after(Date().addingTimeInterval(linger)) : .immediate
        Task {
          for activity in Activity<FushiPlaybackAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: policy)
          }
          for activity in Activity<FushiTaskAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: policy)
          }
        }
      }
    #else
      menuBar.end(id: id, after: linger)
    #endif
  }

  /// 冷启动时调用：上次进程被杀留下的活动对不上任何会话，一律收掉。
  private func endAllActivities() {
    #if canImport(ActivityKit) && os(iOS)
      if #available(iOS 16.2, *) {
        Task {
          for activity in Activity<FushiPlaybackAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
          for activity in Activity<FushiTaskAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
        }
      }
    #else
      menuBar.endAll()
    #endif
  }
}
