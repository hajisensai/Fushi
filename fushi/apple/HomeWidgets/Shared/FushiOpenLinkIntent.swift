import Foundation

#if canImport(AppIntents)
  import AppIntents

  /// 控制中心 / 锁屏快捷键位 / Action 按钮上的入口：把 app 带到前台并打开一条 `fushi://`
  /// 链接（查词、拍照查词、开始复习……）。`openAppWhenRun` 保证 `perform()` 在 app 进程里、
  /// 前台执行；链接交给 SceneDelegate → `url_events`（macOS：AppDelegate → `source_urls`），
  /// 与图标快捷菜单同一个落地口。
  @available(iOS 17.0, macOS 14.0, *)
  struct FushiOpenLinkIntent: AppIntent {
    static var title: LocalizedStringResource { "Open in Fushi" }
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Link")
    var url: String

    /// true：先试着在 app 里续播（Dart `resume`），续不上再打开 [url]（macOS 的「接着听」控件）。
    @Parameter(title: "Resume playback", default: false)
    var resume: Bool

    init() {}
    init(url: String, resume: Bool = false) {
      self.url = url
      self.resume = resume
    }

    @MainActor
    func perform() async throws -> some IntentResult {
      if resume, await FushiIntentRelay.send("resume", nil) {
        return .result()
      }
      await FushiIntentRelay.openInForeground(url)
      return .result()
    }
  }
#endif
