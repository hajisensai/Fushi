import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/study_diag_export.dart';
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 用户 2026-09-12：「要有个导出日志的方式用于排查阅读速度异常」。
///  * [StudyDiagLog]：一行一事件、追加落盘、跨运行保留、超限保尾对齐行首；
///  * 会话快照行：字/时与统计页同口径（最小样本 1 分钟，不足写 `-`）；
///  * 源码守卫：main 装 `StudyClock.trace` → 日志；设置 › 诊断有导出动作走
///    `saveLogToFile`；时钟 / 账本 arrive / 恢复决策 / 跳句 / 导航埋点都在。
void main() {
  test('formatLine：时间 [来源] 消息，多行压成一行', () {
    final String line = StudyDiagLog.formatLine(
      DateTime(2026, 9, 12, 14, 3, 22, 123),
      'clock',
      'a\nb\r\nc',
    );
    expect(line, '2026-09-12 14:03:22.123 [clock] a⏎b⏎c');
  });

  test('trimTail：保尾到上限并丢掉第一段残行', () {
    final String s = List<String>.generate(50, (int i) => 'line-$i').join('\n');
    final List<int> bytes = utf8.encode('$s\n');
    final String out = StudyDiagLog.trimTail(bytes, maxBytes: 60);
    expect(utf8.encode(out).length, lessThanOrEqualTo(60));
    expect(out, startsWith('line-'), reason: '第一行必须是完整行');
    expect(out, endsWith('line-49\n'));
    expect(StudyDiagLog.trimTail(bytes, maxBytes: 1 << 20), '$s\n');
  });

  test('add 落盘追加、readPersisted 跨实例可读、clear 清空', () async {
    final Directory dir = await Directory.systemTemp.createTemp('study-diag');
    addTearDown(() => dir.delete(recursive: true));
    final StudyDiagLog log = StudyDiagLog.instance;
    await log.init(directoryOverride: dir);
    log.add('ledger', 'credit 120c');
    log.add('reader', 'resume from audio cue');
    await log.flush();
    final String text = await File(
      '${dir.path}/${StudyDiagLog.fileName}',
    ).readAsString();
    expect(text, contains('[log] session start'));
    expect(text, contains('[ledger] credit 120c\n'));
    expect(text, contains('[reader] resume from audio cue\n'));
    expect(log.lines.last, endsWith('[reader] resume from audio cue'));
    expect(await log.readPersisted(), text);
    await log.clear();
    expect(await log.readPersisted(), isEmpty);
    expect(log.lines, isEmpty);
  });

  test('会话快照行：字/时与统计页同口径，样本不足写 -', () {
    StudySession session({required int ms, required int chars}) => StudySession(
          mediaKind: kActivityMediaBook,
          mediaKey: 'k',
          title: '小説',
          format: 'epub',
          deviceId: 'dev',
          startAt: 0,
          endAt: ms,
          durationMs: ms,
          chars: chars,
          pages: 0,
          segmentUids: const <String>['a', 'b'],
        );
    final String ok = formatStudySessionDiagRow(
      session(ms: 30 * 60000, chars: 6000),
    );
    expect(ok, contains('| book | 1800000 | 6000 | 0 | 12000 | dev | 2 | 小説'));
    final String thin = formatStudySessionDiagRow(
      session(ms: 20000, chars: 50),
    );
    expect(thin, contains('| 20000 | 50 | 0 | - | dev'));
  });

  group('源码守卫', () {
    test('main 装 StudyDiagLog + StudyClock.trace；时钟有静态 sink', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('await StudyDiagLog.instance.init();'));
      expect(
        main,
        contains(
          "StudyClock.trace = (String line) => StudyDiagLog.instance.add('clock', line);",
        ),
      );
      final String clock = File(
        '../packages/fushi_audio/lib/src/audiobook/study_clock.dart',
      ).readAsStringSync();
      expect(clock, contains('static void Function(String line)? trace;'));
      for (final String event in <String>[
        "'start ",
        "'stop session=",
        "'detach session=",
        "'+\${chars}c → ",
        "'drop +\${chars}c (not running)'",
        "'-\${chars}c taken=",
        "'reject window ",
        "'open ",
        "'seal ",
        "'write error ",
      ]) {
        expect(
          RegExp('_trace\\(\\s*${RegExp.escape(event)}').hasMatch(clock),
          isTrue,
          reason: '时钟事件 $event 必须进流水',
        );
      }
    });

    test('设置 › 诊断：导出动作走 saveLogToFile + buildStudyDiagExport', () {
      final String settings = File(
        'lib/src/settings/settings_schema_system.dart',
      ).readAsStringSync();
      expect(settings, contains("id: 'diagnostics.study_diag_export'"));
      expect(settings, contains('onTap: _exportStudyDiagLog,'));
      final int fn = settings.indexOf('Future<void> _exportStudyDiagLog(');
      expect(fn, greaterThanOrEqualTo(0));
      final String body = settings.substring(fn, settings.indexOf('\n}\n', fn));
      expect(body, contains('buildStudyDiagExport('));
      expect(body, contains('saveLogToFile('));
      expect(body, contains("fileName: 'fushi_study_diag_log.txt'"));
    });

    test('阅读器埋点：账本 arrive、恢复决策、显式跳句、导航', () {
      // 入账 / 撤回的数额由 StudyClock.trace 记（+Nc / -Nc taken=），账本层不重复。
      final String nav = File(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      ).readAsStringSync();
      expect(nav, contains('_traceArrive(unitStart, unitEnd);'));
      expect(nav, contains("studyDiag('reader', 'navigate → chapter="));
      final String audio = File(
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      ).readAsStringSync();
      expect(audio, contains("'explicit cue jump → sentence="));
      final String page = File(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ).readAsStringSync();
      expect(page, contains("'open resume point chapter="));
    });
  });
}
