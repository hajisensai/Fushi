import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统「降低透明度 / 关闭透明效果」无障碍设置的 Dart 侧镜像。
///
/// Flutter 引擎只经 `AccessibilityFeatures` 暴露 reduceMotion 等信号，没有
/// reduceTransparency，所以走自有原生通道 `app.fushi/system_transparency`：
/// - Dart → 原生 `getReduceTransparency`：返回 `bool`，启动时读一次；
/// - 原生 → Dart `reduceTransparencyChanged`(`bool`)：系统设置变化时推送。
///
/// 各平台来源：
/// - **Windows**：`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`
///   的 `EnableTransparency`（DWORD，0 = 「透明效果」关闭 → true）；主窗口收到
///   `WM_SETTINGCHANGE("ImmersiveColorSet")` 时重读并按值去重推送
///   （`windows/runner/system_transparency_channel.cpp`）。
/// - **macOS**：`NSWorkspace.accessibilityDisplayShouldReduceTransparency`，订阅
///   `accessibilityDisplayOptionsDidChangeNotification`（`macos/Runner/AppDelegate.swift`）。
/// - **iOS**：`UIAccessibility.isReduceTransparencyEnabled`，订阅
///   `reduceTransparencyStatusDidChangeNotification`（`ios/Runner/AppDelegate.swift`）。
///
/// 没有的平台：
/// - **Android**：系统没有「降低透明度」级别的全局无障碍设置（只有移除动画、高对比度
///   文字等），无从读取，恒为 false。
/// - **Linux**：桌面环境各自为政（GNOME / KDE 无统一的透明度无障碍键），不做，恒为 false。
/// - Web 同样 no-op。
///
/// 任何平台异常（`PlatformException` / `MissingPluginException`，例如原生侧未注册）
/// 一律吞掉并保持 false——玻璃材质的退化只是视觉偏好，不能因此影响启动。
class SystemTransparency {
  SystemTransparency._();

  /// 通道名，与三端原生实现逐字一致。
  static const String channelName = 'app.fushi/system_transparency';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// true = 用户在系统里开启了「降低透明度」（Windows：关闭了透明效果），
  /// 玻璃表面应退回实心表面。
  static final ValueNotifier<bool> reduceTransparency = ValueNotifier<bool>(
    false,
  );

  static bool _initialized = false;

  /// 当前平台是否有原生实现。
  static bool get isSupported {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// 读一次当前值写入 [reduceTransparency]，并订阅原生推送。幂等；不支持的平台
  /// 直接返回。先挂推送处理器再读，避免读取期间的变化被漏掉。
  static Future<void> initialize() async {
    if (_initialized || !isSupported) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final bool? value = await _channel.invokeMethod<bool>(
        'getReduceTransparency',
      );
      if (value != null) reduceTransparency.value = value;
    } on PlatformException {
      // 原生侧读取失败：保持当前值（默认 false）。
    } on MissingPluginException {
      // 原生侧未注册（旧构建 / 测试环境）：保持 false。
    }
  }

  static Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'reduceTransparencyChanged') {
      final Object? value = call.arguments;
      if (value is bool) reduceTransparency.value = value;
    }
    return null;
  }

  /// 测试用：解除通道处理器并恢复初始状态。
  @visibleForTesting
  static void debugReset() {
    _channel.setMethodCallHandler(null);
    _initialized = false;
    reduceTransparency.value = false;
  }
}
