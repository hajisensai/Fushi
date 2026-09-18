import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// BUG-2588：把 native runner 主线程停泵看门狗（`fushi/windows/runner/hang_watchdog.cpp`）
/// 上次运行留下的记录折进 [ErrorLogService]。
///
/// 卡死（主线程不再泵消息）不是崩溃：没有异常、`SetUnhandledExceptionFilter` 不会触发、
/// WER 不留 dump，Dart 侧的查词面包屑下次启动只能报一条 `Lookup.crashRecovered`——分不清
/// 「崩了」还是「卡死后被强杀」，更看不到主线程当时卡在哪。看门狗在主线程连续停泵超过
/// 阈值时从旁路线程抓一份全线程栈 minidump（`crashdumps\hang-<pid>-<tick>.dmp`，诊断区
/// 「崩溃转储」页自动列出），并往同目录 `hang_watchdog.log` 追加一行「什么时候、卡了多久、
/// dump 在哪」。本类在启动时（[ErrorLogService.init] 之后）把这一行读出折成
/// `MainThread.hangRecovered`，与 `Lookup.crashRecovered` 并排出现在错误日志里；读后清空
/// （滚动语义，与 WGC 日志 / 面包屑一致）。
class HangWatchdogLog {
  HangWatchdogLog._();

  /// 日志文件相对 `%LOCALAPPDATA%` 的子路径（native 端 `hang_watchdog.cpp` 写进与
  /// crash dump 同一目录，文件名 `hang_watchdog.log`——两边硬钉同一确定路径）。
  static const String _relativePath = r'Fushi\crashdumps\hang_watchdog.log';

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
      // 清不掉就留着，下次启动再折入（会重复一次，可接受，不影响取证）。
    }
    return content;
  }

  /// 把上次运行的看门狗记录折进 [ErrorLogService]（仅 Windows）。在
  /// [ErrorLogService.init] 之后调用。任何异常静默吞掉（不阻塞启动）。
  static Future<void> foldIntoErrorLog() async {
    try {
      final File? file = resolveLogFile(
        isWindows: Platform.isWindows,
        localAppData: Platform.environment['LOCALAPPDATA'],
      );
      if (file == null) return;
      final String? content = readAndClear(file);
      if (content == null) return;
      // 走用户可见的 log（不是 logDiagnostic）：这条正是用户报「卡死」时最该复制给
      // 开发者的一行——它指向诊断区里那份可分享的 hang dump。
      ErrorLogService.instance.log(
        'MainThread.hangRecovered',
        '上次运行主线程停泵（app 卡死、键鼠无响应），看门狗已抓取全线程栈 dump——'
            '请在「诊断 → 崩溃转储」分享 hang-*.dmp：\n$content',
      );
    } catch (e) {
      debugPrint('[HangWatchdogLog] foldIntoErrorLog failed: $e');
    }
  }
}
