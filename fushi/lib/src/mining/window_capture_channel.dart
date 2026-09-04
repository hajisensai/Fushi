import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// TODO-1162 外部窗口挖矿 M0（仅 Windows）：枚举系统可见顶层窗口 + 对选定窗口抓一帧
/// 静态截图（Windows.Graphics.Capture 单帧），经 MethodChannel 返回给 Dart。
///
/// native 侧（`fushi/windows/runner/window_capture.cpp`）注册 `window_capture`
/// channel，暴露两个方法：
///   - `listWindows` -> `List<Map>`：每项 `{hwnd:int, title:String}`。
///   - `captureWindow` -> `Map`：`{pngBytes:Uint8List}` 或 `{error:String}`。
///   - 滚动录制（galgame 视频卡片，`window_recorder.cpp` 的 `WindowRecorder`）：
///     `startWindowRecording` -> bool、`stopWindowRecording` -> null、
///     `isWindowRecording` -> bool、
///     `exportWindowRecording` -> `{frames:[{path,tickMs}...], nowTickMs, error?}`。
///
/// native 缺失（未构建 / 非 Windows / 旧 Windows 无 WGC）时，两个方法都以
/// [MissingPluginException] / [PlatformException] 收敛为空列表 / error 结果——
/// 调用方据此降级（不崩、不静默假成功）。
abstract final class WindowCaptureChannel {
  static const MethodChannel _channel = MethodChannel(
    'app.fushi.reader/window_capture',
  );

