import Foundation
import LocalAuthentication

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// 上锁作品的系统验证（拍板台 qiqSbvdxrk，Dart 侧 `media_lock_auth.dart`）：
/// `app.fushi.reader/device_owner_auth` 的 iOS / macOS 实现。
///
/// 用 `LAPolicy.deviceOwnerAuthentication`：Face ID / Touch ID / Optic ID 优先，认不出
/// 时系统自己退到设备密码（iOS）/ 登录密码（macOS）——正是「生物识别 / 设备锁屏兜底」。
/// Face ID 需要 Info.plist 的 `NSFaceIDUsageDescription`。
///
/// 结果约定与 Android / Windows 相同：`"success"` / `"failed"`（取消或没通过）/
/// `"unavailable"`（没设密码 / 不支持）。
enum FushiDeviceOwnerAuth {
  static let channelName = "app.fushi.reader/device_owner_auth"

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        var error: NSError?
        result(LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error))
      case "authenticate":
        let args = call.arguments as? [String: Any]
        let reason = (args?["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? " "
        authenticate(reason: reason, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func authenticate(reason: String, result: @escaping FlutterResult) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      result("unavailable")
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
      DispatchQueue.main.async {
        result(ok ? "success" : "failed")
      }
    }
  }
}
