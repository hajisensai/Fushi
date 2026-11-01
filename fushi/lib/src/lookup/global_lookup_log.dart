// TODO-617 global lookup — best-effort file logger for desktop diagnostics.
//
// The runner is a WIN32 GUI exe with no console, so debugPrint goes nowhere
// when launched standalone. This appends timestamped lines to a fixed file
// (<systemTemp>/hibiki_glookup.log) so the overlay trigger can be diagnosed
// without attaching a debugger. Temporary diagnostic aid for the M0/M1 bring-up.
//
// 写法约束（游戏内嵌查词耗时优化，2026-11）：
//   * glog 跑在 UI isolate 上，且就在查词关键路径里——一次查词十几行。逐行
//     `flush: true`（FlushFileBuffers 落盘）实测一行约 2.5 ms，不 flush 约 0.14 ms；
//     日志只为诊断，进程崩溃时已写入的内容仍在系统缓存里，只有整机掉电才会丢，
//     所以不再逐行落盘。
//   * 仍然**每行打开、追加、关闭**，不长期持有句柄：runner 的 NativeGlog 也在往同一个
//     文件追加，Dart 的 append 句柄只在打开那一刻定位到文件尾，常开会把原生写入的行
//     覆盖掉。
//   * 文件从前从不轮转，用户机器上长到 1 GB 以上。超过 [kGlookupLogMaxBytes] 就整体
//     换名为 `.1`（只留一份旧档）。
//   * 单行超过 [kGlookupLogMaxLineChars] 截断：制卡时整张卡的词典内容会被原样带进
//     日志，一行几十 KB 既拖慢写入又淹没诊断信息。

import 'dart:io';

/// 日志文件超过这个字节数就换名为 `.1` 重新开始。
const int kGlookupLogMaxBytes = 16 * 1024 * 1024;

/// 单行日志的字符上限（超出部分截断并注明截掉了多少）。
const int kGlookupLogMaxLineChars = 2000;

/// 每写这么多行检查一次文件大小（stat 一次约几十微秒，不必每行都做）。
const int _kRotateCheckEvery = 256;

File? _logFile;
int _linesSinceRotateCheck = _kRotateCheckEvery;

String _logPath() =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}hibiki_glookup.log';

File _resolveLogFile() => _logFile ??= File(_logPath());

/// 测试用：把日志指到别的文件，并让下一次写入立即检查大小。
void debugSetGlookupLogFile(File? file) {
  _logFile = file;
  _linesSinceRotateCheck = _kRotateCheckEvery;
}

/// 超长消息截断成 [kGlookupLogMaxLineChars] 个字符并注明原长。
String clampGlookupLogLine(String message) {
  if (message.length <= kGlookupLogMaxLineChars) return message;
  final int dropped = message.length - kGlookupLogMaxLineChars;
  return '${message.substring(0, kGlookupLogMaxLineChars)}…(+$dropped chars)';
}

void _rotateIfNeeded(File file) {
  if (++_linesSinceRotateCheck < _kRotateCheckEvery) return;
  _linesSinceRotateCheck = 0;
  try {
    if (!file.existsSync() || file.lengthSync() <= kGlookupLogMaxBytes) {
      return;
    }
    final File previous = File('${file.path}.1');
    if (previous.existsSync()) previous.deleteSync();
    file.renameSync(previous.path);
  } catch (_) {
    // 原生侧恰好开着文件时换名会失败：保持原文件，下一轮再试。
  }
}

void glog(String message) {
  try {
    final File file = _resolveLogFile();
    _rotateIfNeeded(file);
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()}  ${clampGlookupLogLine(message)}\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // Never let logging break the trigger.
  }
}
