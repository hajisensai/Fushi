import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// BUG-766：启动 present-watchdog。
///
/// 现有裸加载看门狗（TODO-1260，`main.dart` `_startLoadingWatchdogIfNeeded`）的 Timer
/// 与逃生 UI 都在 UI isolate —— 当故障是 **Flutter 引擎 raster / GPU present 管线楔死**
/// （快速进出视频 → libmpv/ANGLE/WGC churn 污染进程共享 D3D device/swapchain）时，
/// Timer 会照常 fire、逃生 UI 会照常 build，但和 loading 转圈一样**送不上屏**，用户只
/// 看见一片纯背景色、只能手动 kill。那层看门狗够不着「present 层」死锁。
///
/// 本类用**不依赖 present 的判据**兜底：`runApp` 后超过 [timeout] 仍未 rasterize 过任何
/// 一帧（`WidgetsBinding.instance.firstFrameRasterized == false`）⟹ present 楔死（正常启动
/// 首帧——含 loading 转圈——早已 rasterize，该 bool 早为 true，故不会误触发）。命中即
/// [onStall]：落盘取证（下次启动折进错误日志随上传带走）+ 一次性自动重启（marker 防循环）。
///
/// 纯逻辑（注入 [scheduleTimer] / [isFirstFrameRasterized] / [onStall]），便于离屏单测。
class PresentWatchdog {
  PresentWatchdog({
    required this.timeout,
    required this.isFirstFrameRasterized,
    required this.onStall,
    void Function() Function(Duration, void Function())? scheduleTimer,
  }) : _schedule = scheduleTimer ?? _defaultSchedule;

  final Duration timeout;
  final bool Function() isFirstFrameRasterized;
  final void Function() onStall;

  /// 注入的定时调度：给定时长与回调，返回一个 cancel 函数（生产走真实 [Timer]）。
  final void Function() Function(Duration, void Function()) _schedule;

  void Function()? _cancel;
  bool _stallReported = false;
  bool _disarmed = false;

  static void Function() _defaultSchedule(Duration d, void Function() cb) {
    final Timer t = Timer(d, cb);
    return t.cancel;
  }

  /// 进入裸加载态时 arm（幂等：已挂 / 已 stall / 已 disarm 都不重复挂）。
  void arm() {
    if (_cancel != null || _stallReported || _disarmed) return;
    _cancel = _schedule(timeout, _check);
  }

  void _check() {
    _cancel = null;
    if (_disarmed || _stallReported) return;
    // 首帧已 present = 引擎渲染正常，绝不误触发自动重启。
    if (isFirstFrameRasterized()) return;
    _stallReported = true;
    onStall();
  }

  /// 首帧出画 / 初始化完成时撤销（之后不再触发）。
  void disarm() {
    _disarmed = true;
    _cancel?.call();
    _cancel = null;
  }
}

/// present 楔死取证落盘 + 自动重启 marker（仿 `WgcCaptureLog`，路径固定在
/// `%LOCALAPPDATA%\Hibiki\`，不依赖 `AppModel.initialise()` —— 楔死可能发生在初始化完成
/// 之前，此刻数据根尚未解析）。全部纯逻辑（注入 file/now），便于单测。
class PresentStallLog {
  PresentStallLog._();

  static const String logRelative = r'Hibiki\present_stall.log';
  static const String markerRelative = r'Hibiki\present_stall.marker';

  /// 解析 `%LOCALAPPDATA%\Hibiki\<relative>`（仅 Windows；非 Windows / 无 LOCALAPPDATA
  /// 返回 null）。
  @visibleForTesting
  static File? resolveFile(
    String relative, {
    bool isWindows = false,
    String? localAppData,
  }) {
    if (!isWindows) return null;
    if (localAppData == null || localAppData.isEmpty) return null;
    return File('$localAppData\\$relative');
  }

  /// append 一行取证（best-effort，失败不致命）。生产由 present-watchdog onStall 调用。
  static void appendStall(
    File file,
    DateTime now, {
    required Duration afterTimeout,
  }) {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${now.toUtc().toIso8601String()} present-stall: first frame not '
        'rasterized after ${afterTimeout.inSeconds}s '
        '(raster/present 楔死疑似, BUG-766)\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 取证 best-effort：写不进不影响自愈重启。
    }
  }

  /// 读后清（滚动语义，仿 `WgcCaptureLog.readAndClear`），供启动折进诊断段。
  @visibleForTesting
  static String? readAndClear(File file) {
    if (!file.existsSync()) return null;
    String content;
    try {
      content = file.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
    if (content.isEmpty) return null;
    try {
      file.writeAsStringSync('', flush: true);
    } catch (_) {
      // 清不掉留着，下次重复折入一次可接受。
    }
    return content;
  }

  /// 认领一次自动重启：marker 不存在 → 写 marker 返回 true（可重启）；已存在 → 返回
  /// false（上次已因楔死重启过、这次仍卡，别再重启，避免驱动级 device-lost 跨进程时
  /// 无限重启循环）。生产由 present-watchdog onStall 调用。
  static bool claimRestart(File markerFile) {
    try {
      if (markerFile.existsSync()) return false;
      markerFile.parent.createSync(recursive: true);
      markerFile.writeAsStringSync('1', flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 成功启动后清除 marker（让下次再遇楔死还能自动重启一次）。生产由 build 启动推进后调用。
  static void clearRestartMarker(File markerFile) {
    try {
      if (markerFile.existsSync()) markerFile.deleteSync();
    } catch (_) {}
  }

  /// 启动时把上次运行的 present 楔死取证折进 [ErrorLogService] 诊断段（仅 Windows，
  /// 与 `WgcCaptureLog.foldIntoErrorLog` 对称，随日志上传带走）。任何异常静默吞掉。
  static Future<void> foldIntoErrorLog() async {
    try {
      final File? file = resolveFile(
        logRelative,
        isWindows: Platform.isWindows,
        localAppData: Platform.environment['LOCALAPPDATA'],
      );
      if (file == null) return;
      final String? content = readAndClear(file);
      if (content == null) return;
      ErrorLogService.instance.logDiagnostic(
        'PresentWatchdog.stall',
        '上次运行 present 楔死取证（BUG-766，raster/present 管线未出首帧）：\n$content',
      );
    } catch (e) {
      debugPrint('[PresentStallLog] foldIntoErrorLog failed: $e');
    }
  }

  /// 生产用 marker 文件（Windows），非 Windows / 无 LOCALAPPDATA 返回 null。
  static File? resolveMarkerFile() => resolveFile(
        markerRelative,
        isWindows: Platform.isWindows,
        localAppData: Platform.environment['LOCALAPPDATA'],
      );

  /// 生产用取证日志文件（Windows），非 Windows / 无 LOCALAPPDATA 返回 null。
  static File? resolveStallLogFile() => resolveFile(
        logRelative,
        isWindows: Platform.isWindows,
        localAppData: Platform.environment['LOCALAPPDATA'],
      );
}
