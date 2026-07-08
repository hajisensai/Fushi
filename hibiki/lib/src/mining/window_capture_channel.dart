import 'package:flutter/services.dart';

/// TODO-1162 外部窗口挖矿 M0（仅 Windows）：枚举系统可见顶层窗口 + 对选定窗口抓一帧
/// 静态截图（Windows.Graphics.Capture 单帧），经 MethodChannel 返回给 Dart。
///
/// native 侧（`hibiki/windows/runner/window_capture.cpp`）注册 `window_capture`
/// channel，暴露两个方法：
///   - `listWindows` -> `List<Map>`：每项 `{hwnd:int, title:String}`。
///   - `captureWindow` -> `Map`：`{pngBytes:Uint8List}` 或 `{error:String}`。
///
/// native 缺失（未构建 / 非 Windows / 旧 Windows 无 WGC）时，两个方法都以
/// [MissingPluginException] / [PlatformException] 收敛为空列表 / error 结果——
/// 调用方据此降级（不崩、不静默假成功）。
abstract final class WindowCaptureChannel {
  static const MethodChannel _channel =
      MethodChannel('app.hibiki.reader/window_capture');

  /// 枚举当前可捕获的顶层窗口（有标题、可见、非本 app 自身）。native 不可用或无窗口
  /// 时返回空列表（调用方按空列表提示「未找到窗口」，不崩）。
  static Future<List<ExternalWindowInfo>> listWindows() async {
    try {
      final List<Object?>? raw =
          await _channel.invokeListMethod<Object?>('listWindows');
      if (raw == null) {
        return const <ExternalWindowInfo>[];
      }
      final List<ExternalWindowInfo> out = <ExternalWindowInfo>[];
      for (final Object? item in raw) {
        if (item is Map) {
          final ExternalWindowInfo? info = ExternalWindowInfo.fromMap(item);
          if (info != null) {
            out.add(info);
          }
        }
      }
      return out;
    } on PlatformException {
      return const <ExternalWindowInfo>[];
    } on MissingPluginException {
      return const <ExternalWindowInfo>[];
    }
  }

  /// 对 [hwnd] 指向的窗口抓一帧静态截图（PNG 字节）。成功返回带 [WindowCaptureResult.pngBytes]，
  /// 失败（窗口已关 / DRM 黑帧 / WGC 不支持 / native 缺失）返回带 [WindowCaptureResult.error]
  /// 的结果（fail-open，绝不抛给调用方）。
  static Future<WindowCaptureResult> captureWindow(int hwnd) async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'captureWindow',
        <String, Object?>{'hwnd': hwnd},
      );
      return WindowCaptureResult.fromMap(r ?? const <Object?, Object?>{});
    } on PlatformException catch (e) {
      return WindowCaptureResult(error: e.message ?? 'capture failed');
    } on MissingPluginException {
      return const WindowCaptureResult(error: 'window_capture unavailable');
    }
  }
}

/// 一个可捕获的外部顶层窗口：native HWND（作为 [int] 传回）+ 窗口标题。
class ExternalWindowInfo {
  const ExternalWindowInfo({required this.hwnd, required this.title});

  /// native 窗口句柄 HWND，作为整数在 MethodChannel 上传输（回传 native 时原样带回）。
  final int hwnd;

  /// 窗口标题（GetWindowText），供 UI 展示与选择。
  final String title;

  /// 从 native map 解析；缺 `hwnd`（无有效句柄）返回 null（跳过该项）。
  static ExternalWindowInfo? fromMap(Map<Object?, Object?> m) {
    final Object? h = m['hwnd'];
    if (h is! int) {
      return null;
    }
    return ExternalWindowInfo(
      hwnd: h,
      title: (m['title'] as String?) ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExternalWindowInfo && other.hwnd == hwnd && other.title == title;

  @override
  int get hashCode => Object.hash(hwnd, title);
}

/// [WindowCaptureChannel.captureWindow] 的结果：成功带 PNG 字节，失败带人类可读原因。
class WindowCaptureResult {
  const WindowCaptureResult({this.pngBytes, this.error});

  /// 捕获到的 PNG 图像字节（成功时非空）。
  final Uint8List? pngBytes;

  /// 失败原因（成功时为 null）。
  final String? error;

  /// true = 成功拿到非空图像字节。
  bool get ok => error == null && pngBytes != null && pngBytes!.isNotEmpty;

  static WindowCaptureResult fromMap(Map<Object?, Object?> m) =>
      WindowCaptureResult(
        pngBytes: m['pngBytes'] as Uint8List?,
        error: m['error'] as String?,
      );
}
