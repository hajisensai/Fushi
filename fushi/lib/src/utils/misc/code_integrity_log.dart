import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// BUG-5484：把 native runner 读到的 Windows 代码完整性（智能应用控制 / WDAC）拦截记录
/// 折进 [ErrorLogService]。
///
/// 开着智能应用控制的机器上，被拦的 DLL / exe 只记在「事件查看器 › Microsoft › Windows ›
/// CodeIntegrity › Operational」里，普通用户不知道去翻。`fushi/windows/runner/
/// code_integrity_probe.cpp` 每次启动 60 s 后（以及启动卡死、强制显窗那一刻）自己查
/// 这个事件日志，把指向 Fushi 文件的新拦截记录和智能应用控制的状态写进
/// `crashdumps\code_integrity.log`；本类在下次启动时读出折成 `CodeIntegrity.blocked`，
/// 读后清空（滚动语义，与 [HangWatchdogLog] 一致），随反馈日志上传。
class CodeIntegrityLog {
  CodeIntegrityLog._();

  /// 日志文件相对 `%LOCALAPPDATA%` 的子路径（native 端写进 crash dump 同一目录，
  /// 文件名 `code_integrity.log`——两边硬钉同一确定路径）。
  static const String _relativePath = r'Fushi\crashdumps\code_integrity.log';

  /// 解析日志文件（仅 Windows）。`LOCALAPPDATA` 缺失或非 Windows 返回 null。
  @visibleForTesting
  static File? resolveLogFile({
    required bool isWindows,
    required String? localAppData,
  }) {
    if (!isWindows) return null;
    if (localAppData == null || localAppData.isEmpty) return null;
    return File('$localAppData\\$_relativePath');
  }

  /// 纯逻辑：读 [file] 内容，非空则返回内容并清空文件；不存在 / 空 / 读失败返回 null。
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
      // 清不掉就留着，下次启动再折入（重复一次可接受）。
    }
    return content;
  }

  /// 把上次运行查到的拦截记录折进 [ErrorLogService]（仅 Windows）。在
  /// [ErrorLogService.init] 之后调用；任何异常静默吞掉（不阻塞启动）。
  static Future<void> foldIntoErrorLog() async {
    try {
      final File? file = resolveLogFile(
        isWindows: Platform.isWindows,
        localAppData: Platform.environment['LOCALAPPDATA'],
      );
      if (file == null) return;
      final String? content = readAndClear(file);
      if (content == null) return;
      ErrorLogService.instance.log(
        'CodeIntegrity.blocked',
        'Windows 代码完整性 / 智能应用控制的状态与拦截记录（`blocked` 行点名被拦的 Fushi 文件；'
            '为 0 条时说明卡住与系统拦截无关）：\n$content',
      );
    } catch (e) {
      debugPrint('[CodeIntegrityLog] foldIntoErrorLog failed: $e');
    }
  }
}
