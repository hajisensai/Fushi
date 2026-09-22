import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/video_diag_export.dart';
import 'package:fushi/src/diagnostics/video_diag_log.dart';

/// 导出正文的契约：头信息必须自带「读这份日志需要先知道的事」，否则拿到流水还得
/// 再问用户一轮（开没开小内存模式、诊断是不是全程开着）。
void main() {
  String build({
    String timeline = 'line-1\nline-2',
    String mpvLog = 'mpv-line',
    bool lowMemoryMode = false,
    bool diagnosticsEnabled = true,
  }) {
    return buildVideoDiagExport(
      appVersion: '1.2.3+456',
      timeline: timeline,
      mpvLog: mpvLog,
      lowMemoryMode: lowMemoryMode,
      diagnosticsEnabled: diagnosticsEnabled,
      msgLevel: VideoDiagLog.defaultMsgLevel,
      platformDescription: 'windows 11',
      now: DateTime.utc(2026, 9, 22, 12),
    );
  }

  test('头信息带版本、平台、过滤串与小内存状态', () {
    final String out = build();
    expect(out, contains('app: 1.2.3+456'));
    expect(out, contains('platform: windows 11'));
    expect(out, contains('msg-level: ${VideoDiagLog.defaultMsgLevel}'));
    expect(out, contains('low-memory-mode: false'));
    expect(out, contains('generated: 2026-09-22T12:00:00.000Z'));
  });

  test('小内存模式时明写热槽被关（查词冷建的直接后果）', () {
    expect(
      build(lowMemoryMode: true),
      contains('warm-popup-slot: disabled (cold WebView per lookup)'),
    );
    expect(build(lowMemoryMode: false), contains('warm-popup-slot: enabled'));
  });

  test('三段齐全且按「先看的在前」排序', () {
    final String out = build();
    final int header = out.indexOf('=== Fushi video diagnostics ===');
    final int timeline = out.indexOf('=== timeline (');
    final int mpv = out.indexOf('=== libmpv log tail (');
    expect(header, 0);
    expect(timeline, greaterThan(header));
    expect(mpv, greaterThan(timeline), reason: 'libmpv 原始日志最长，放最后，前两段才是先读的');
    expect(out, contains('line-1'));
    expect(out, contains('mpv-line'));
  });

  test('诊断没开时给出明确提示，而不是让人对着空流水发呆', () {
    final String out = build(timeline: '', diagnosticsEnabled: false);
    expect(out, contains('diagnostics-enabled: false'));
    expect(out, contains('Turn it on, reproduce, then export again.'));
    expect(out, contains('(empty)'));
  });

  test('mpv 段为空时说明原因（只在诊断开着时才写）', () {
    final String out = build(mpvLog: '   ');
    expect(
      out,
      contains('libmpv verbose logging only runs while diagnostics are on'),
    );
  });
}
