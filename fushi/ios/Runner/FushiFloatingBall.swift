import Flutter
import UIKit

#if canImport(AppIntents)
  import AppIntents
#endif

/// 全局悬浮球的 iOS 半边（契约见 docs/specs/2026-09-28-floating-ball.md，
/// 通道 `app.fushi.reader/floating_ball`）。
///
/// iOS 不允许应用外悬浮，所以这里只有三件事：
/// - `captureScreen`：截本 app 自己的窗口（含 WKWebView 内容），交 Dart 做 Vision OCR；
/// - `sensorHousingEdge`：刘海 / 灵动岛在哪条边，应用内球据此只避让那一侧；界面方向
///   变化时原生主动推 `sensorHousingEdgeChanged`（`interfaceOrientationDidChange`）；
/// - App Intent「Look up in Fushi」把快捷指令 / Siri 给的词送进应用内查词弹窗。
///
/// Android 专有的方法（`canDrawOverlays` / `startSystemBall` …）在这里一律
/// `FlutterMethodNotImplemented`，Dart 侧收到 MissingPluginException 自行降级。
///
/// App Intent 投递的握手：意图可能在引擎 / Dart 还没起来时就执行（冷启动），
/// 原生侧**先排队、不盲推**。Dart 装好 `lookupFromIntent` 处理器后调用
/// `takePendingIntentLookup`：取走排队的词，同时宣告「Dart 已就绪」；此后的意图
/// 直接 `invokeMethod("lookupFromIntent")`。这样同一个词不会既被推一次又被取一次。
enum FushiFloatingBall {
  static let channelName = "app.fushi.reader/floating_ball"

