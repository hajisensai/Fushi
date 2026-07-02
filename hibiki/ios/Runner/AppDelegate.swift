import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  // TODO-057: brightness override applied during a video session. We snapshot
  // the user's brightness the first time the player asks (getBrightness) and
  // restore it on exit (restoreBrightness) so dragging never leaves the system
  // brightness permanently changed.
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let brightnessChannel = FlutterMethodChannel(
        name: "app.hibiki.reader/screen_brightness",
        binaryMessenger: controller.binaryMessenger)
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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
