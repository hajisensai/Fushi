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

    init() {}
    init(url: String) { self.url = url }

    @MainActor
    func perform() async throws -> some IntentResult {
      await FushiIntentRelay.openInForeground(url)
      return .result()
    }
  }
#endif