  private static var channel: FlutterMethodChannel?
  /// Dart 是否已经调过 `takePendingIntentLookup`（即处理器已装好）。
  /// 引擎重建（新 channel）时清零，等新的 Dart 再宣告一次。
  private static var dartReady = false
  /// 还没送到 Dart 的意图查词（只留最新一条——旧的已经被用户的新请求取代）。
  private static var pendingIntentWord: String?

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "captureScreen":
        captureScreen(result: result)
      case "takePendingIntentLookup":
        dartReady = true
        let word = pendingIntentWord
        pendingIntentWord = nil
        result(word)
      case "sensorHousingEdge":
        result(sensorHousingEdge())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    Self.channel = channel
    dartReady = false
  }

  /// App Intent 执行时调用（主线程）。
  static func deliverIntentLookup(_ word: String) {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard dartReady, let channel = channel else {
      pendingIntentWord = trimmed
      return
    }
    channel.invokeMethod("lookupFromIntent", arguments: ["word": trimmed]) { reply in
      // Dart 处理器已被卸掉（热重启中途等）：退回排队，等下一次 take。
      if let error = reply as? FlutterError {
        NSLog("FushiFloatingBall: lookupFromIntent failed: \(error.code)")
        pendingIntentWord = trimmed
      } else if let reply = reply as? NSObject, reply === FlutterMethodNotImplemented {
        pendingIntentWord = trimmed
        dartReady = false
      }
    }
  }

  /// 截承载 Flutter 视图的窗口。`drawHierarchy` 会把 WKWebView 的内容一起画进来
  /// （`layer.render(in:)` 不会）。输出物理像素（乘屏幕 scale），Dart 按
  /// 「图片尺寸 / 逻辑尺寸」换算坐标。
  private static func captureScreen(result: @escaping FlutterResult) {
    guard let window = hostWindow() else {
      result(
        FlutterError(
          code: "CAPTURE_FAILED",
          message: "No window to capture",
          details: nil))
      return
    }
    let bounds = window.bounds
    guard bounds.width > 0, bounds.height > 0 else {
      result(
        FlutterError(
          code: "CAPTURE_FAILED",
          message: "Window has empty bounds",
          details: nil))
      return
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = window.screen.scale
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
    var drawn = false
    let png = renderer.pngData { _ in
      drawn = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
    }
    guard drawn, !png.isEmpty else {
      result(
        FlutterError(
          code: "CAPTURE_FAILED",
          message: "drawHierarchy failed",
          details: nil))
      return
    }
    result(FlutterStandardTypedData(bytes: png))
  }

  /// 界面方向变了（SceneDelegate 的 `windowScene(_:didUpdate:interfaceOrientation:…)`
  /// 转进来，主线程）：主动把新的外壳边推给 Dart（BUG-2911）。
  ///
  /// 必须推而不是等 Dart 重查：横屏左 ↔ 右翻转 180° 时窗口尺寸不变、左右安全区
  /// 又对称，Flutter 的 metrics 不一定变，Dart 的 didChangeMetrics 不一定触发。
  /// 时机取舍：`viewWillTransition(to:with:)` 开头 `interfaceOrientation` 还是旧值，
  /// 那里推只会推旧边；scene 的这条回调在 `interfaceOrientation` 更新之后才来，
  /// 推出去的一定是新值，代价是可能比 Flutter 收到新 inset 晚一点（左 ↔ 右翻转时
  /// 那一两帧球还按旧边算，随后挪正）。Dart 没装处理器时消息无人接，Dart 起来后的
  /// 首次查询会补上。
  static func interfaceOrientationDidChange(_ orientation: UIInterfaceOrientation) {
    channel?.invokeMethod(
      "sensorHousingEdgeChanged", arguments: sensorHousingEdge(for: orientation))
  }

  /// 传感器外壳（刘海 / 灵动岛）此刻在屏幕的哪条边：`left` / `top` / `right` / `bottom`，
  /// 方向未知时 nil。
  ///
  /// iOS 横屏的 `safeAreaInsets` 左右**对称**（两侧都是外壳深度），Flutter 也不上报
  /// cutout 的 displayFeatures，Dart 分不出哪一侧真被挡住；外壳永远在设备「顶边」，
  /// 所以按界面方向换算即可。`landscapeRight` = Home 侧在右 → 顶边在左。
  private static func sensorHousingEdge() -> String? {
    guard let scene = hostWindow()?.windowScene else { return nil }
    return sensorHousingEdge(for: scene.interfaceOrientation)
  }

  private static func sensorHousingEdge(for orientation: UIInterfaceOrientation) -> String? {
    switch orientation {
    case .portrait: return "top"
    case .portraitUpsideDown: return "bottom"
    case .landscapeRight: return "left"
    case .landscapeLeft: return "right"
    default: return nil
    }
  }

  /// 前台活跃场景里的 key window；没有就退到任意一个前台窗口，再退到任意窗口。
  private static func hostWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.filter { $0.activationState == .foregroundActive }
    let activeWindows = active.flatMap { $0.windows }
    if let key = activeWindows.first(where: { $0.isKeyWindow }) {
      return key
    }
    if let flutter = activeWindows.first(where: { $0.rootViewController is FlutterViewController }) {
      return flutter
    }
    return activeWindows.first ?? scenes.flatMap { $0.windows }.first
  }
}

#if canImport(AppIntents)
  /// 「Look up in Fushi」：快捷指令 / Siri / 操作按钮可用。主 app target 内实现，
  /// 不新增扩展 target、不需要新 entitlement。`openAppWhenRun` 让系统先把 app
  /// 拉到前台再执行 perform()，查词弹窗是应用内的。
  @available(iOS 16.0, *)
  struct LookupInFushiIntent: AppIntent {
    static var title: LocalizedStringResource = "Look up in Fushi"
    static var description = IntentDescription(
      "Opens Fushi and looks the word up in your dictionaries.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Word")
    var word: String

    static var parameterSummary: some ParameterSummary {
      Summary("Look up \(\.$word) in Fushi")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
      FushiFloatingBall.deliverIntentLookup(word)
      return .result()
    }
  }

  /// 让意图不经用户配置就出现在快捷指令 / Siri 里。短语必须含 `.applicationName`；
  /// String 参数不能放进短语，Siri 会按 @Parameter 追问要查的词。
  @available(iOS 16.0, *)
  struct FushiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
      AppShortcut(
        intent: LookupInFushiIntent(),
        phrases: [
          "Look up in \(.applicationName)",
          "Look up a word in \(.applicationName)",
        ])
    }
  }
#endif
