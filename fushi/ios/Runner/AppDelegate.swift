import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, FlutterImplicitEngineDelegate {
  private static let ankiMobilePasteboardType = "net.ankimobile.json"
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
        if let data = UIPasteboard.general.data(
          forPasteboardType: Self.ankiMobilePasteboardType
        ) {
          UIPasteboard.general.setData(
            Data(),
            forPasteboardType: Self.ankiMobilePasteboardType)
          result(String(data: data, encoding: .utf8))
        } else {
          result(nil)
        }
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
            result(FlutterError(
              code: responseObject["code"] as? String ?? "RUNTIME_FAILED",
              message: message,
              details: nil))
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
