import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, FlutterImplicitEngineDelegate {
  private static let ankiMobilePasteboardType = "net.ankimobile.json"
  private var initialUrl: String?
  private var urlEventSink: FlutterEventSink?
  private var ankiMobileMediaBackgroundTask: UIBackgroundTaskIdentifier = .invalid

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

  private func installChannels(binaryMessenger: FlutterBinaryMessenger) {
    let splashChannel = FlutterMethodChannel(
      name: "app.hibiki.reader/splash",
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
      name: "app.hibiki.reader/ankimobile",
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
      name: "app.hibiki.reader/url_events",
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
      name: "app.hibiki.reader/url_events/stream",
      binaryMessenger: binaryMessenger)
    urlEventChannel.setStreamHandler(self)

    let brightnessChannel = FlutterMethodChannel(
      name: "app.hibiki.reader/screen_brightness",
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
  }

  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    deliverUrl(url.absoluteString)
    let handled = super.application(application, open: url, options: options)
    return handled || url.scheme == "hibiki"
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
