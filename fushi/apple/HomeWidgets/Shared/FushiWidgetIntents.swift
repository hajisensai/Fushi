import Foundation

#if canImport(AppIntents)
  import AppIntents
#endif

/// 小组件 / Live Activity / 控制中心按钮发给 app 的动作。主 app 与扩展都编译本文件；
/// `handler` / `foregroundOpener` 只有主 app 会装（`FushiHomeWidgets.install`），扩展进程里
/// 恒为 nil。`LiveActivityIntent` / `AudioPlaybackIntent` / `openAppWhenRun` 的 `perform()`
/// 由系统放到 **app 进程** 里执行，所以能拿到它们。
enum FushiIntentRelay {
  /// 把动作交给 Dart，返回 Dart 是否接住。
  nonisolated(unsafe) static var handler:
    ((_ action: String, _ argument: String?) async -> Bool)?

  /// 前台打开一条 `fushi://` 链接（iOS：SceneDelegate → url_events；macOS：source_urls）。
  nonisolated(unsafe) static var foregroundOpener: ((String) async -> Void)?

  /// 后台续播接不住时「把 app 带到前台再打开 url」的那个错误。只有主 app 能造：
  /// `ForegroundContinuableIntent` 在扩展里不可用，一致性声明在 Runner 那边
  /// （FushiHomeWidgets.swift），扩展里这里恒为 nil。
  nonisolated(unsafe) static var continueInForeground: ((String) -> Error)?

  static func send(_ action: String, _ argument: String? = nil) async -> Bool {
    guard let handler else { return false }
    return await handler(action, argument)
  }

  static func openInForeground(_ url: String) async {
    await foregroundOpener?(url)
  }
}

#if canImport(AppIntents) && os(iOS)
  @available(iOS 17.0, *)
  enum FushiPlaybackAction: String, AppEnum {
    case toggle
    case previous
    case next
    case favorite

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Playback action" }
    static var caseDisplayRepresentations: [FushiPlaybackAction: DisplayRepresentation] {
      [
        .toggle: "Play / pause",
        .previous: "Previous sentence",
        .next: "Next sentence",
        .favorite: "Save sentence",
      ]
    }
  }

  /// Live Activity 上的 上一句 / 播放暂停 / 下一句 / 收藏这句。
  @available(iOS 17.0, *)
  struct FushiPlaybackControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Control Fushi playback" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Action")
    var action: FushiPlaybackAction

    init() {}
    init(action: FushiPlaybackAction) { self.action = action }

    func perform() async throws -> some IntentResult {
      _ = await FushiIntentRelay.send("playback", action.rawValue)
      return .result()
    }
  }

  /// 主屏「接着听」/ 控制中心「接着听」。app 进程活着且会话还在（例如有声书刚暂停、
  /// 在后台）就直接后台续播；不行就把 app 带到前台，经 `url`（`fushi://widget/resume_audiobook`）
  /// 走与点击条目相同的打开路径——不在后台硬起一个没有界面的 Flutter 引擎。
  ///
  /// `AudioPlaybackIntent` 的 `perform()` 由系统放进 app 进程执行；前台续接的一致性
  /// （`ForegroundContinuableIntent`）只能在主 app 里声明，见 [FushiIntentRelay.continueInForeground]。
  @available(iOS 17.0, *)
  struct FushiResumeAudiobookIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Resume audiobook" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Link")
    var url: String

    init() {}
    init(url: String) { self.url = url }

    func perform() async throws -> some IntentResult {
      if await FushiIntentRelay.send("resumeAudiobook", url) {
        return .result()
      }
      if let makeError = FushiIntentRelay.continueInForeground {
        throw makeError(url)
      }
      return .result()
    }
  }
#endif
