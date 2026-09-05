import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, FlutterImplicitEngineDelegate {
  private static let ankiMobilePasteboardType = "net.ankimobile.json"
  /// BUG-2150: how long to wait for the app to actually become active after an
  /// AnkiMobile x-callback return before giving up and reading anyway.
  private static let ankiMobilePasteboardActiveTimeout: TimeInterval = 5
  private var initialUrl: String?
  private var urlEventSink: FlutterEventSink?
  private var ankiMobileMediaBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private let aidokuRuntimeQueue = DispatchQueue(
    label: "app.fushi.reader.aidoku-runtime",
    qos: .userInitiated)

  // TODO-057: brightness override applied during a video session. We snapshot
  // the user's brightness the first time the player asks (getBrightness) and
  // restore it on exit (restoreBrightness) so dragging never leaves the system
  // brightness permanently changed.
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    installChannels(binaryMessenger: engineBridge.applicationRegistrar.messenger())
  }

  /// 安装来源判据 = 系统写进 bundle 的 App Store 收据文件，不是猜测：
  /// - App Store 安装 → `.../receipt`
  /// - TestFlight 安装 → `.../sandboxReceipt`
  /// - 侧载 / 自签 / Xcode 直接跑 → 收据**文件不存在**（`appStoreReceiptURL` 仍给得
  ///   出路径，所以必须查文件是否真的在，只看文件名会把侧载误判成 TestFlight）。
  private static func currentInstallSource() -> String {
    guard let receiptUrl = Bundle.main.appStoreReceiptURL,
      FileManager.default.fileExists(atPath: receiptUrl.path)
    else {
      return "sideload"
    }
    return receiptUrl.lastPathComponent == "sandboxReceipt" ? "testFlight" : "appStore"
  }

  private func installChannels(binaryMessenger: FlutterBinaryMessenger) {
    let splashChannel = FlutterMethodChannel(
      name: "app.fushi.reader/splash",
      binaryMessenger: binaryMessenger)
    splashChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getSplashColor":
        // LaunchScreen.storyboard uses a white root view / LaunchBackground.
        result(0xFFFFFFFF)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let ankiMobileChannel = FlutterMethodChannel(
      name: "app.fushi.reader/ankimobile",
      binaryMessenger: binaryMessenger)
    ankiMobileChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "consumeInfoForAddingPasteboard":
        Self.consumeAnkiMobilePasteboard(result: result)
      case "beginMediaImportBackgroundTask":
        self?.beginAnkiMobileMediaBackgroundTask()
        result(nil)
      case "endMediaImportBackgroundTask":
        self?.endAnkiMobileMediaBackgroundTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let urlMethodChannel = FlutterMethodChannel(
      name: "app.fushi.reader/url_events",
      binaryMessenger: binaryMessenger)
    urlMethodChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "getInitialUrl":
        result(self?.initialUrl)
        self?.initialUrl = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let urlEventChannel = FlutterEventChannel(
      name: "app.fushi.reader/url_events/stream",
      binaryMessenger: binaryMessenger)
    urlEventChannel.setStreamHandler(self)

    let brightnessChannel = FlutterMethodChannel(
      name: "app.fushi.reader/screen_brightness",
      binaryMessenger: binaryMessenger)
    brightnessChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getBrightness":
        // UIScreen.brightness is 0...1; main-thread read.
        result(Double(UIScreen.main.brightness))
      case "setBrightness":
        guard let value = call.arguments as? NSNumber else {
          result(FlutterError(
            code: "INVALID_ARG",
            message: "setBrightness requires a number 0..1",
            details: nil))
          return
        }
        let clamped = max(0.0, min(1.0, value.doubleValue))
        UIScreen.main.brightness = CGFloat(clamped)
        result(nil)
      case "restoreBrightness":
        // The Dart side passes the snapshot it took on entry; write it back.
        // nil means "do not touch" (no snapshot available) — leave as-is.
        if let value = call.arguments as? NSNumber {
          let clamped = max(0.0, min(1.0, value.doubleValue))
          UIScreen.main.brightness = CGFloat(clamped)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // 更新落地入口分流（Dart 侧 IosUpdater.resolveDownloadLanding）。iOS 有三条互不
    // 相干的分发链路 —— App Store / TestFlight / GitHub 未签名 ipa 侧载 —— 而「该去
    // 哪儿更新」只由「这份 app 是从哪儿装来的」决定。这里回答的就是这一个事实。
    let updateChannel = FlutterMethodChannel(
      name: "app.fushi.reader/update",
      binaryMessenger: binaryMessenger)
    updateChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getInstallSource":
        result(Self.currentInstallSource())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let aidokuRuntimeChannel = FlutterMethodChannel(
      name: "app.fushi.reader/aidoku_runtime",
      binaryMessenger: binaryMessenger)
    aidokuRuntimeChannel.setMethodCallHandler { [weak self] (call, result) in
      guard call.method == "invoke" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let request = call.arguments as? [String: Any],
        JSONSerialization.isValidJSONObject(request),
        let requestData = try? JSONSerialization.data(withJSONObject: request),
        let requestJson = String(data: requestData, encoding: .utf8)
      else {
        result(FlutterError(
          code: "INVALID_REQUEST",
          message: "Aidoku runtime request must be a JSON object",
          details: nil))
        return
      }
      guard let self = self else {
        result(FlutterError(
          code: "RUNTIME_UNAVAILABLE",
          message: "Aidoku runtime channel was released",
          details: nil))
        return
      }
      self.aidokuRuntimeQueue.async {
        let responsePointer = requestJson.withCString { pointer in
          fushi_aidoku_invoke(pointer)
        }
        guard let responsePointer else {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "RUNTIME_FAILED",
              message: "Aidoku runtime returned no response",
              details: nil))
          }
          return
        }
        let responseJson = String(cString: responsePointer)
        fushi_aidoku_string_free(responsePointer)
        let responseData = Data(responseJson.utf8)
        guard
          let response = try? JSONSerialization.jsonObject(with: responseData),
          let responseObject = response as? [String: Any]
        else {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "INVALID_RESPONSE",
              message: "Aidoku runtime returned invalid JSON",
              details: responseJson))
          }
          return
        }
        DispatchQueue.main.async {
          if let message = responseObject["error"] as? String {
            // 整个错误信封原样透传：`CLOUDFLARE_CHALLENGE` 带 `challengeUrl`，
            // Dart 侧靠它决定在 WebView 里打开哪一页解题（BUG-1876）。
            result(FlutterError(
              code: responseObject["code"] as? String ?? "RUNTIME_FAILED",
              message: message,
              details: responseObject))
          } else {
            result(responseObject)
          }
        }
      }
    }
  }

  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    deliverUrl(url.absoluteString)
    let handled = super.application(application, open: url, options: options)
    return handled || url.scheme == "fushi"
  }

  func deliverUrl(_ url: String) {
    if let sink = urlEventSink {
      sink(url)
    } else {
      initialUrl = url
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    urlEventSink = events
    if let url = initialUrl {
      events(url)
      initialUrl = nil
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    urlEventSink = nil
    return nil
  }

  /// 读取 AnkiMobile 经系统剪贴板回传的 `infoForAdding` JSON（BUG-2150）。
  ///
  /// 前置条件不是「URL 回调到了」，而是「app 真的 active 了」：iOS 只允许**前台活跃**
  /// 的 app 读别的 app 写进通用剪贴板的内容，iOS 16+ 还要为此弹一次系统「允许粘贴」
  /// 确认，而这个弹窗只有 active 的 app 能呈现。AnkiMobile 的
  /// `x-success=fushi://ankiFetch` 把我们拉回前台时，系统的调用顺序是
  /// `willEnterForeground` → `application(_:open:)` → `didBecomeActive`，也就是说
  /// URL 回调整个跑在 `.inactive` 阶段。旧实现就在这一刻直接读剪贴板，必然拿到 nil，
  /// 用户看到的却是「剪贴板上没有 AnkiMobile 配置」——一句与事实无关的错误。
  ///
  /// 非 active 时挂一次性 `didBecomeActiveNotification` 观察者，等真正活跃后再读；
  /// 万一始终等不到（用户又切走了），超时后**不读**、如实报 `notActive`，而不是
  /// 无限挂起让 Dart 侧的 Future 永不完成。
  ///
  /// 超时后不能"尽力读一次"：非 active 下 `data(forPasteboardType:)` 必然返回 nil，
  /// 而 `contains(pasteboardTypes:)` 仍看得见类型（只查元数据），于是三态判定会落到
  /// `denied` —— 把「app 还没回到前台」谎报成「iOS 拒绝了粘贴」，用户被指去改一个
  /// 根本没出问题的权限。这正是 BUG-2150 要消灭的那类误导诊断。
  private static func consumeAnkiMobilePasteboard(result: @escaping FlutterResult) {
    if UIApplication.shared.applicationState == .active {
      result(readAnkiMobilePasteboard())
      return
    }

    var observer: NSObjectProtocol? = nil
    var timeout: DispatchWorkItem? = nil
    var finished = false
    // FlutterResult 必须恰好回调一次：两条路径（变 active / 超时）共用这道闸门。
    // `becameActive` 决定读不读剪贴板——超时那条路径下 app 仍非 active，读出来的
    // 三态没有意义（必落 denied），只能如实报 notActive。
    let finish = { (becameActive: Bool) in
      guard !finished else { return }
      finished = true
      timeout?.cancel()
      if let observer = observer {
        NotificationCenter.default.removeObserver(observer)
      }
      guard becameActive else {
        result(["status": "notActive"])
        return
      }
      result(readAnkiMobilePasteboard())
    }

    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in finish(true) }

    let work = DispatchWorkItem { finish(false) }
    timeout = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + ankiMobilePasteboardActiveTimeout,
      execute: work)
  }

  /// 三态读取（BUG-2150）。这三种情形用户的下一步动作完全不同，压成一句
  /// 「剪贴板上没有 AnkiMobile 配置」只会把人带进死路：
  /// - `ok`：读到 JSON，按官方手册取走后清空剪贴板；
  /// - `denied`：剪贴板上**确实有** AnkiMobile 写的数据，但系统不让读——用户选了
  ///   「不允许粘贴」，或此刻根本弹不出确认；
  /// - `empty`：AnkiMobile 压根没写，通常是用户没在 AnkiMobile 里同意那次请求。
  ///
  /// `contains(pasteboardTypes:)` 只查元数据、不访问内容，不会触发粘贴确认弹窗，
  /// 因此可以拿它把 `denied` 和 `empty` 分开。
  /// 「类型在但内容为空」归 `empty`：那是我们自己取走后写回的空 Data（重复消费同一次
  /// 回调时会撞上），不是被拒绝。
  private static func readAnkiMobilePasteboard() -> [String: Any] {
    let data = UIPasteboard.general.data(
      forPasteboardType: ankiMobilePasteboardType)
    if let data = data, !data.isEmpty,
      let json = String(data: data, encoding: .utf8), !json.isEmpty
    {
      // 官方手册要求取走后清空剪贴板。
      UIPasteboard.general.setData(
        Data(),
        forPasteboardType: ankiMobilePasteboardType)
      return ["status": "ok", "json": json]
    }
    if data != nil {
      return ["status": "empty"]
    }
    let hasType = UIPasteboard.general.contains(
      pasteboardTypes: [ankiMobilePasteboardType])
    return ["status": hasType ? "denied" : "empty"]
  }

  private func beginAnkiMobileMediaBackgroundTask() {
    endAnkiMobileMediaBackgroundTask()
    ankiMobileMediaBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "AnkiMobile media import"
    ) { [weak self] in
      self?.endAnkiMobileMediaBackgroundTask()
    }
  }

  private func endAnkiMobileMediaBackgroundTask() {
    guard ankiMobileMediaBackgroundTask != .invalid else { return }
    let task = ankiMobileMediaBackgroundTask
    ankiMobileMediaBackgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }
}