  /// 枚举当前可捕获的顶层窗口（有标题、可见、非本 app 自身）。native 不可用或无窗口
  /// 时返回空列表（调用方按空列表提示「未找到窗口」，不崩）。
  static Future<List<ExternalWindowInfo>> listWindows() async {
    try {
      final List<Object?>? raw = await _channel.invokeListMethod<Object?>(
        'listWindows',
      );
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

  /// 测试钩子：覆盖「当前平台是否支持滚动录制」判定（null = 按 [Platform.isWindows]）。
  /// 契约测试在非 Windows CI 上也要能驱动 mock channel，真机代码永远不设它。
  @visibleForTesting
  static bool? debugPlatformSupportedOverride;

  static bool get _recordingSupported =>
      debugPlatformSupportedOverride ?? Platform.isWindows;

  /// galgame 视频卡片：对 [hwnd] 开始持续滚动录制（native `WindowRecorder`，WGC 持久
  /// 会话，按 [fps] 抽帧、裁客户区、等比缩到 [maxWidth] 宽、JPEG 入环形队列，只留最近
  /// [maxSeconds] 秒）。已在录同一窗口时幂等返回 true。非 Windows / native 缺失 /
  /// WGC 不支持 / 窗口不可捕获一律返回 false，绝不抛。
  static Future<bool> startWindowRecording({
    required int hwnd,
    int fps = 5,
    int maxSeconds = 20,
    int maxWidth = 640,
  }) async {
    if (!_recordingSupported) {
      return false;
    }
    try {
      final bool? started = await _channel.invokeMethod<bool>(
        'startWindowRecording',
        <String, Object?>{
          'hwnd': hwnd,
          'fps': fps,
          'maxSeconds': maxSeconds,
          'maxWidth': maxWidth,
        },
      );
      return started ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停止滚动录制并释放环形队列。幂等；非 Windows / native 缺失时静默返回。
  static Future<void> stopWindowRecording() async {
    if (!_recordingSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopWindowRecording');
    } on PlatformException {
      // 停止失败没有可恢复的动作；下一次 start 会先 stop 再起。
    } on MissingPluginException {
      // native 缺失 = 本来就没在录。
    }
  }

  /// 是否仍在录制（Start 成功且目标窗口尚未销毁）。非 Windows / native 缺失为 false。
  static Future<bool> get isWindowRecording async {
    if (!_recordingSupported) {
      return false;
    }
    try {
      final bool? recording = await _channel.invokeMethod<bool>(
        'isWindowRecording',
      );
      return recording ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 把 tick 落在 `[fromTickMs, toTickMs]` 内的帧以 `frame_%05d.jpg` 写进已建好的
  /// [directory]，按 tick 升序返回。[toTickMs] <= 0 表示「到现在」。tick 与 hook 台词
  /// 事件同为 runner 的 `GetTickCount64()` 时钟。失败 / 未在录制 / 区间无帧时
  /// [WindowRecordingExport.error] 非 null（`not_recording` / `no_frames` /
  /// `bad_directory` / `write_failed` / `unsupported`），绝不抛。
  static Future<WindowRecordingExport> exportWindowRecording({
    required int fromTickMs,
    required int toTickMs,
    required String directory,
  }) async {
    if (!_recordingSupported) {
      return const WindowRecordingExport(
        frames: <WindowRecordingFrame>[],
        nowTickMs: 0,
        error: 'unsupported',
      );
    }
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'exportWindowRecording',
        <String, Object?>{
          'fromTickMs': fromTickMs,
          'toTickMs': toTickMs,
          'directory': directory,
        },
      );
      return WindowRecordingExport.fromMap(r ?? const <Object?, Object?>{});
    } on PlatformException catch (e) {
      return WindowRecordingExport(
        frames: const <WindowRecordingFrame>[],
        nowTickMs: 0,
        error: e.message ?? 'export failed',
      );
    } on MissingPluginException {
      return const WindowRecordingExport(
        frames: <WindowRecordingFrame>[],
        nowTickMs: 0,
        error: 'window_capture unavailable',
      );
    }
  }
}

/// 滚动录制导出的一帧：磁盘 JPEG 路径 + 到达 tick（runner `GetTickCount64()`）。
class WindowRecordingFrame {
  const WindowRecordingFrame({required this.path, required this.tickMs});

  final String path;
  final int tickMs;

  /// 从 native map 解析；缺 `path` / `tickMs` 返回 null（跳过该项）。
  static WindowRecordingFrame? fromMap(Map<Object?, Object?> m) {
    final Object? path = m['path'];
    final Object? tick = m['tickMs'];
    if (path is! String || path.isEmpty || tick is! int) {
      return null;
    }
    return WindowRecordingFrame(path: path, tickMs: tick);
  }

  @override
  bool operator ==(Object other) =>
      other is WindowRecordingFrame &&
      other.path == path &&
      other.tickMs == tickMs;

  @override
  int get hashCode => Object.hash(path, tickMs);
}

/// [WindowCaptureChannel.exportWindowRecording] 的结果。
class WindowRecordingExport {
  const WindowRecordingExport({
    required this.frames,
    required this.nowTickMs,
    this.error,
  });

  /// 按 [WindowRecordingFrame.tickMs] 升序，文件为 JPEG。
  final List<WindowRecordingFrame> frames;

  /// runner 的 `GetTickCount64()` 当前值（与 hook 台词时间戳同一时钟）。
  final int nowTickMs;

  /// 非 null 表示失败 / 未在录制（如 `not_recording`、`no_frames`、`unsupported`）。
  final String? error;

  bool get ok => error == null;

  static WindowRecordingExport fromMap(Map<Object?, Object?> m) {
    final List<WindowRecordingFrame> frames = <WindowRecordingFrame>[];
    final Object? raw = m['frames'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map) {
          final WindowRecordingFrame? f = WindowRecordingFrame.fromMap(
            item.cast<Object?, Object?>(),
          );
          if (f != null) {
            frames.add(f);
          }
        }
      }
    }
    frames.sort((a, b) => a.tickMs.compareTo(b.tickMs));
    final Object? now = m['nowTickMs'];
    return WindowRecordingExport(
      frames: frames,
      nowTickMs: now is int ? now : 0,
      error: m['error'] as String?,
    );
  }
}

/// 一个可捕获的外部顶层窗口：native HWND（作为 [int] 传回）+ 窗口标题 + 所属进程 PID。
class ExternalWindowInfo {
  const ExternalWindowInfo({
    required this.hwnd,
    required this.title,
    this.pid = 0,
  });

  /// native 窗口句柄 HWND，作为整数在 MethodChannel 上传输（回传 native 时原样带回）。
  final int hwnd;

  /// 窗口标题（GetWindowText），供 UI 展示与选择。
  final String title;

  /// 窗口所属进程 PID（galgame 引擎级 voice hook 的注入目标）；native 未提供时为 0。
  final int pid;

  /// 从 native map 解析；缺 `hwnd`（无有效句柄）返回 null（跳过该项）。
  static ExternalWindowInfo? fromMap(Map<Object?, Object?> m) {
    final Object? h = m['hwnd'];
    if (h is! int) {
      return null;
    }
    final Object? p = m['pid'];
    return ExternalWindowInfo(
      hwnd: h,
      title: (m['title'] as String?) ?? '',
      pid: p is int ? p : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExternalWindowInfo &&
      other.hwnd == hwnd &&
      other.title == title &&
      other.pid == pid;

  @override
  int get hashCode => Object.hash(hwnd, title, pid);
}

/// [WindowCaptureChannel.captureWindow] 的结果：成功带 PNG 字节，失败带人类可读原因。
class WindowCaptureResult {
  const WindowCaptureResult({this.pngBytes, this.error, this.diagnostics});

  /// 捕获到的 PNG 图像字节（成功时非空）。
  final Uint8List? pngBytes;

  /// 失败原因（成功时为 null）。
  final String? error;

  /// BUG-1096：**成功路径**上值得记录的 native 事实，与 [error] 正交（有它不代表失败）。
  /// 目前两类：① WGC 光标合成抑制没能生效（`IGraphicsCaptureSession2` 缺失或
  /// `put_IsCursorCaptureEnabled` 失败——以前这两处 HRESULT 都被 native 静默吞掉）；
  /// ② 捕获目标被从 Magpie 缩放窗重定向到了真实源窗口。native 无话可说时为 null。
  final String? diagnostics;

  /// true = 成功拿到非空图像字节。
  bool get ok => error == null && pngBytes != null && pngBytes!.isNotEmpty;

  static WindowCaptureResult fromMap(Map<Object?, Object?> m) =>
      WindowCaptureResult(
        pngBytes: m['pngBytes'] as Uint8List?,
        error: m['error'] as String?,
        diagnostics: m['diagnostics'] as String?,
      );
}
