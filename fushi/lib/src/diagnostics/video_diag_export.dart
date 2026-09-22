import 'dart:io';

import 'package:fushi/src/diagnostics/video_diag_log.dart';

/// 视频 / 查词诊断日志的导出正文（设置 › 诊断 › 导出视频诊断日志）。
///
/// 正文三段，顺序固定：
///
/// 1. **头信息**：版本、平台、当前过滤串，以及排查时第一个要确认的两件事——小内存
///    模式开没开、热槽在不在。没有这段，拿到一份流水还得先反问用户一轮。
/// 2. **统一时间轴**（`video_diag_log.txt`）：Flutter 帧耗时、libmpv 属性采样、查词
///    各阶段、热槽生命周期，全部按同一把 uptime 尺排列。
/// 3. **libmpv 原始日志尾部**（`video_mpv_log.txt`）：mpv 自己写的那一份 verbose
///    日志，解码器/hwdec 协商/VO 交换链/demuxer 都在里面。放在最后是因为它最长，
///    前两段才是先要看的。
///
/// 分段用醒目的分隔行，便于用户只截其中一段贴出来。
String buildVideoDiagExport({
  required String appVersion,
  required String timeline,
  required String mpvLog,
  required bool lowMemoryMode,
  required bool diagnosticsEnabled,
  required String msgLevel,
  String? platformDescription,
  DateTime? now,
}) {
  final StringBuffer sb = StringBuffer();
  sb.writeln('=== Fushi video diagnostics ===');
  sb.writeln('generated: ${(now ?? DateTime.now()).toIso8601String()}');
  sb.writeln('app: $appVersion');
  sb.writeln('platform: ${platformDescription ?? _describePlatform()}');
  sb.writeln('diagnostics-enabled: $diagnosticsEnabled');
  sb.writeln('msg-level: $msgLevel');
  // 这一行是整份导出里最该先看的：用户报「视频卡顿」时它是否为 true，直接决定
  // 后面该往哪个方向读——开着就该看查词慢/闪，关着就该看丢帧。
  sb.writeln('low-memory-mode: $lowMemoryMode');
  sb.writeln(
    'warm-popup-slot: ${lowMemoryMode ? "disabled (cold WebView per lookup)" : "enabled"}',
  );
  if (!diagnosticsEnabled) {
    sb.writeln(
      'NOTE: diagnostics were OFF — the timeline below only holds whatever was '
      'recorded while it was on. Turn it on, reproduce, then export again.',
    );
  }
  sb.writeln();
  sb.writeln('=== timeline (${VideoDiagLog.fileName}) ===');
  sb.writeln(timeline.trim().isEmpty ? '(empty)' : timeline.trimRight());
  sb.writeln();
  sb.writeln('=== libmpv log tail (${VideoDiagLog.mpvLogFileName}) ===');
  sb.writeln(
    mpvLog.trim().isEmpty
        ? '(empty — libmpv verbose logging only runs while diagnostics are on)'
        : mpvLog.trimRight(),
  );
  return sb.toString();
}

/// 读齐两份日志并拼出导出正文。IO 失败按空串处理——导出永远要给得出东西，
/// 哪怕只剩头信息。
Future<String> buildVideoDiagExportFromDisk({
  required String appVersion,
  required bool lowMemoryMode,
  DateTime? now,
}) async {
  final VideoDiagLog log = VideoDiagLog.instance;
  final String timeline = await log.readPersisted();
  final String mpvLog = await log.readMpvLogTail();
  return buildVideoDiagExport(
    appVersion: appVersion,
    timeline: timeline,
    mpvLog: mpvLog,
    lowMemoryMode: lowMemoryMode,
    diagnosticsEnabled: log.enabled,
    msgLevel: log.msgLevel,
    now: now,
  );
}

String _describePlatform() =>
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
