import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// BUG-209 / TODO-398：把 native 端 WGC（Windows.Graphics.Capture）帧捕获生命周期
/// 日志折进 [ErrorLogService] 的上传链路。
///
/// native 侧（`packages/flutter_inappwebview_windows/windows/utils/wgc_log.cpp`）在
/// 帧池 create / retire / stop / recreate / createSession-fail / startCapture-fail 等
/// 生命周期点，把带时间戳 + 线程 id + 帧池指针的结构化行写进固定文件
/// `%LOCALAPPDATA%\Hibiki\wgc_capture.log`（始终编译，Release 也写，不依赖 Dart 下发
/// 路径——避免「下发前 capture 已发生」的时机赌注）。
///
/// 启动时（[ErrorLogService.init] 之后）调用本函数：把上次运行残留的 WGC 日志读出
/// 折进错误日志的**诊断/取证段**（TODO-1083：不再计入用户可见错误，但仍经现有
/// [uploadLogToServer] 上传随日志带走），
/// 读后清空文件准备本次运行写入（滚动语义，避免无界累积，与导入面包屑「读后清」一致）。
/// 这样 BUG-209 延迟 UAF 在下次启动就有可上传的可读崩前生命周期证据，不必再赌系统
/// WER 偶然留 minidump。
class WgcCaptureLog {
  WgcCaptureLog._();

  /// 日志文件相对 `%LOCALAPPDATA%` 的子路径（native 端 wgc_log.cpp 用同一常量
  /// `%LOCALAPPDATA%\Hibiki\wgc_capture.log`——两边硬钉同一确定路径，无 bundle id 推测）。
  static const String _relativePath = r'Hibiki\wgc_capture.log';

  /// 解析日志文件（仅 Windows）。环境变量 `LOCALAPPDATA` 缺失或非 Windows 返回 null。
  @visibleForTesting
  static File? resolveLogFile({
    bool isWindows = false,
    String? localAppData,
  }) {
    if (!isWindows) return null;
    final String? base = localAppData;
    if (base == null || base.isEmpty) return null;
    return File('$base\\$_relativePath');
  }

  /// 纯逻辑：读 [file] 内容，非空则返回内容并清空文件（读后清的滚动语义）；
  /// 不存在 / 空 / 读失败返回 null。便于单测注入临时文件。
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
      // 清不掉就留着，下次启动再折入（会重复一次，可接受，不影响取证）。
    }
    return content;
  }

  /// 启动时把上次运行的 WGC 捕获日志折进 [ErrorLogService]（仅 Windows）。
  /// 在 [ErrorLogService.init] 之后调用。任何异常静默吞掉（不阻塞启动）。
  static Future<void> foldIntoErrorLog() async {
    try {
      final File? file = resolveLogFile(
        isWindows: Platform.isWindows,
        localAppData: Platform.environment['LOCALAPPDATA'],
      );
      if (file == null) return;
      final String? content = readAndClear(file);
      if (content == null) return;
      // TODO-1083：WGC 帧捕获生命周期日志是**取证/诊断**（崩前生命周期证据），不是用户
      // 可见的应用「报错」。走 logDiagnostic 归入诊断段——不刷进错误日志页的错误计数/
      // 正文，但仍随复制/分享/上传带走（保住 BUG-209 崩前证据可上传，非删除式绕过）。
      ErrorLogService.instance.logDiagnostic(
        'WGC.captureLog',
        '上次运行的 Windows WGC 帧捕获生命周期日志（BUG-209 取证）：\n$content',
      );
    } catch (e) {
      debugPrint('[WgcCaptureLog] foldIntoErrorLog failed: $e');
    }
  }
}
