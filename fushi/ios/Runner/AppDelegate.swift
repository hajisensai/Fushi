import CoreText
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
  private var challengeBrowser: FushiChallengeBrowser?
  /// 强引用：channel handler 只弱持有它，且它自己是文档选择器的 delegate（UIKit 弱引用）。
  private var directoryImport: FushiDirectoryImport?
  /// 系统「降低透明度」订阅（`app.fushi/system_transparency`）。强引用 channel 与
  /// observer token，进程内只装一次。
  private var systemTransparencyChannel: FlutterMethodChannel?
  private var systemTransparencyObserver: NSObjectProtocol?

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
    // 查词浮层的真模糊背衬：WebView 下方的 UIVisualEffectView 平台视图
    // （apple/FushiNativeMaterialView.swift，Dart 侧 fushi_native_material.dart）。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FushiNativeMaterial") {
      FushiNativeMaterial.register(with: registrar)
    }
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
    // 系统自带 OCR（Vision）。Dart 侧与 Android 侧早就在了，这半边一直空着——
    // 没注册时 Dart 收到 MissingPluginException，isAvailable() 返回 false，引擎
    // 选项就静默不出现（system_ocr_channel.dart 的注释把这条定为「当前事实」）。
    FushiSystemOcr.register(binaryMessenger: binaryMessenger)
    // 系统语音转录（iOS 26 的 SpeechAnalyzer）。老系统上原生侧应答「不支持」，
    // Dart 侧据此不把这个引擎放进下拉。
    FushiSpeechTranscriber.register(binaryMessenger: binaryMessenger)
    // 复制图片到剪贴板（视频截图 / 阅读器内联图）。与 macOS 同一份实现，
    // 方法名与入参逐字对齐 Windows 那份 CF_DIB 实现。
    FushiClipboardImage.register(binaryMessenger: binaryMessenger)
    // 全局悬浮球的 iOS 半边：截本 app 窗口给 OCR + App Intent 查词投递
    // （docs/specs/2026-09-28-floating-ball.md）。
    FushiFloatingBall.register(binaryMessenger: binaryMessenger)
    // 查词输入框的输入法语言。install 必须在任何输入框成为第一响应者之前完成——
    // `textInputMode` 是在 becomeFirstResponder **之前**被读的。
    let imeInstalled = LookupImeLanguage.install()
    let lookupImeChannel = FlutterMethodChannel(
      name: "app.fushi.reader/lookup_ime",
      binaryMessenger: binaryMessenger)
    lookupImeChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setLanguage":
        let tag = call.arguments as? String
        LookupImeLanguage.desiredLanguage = (tag?.isEmpty ?? true) ? nil : tag
        result(nil)
      case "probe":
        // 探针：分辨「属性压根没被调用」和「被调用了但系统没采纳返回值」——
        // 这两种失败的修法完全不同（见 LookupImeLanguage 的类注释）。
        result([
          "installed": imeInstalled,
          "desired": LookupImeLanguage.desiredLanguage ?? "",
          "resolveCount": LookupImeLanguage.resolveCount,
          "lastResolved": LookupImeLanguage.lastResolved ?? "",
          "activeInputModes": UITextInputMode.activeInputModes.compactMap {
            $0.primaryLanguage
          },
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    challengeBrowser = FushiChallengeBrowser(binaryMessenger: binaryMessenger) {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?.rootViewController
    }
    // 目录导入（BUG-2786）：iOS 上沙盒外文件夹只能在安全作用域访问窗口内整卷拷进来。
    // 呈现者必须是最顶层的 VC——导入对话框本身就是 Flutter 路由，但若此刻上面还压着
    // 别的原生表单，从 root 直接 present 会被 UIKit 拒掉（静默不弹）。
    directoryImport = FushiDirectoryImport(binaryMessenger: binaryMessenger) {
      var top = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?.rootViewController
      while let presented = top?.presentedViewController {
        top = presented
      }
      return top
    }
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

    // 长按 app 图标的 Home Screen quick actions（Dart 门面
    // lib/src/platform/app_shortcuts.dart）。点击由 SceneDelegate 换成
    // `fushi://shortcut/<id>` 走下面的 url_events，不另起投递通道。
    let appShortcutsChannel = FlutterMethodChannel(
      name: "app.fushi.reader/app_shortcuts",
      binaryMessenger: binaryMessenger)
    appShortcutsChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setShortcuts":
        // Dart 发 {items, disabledMessage}；后者只给 Android 置灰固定快捷方式用，
        // iOS 的 quick actions 整表替换即可，不存在「固定」的残留。
        let args = call.arguments as? [String: Any]
        let items = (args?["items"] as? [[String: String]]) ?? []
        UIApplication.shared.shortcutItems = items.compactMap { item in
          guard let id = item["id"], let title = item["title"],
            let url = item["url"]
          else { return nil }
          return UIApplicationShortcutItem(
            type: Self.appShortcutType(id),
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: Self.appShortcutSymbol(id)),
            userInfo: ["url": url as NSString])
        }
        result(nil)
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

    // 字体库「浏览系统字体」（四端同一契约，见 Windows system_font_list.cpp /
    // Android MainActivity / macOS AppDelegate）：返回 [{family, supportsJapanese?}]。
    let fontsChannel = FlutterMethodChannel(
      name: "app.fushi.reader/fonts",
      binaryMessenger: binaryMessenger)
    fontsChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "listSystemFonts":
        // UIFont 是 UIKit，族名列表在主线程取；逐族 CoreText 字符集探测放后台。
        Self.listSystemFonts(families: UIFont.familyNames, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    installSystemTransparencyChannel(binaryMessenger: binaryMessenger)
  }

  /// 系统设置「辅助功能 → 显示与文字大小 → 降低透明度」：Dart 侧 `SystemTransparency`
  /// 经 `getReduceTransparency` 读一次，之后由这里在状态变化时推
  /// `reduceTransparencyChanged`（与 Windows / macOS 同一契约）。
  private func installSystemTransparencyChannel(binaryMessenger: FlutterBinaryMessenger) {
    guard systemTransparencyChannel == nil else { return }
    let channel = FlutterMethodChannel(
      name: "app.fushi/system_transparency",
      binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getReduceTransparency":
        result(UIAccessibility.isReduceTransparencyEnabled)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    systemTransparencyChannel = channel
    systemTransparencyObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.systemTransparencyChannel?.invokeMethod(
        "reduceTransparencyChanged",
        arguments: UIAccessibility.isReduceTransparencyEnabled)
    }
  }

  /// `listSystemFonts`：过滤 `.` 开头的私有族，按族名大小写不敏感去重、排序，
  /// 后台逐族判日文覆盖，回主线程交结果。判不出覆盖的族省略 `supportsJapanese`。
  private static func listSystemFonts(
    families: [String], result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sorted = families
        .filter { !$0.isEmpty && !$0.hasPrefix(".") }
        .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
      var seen = Set<String>()
      var entries: [[String: Any]] = []
      for family in sorted {
        guard seen.insert(family.lowercased()).inserted else { continue }
        var entry: [String: Any] = ["family": family]
        if let japanese = Self.fontFamilySupportsJapanese(family) {
          entry["supportsJapanese"] = japanese
        }
        entries.append(entry)
      }
      DispatchQueue.main.async { result(entries) }
    }
  }

  /// 该族的常规字形自身（不含系统回退）是否同时覆盖 U+3042「あ」与 U+6F22「漢」。
  /// 按族名描述符解析；若 CoreText 解析到的不是这个族（回退到了默认字体），返回 nil
  /// 表示「判不出」，而不是把回退字体的覆盖冒充成它的。
  private static func fontFamilySupportsJapanese(_ family: String) -> Bool? {
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontFamilyNameAttribute as String: family] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    let resolvedFamily = CTFontCopyFamilyName(font) as String
    guard resolvedFamily.caseInsensitiveCompare(family) == .orderedSame else {
      return nil
    }
    let charset = CTFontCopyCharacterSet(font) as CharacterSet
    let kana: Unicode.Scalar = "\u{3042}"
    let kanji: Unicode.Scalar = "\u{6F22}"
    return charset.contains(kana) && charset.contains(kanji)
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

  private static let appShortcutTypePrefix = "app.fushi.reader.shortcut."

  private static func appShortcutType(_ id: String) -> String {
    return appShortcutTypePrefix + id
  }

  private static func appShortcutSymbol(_ id: String) -> String {
    switch id {
    case "lookup": return "magnifyingglass"
    case "books": return "book"
    case "manga": return "photo.on.rectangle"
    case "video": return "film"
    default: return "app"
    }
  }

  /// 把快捷方式点击交给 Dart。返回 false = 不是本 app 发布的快捷方式。
  @discardableResult
  func deliverShortcut(_ item: UIApplicationShortcutItem) -> Bool {
    guard item.type.hasPrefix(Self.appShortcutTypePrefix) else { return false }
    let url = (item.userInfo?["url"] as? String)
      ?? "fushi://shortcut/" + item.type.dropFirst(Self.appShortcutTypePrefix.count)
    deliverUrl(url)
    return true
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
