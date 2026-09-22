import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/video_diag_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [VideoDiagLog] 的纯函数与门控契约。
///
/// 重点不是「能写字符串」，而是三条排查时会被依赖的不变量：
///  ① 行格式与 mpv log-file 对齐（uptime 列宽 / 级别名 / 类别），否则两份日志没法
///    并排读；
///  ② mpv `--msg-level` 语法的过滤语义（含 `foo=no` 关类、`vo/gpu` 按段回退），
///    否则用户照 mpv 的习惯写过滤串会得到静默错误的结果；
///  ③ 关着时**一行都不记**——诊断的全部代价都押在这条上。
void main() {
  group('formatLine / formatUptime（mpv log-file 对齐）', () {
    test('uptime 列是右对齐 6 字符的秒 + 3 位毫秒', () {
      expect(VideoDiagLog.formatUptime(0), '[     0.000]');
      expect(VideoDiagLog.formatUptime(12345), '[    12.345]');
      expect(VideoDiagLog.formatUptime(1234567), '[  1234.567]');
      // 负数（时钟回拨等）按 0，不产生 `[-1.-23]` 这种没法解析的列。
      expect(VideoDiagLog.formatUptime(-5), '[     0.000]');
    });

    test('一行含 wall clock、uptime、级别名、类别，且多行压成一行', () {
      final String line = VideoDiagLog.formatLine(
        at: DateTime.utc(2026, 9, 22, 14, 3, 11, 234),
        uptimeMs: 12345,
        category: VideoDiagCategory.lookup,
        level: VideoDiagLevel.v,
        message: 'begin\nterm=x',
      );
      expect(line, startsWith('2026-09-22 14:03:11.234'));
      expect(line, contains('[    12.345]'));
      expect(line, contains('[v][lookup]'));
      // 换行压成 ⏎——流水一行一事件才 grep 得动。
      expect(line, contains('begin⏎term=x'));
      expect(line.contains('\n'), isFalse);
    });

    test('级别名与 libmpv mp_log_levels 同名同序（越靠前越严重）', () {
      expect(
        VideoDiagLevel.values.map((VideoDiagLevel l) => l.name).toList(),
        <String>[
          'no',
          'fatal',
          'error',
          'warn',
          'info',
          'status',
          'v',
          'debug',
          'trace',
        ],
      );
      expect(VideoDiagLevel.error.index, lessThan(VideoDiagLevel.v.index));
    });
  });

  group('parseMsgLevel / passesFilter（mpv --msg-level 语义）', () {
    test('解析多段，非法片段与未知级别名整条忽略', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        'all=v, mpv=debug ,bogus,frame=nope,x=',
      );
      expect(levels['all'], VideoDiagLevel.v);
      expect(levels['mpv'], VideoDiagLevel.debug);
      expect(levels.containsKey('bogus'), isFalse);
      expect(levels.containsKey('frame'), isFalse, reason: '未知级别名不得静默降级');
      expect(levels.containsKey('x'), isFalse);
    });

    test('阈值语义：级别比阈值严或相等才过', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        'all=info',
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.warn, levels),
        isTrue,
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.info, levels),
        isTrue,
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.v, levels),
        isFalse,
      );
    });

    test('精确类别优先于 all', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        'all=error,frame=trace',
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.trace, levels),
        isTrue,
      );
      expect(
        VideoDiagLog.passesFilter('lookup', VideoDiagLevel.warn, levels),
        isFalse,
      );
    });

    test('带斜杠的类别按段回退（mpv 的 vo=… 能盖住 vo/gpu）', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        'all=error,mpv=debug',
      );
      // mpv/vo/gpu → mpv/vo → mpv 命中。
      expect(
        VideoDiagLog.passesFilter('mpv/vo/gpu', VideoDiagLevel.v, levels),
        isTrue,
      );
      // 与之无关的类别仍落 all。
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.v, levels),
        isFalse,
      );
    });

    test('foo=no 关掉整类（不需要额外的关闭分支）', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        'all=trace,mpv=no',
      );
      expect(
        VideoDiagLog.passesFilter('mpv/vo', VideoDiagLevel.fatal, levels),
        isFalse,
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.trace, levels),
        isTrue,
      );
    });

    test('未列出且无 all 时落默认级别 v', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        'mpv=debug',
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.v, levels),
        isTrue,
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.debug, levels),
        isFalse,
      );
    });

    test('默认过滤串把 mpv 转写压到 info（verbose 另有 libmpv 自己的 log-file）', () {
      final Map<String, VideoDiagLevel> levels = VideoDiagLog.parseMsgLevel(
        VideoDiagLog.defaultMsgLevel,
      );
      expect(
        VideoDiagLog.passesFilter('mpv/vo', VideoDiagLevel.v, levels),
        isFalse,
        reason: '默认不把 libmpv 的 verbose 行重复灌进统一时间轴',
      );
      expect(
        VideoDiagLog.passesFilter('mpv/vo', VideoDiagLevel.warn, levels),
        isTrue,
      );
      expect(
        VideoDiagLog.passesFilter('frame', VideoDiagLevel.v, levels),
        isTrue,
      );
    });
  });

  group('redactVideoDiagSecrets（导出前脱敏）', () {
    test('URL 查询参数里的令牌只抹值，host + path 保留', () {
      const String line =
          '[cplayer] Playing: https://emby.example.com/Videos/42/stream.mkv'
          '?api_key=0123456789abcdef&static=true&MediaSourceId=x';
      final String out = redactVideoDiagSecrets(line);
      expect(out, contains('https://emby.example.com/Videos/42/stream.mkv'));
      expect(out, contains('api_key=[redacted]'));
      expect(out, isNot(contains('0123456789abcdef')));
      expect(out, contains('static=true'), reason: '非敏感参数原样');
    });

    test('Authorization / X-Emby-Token 头与 Token="…" 属性都抹掉', () {
      const String text =
          'X-Emby-Token: deadbeef\n'
          'Authorization: MediaBrowser Client="Fushi", Token="cafebabe"\n'
          'http-proxy: http://user:pw@127.0.0.1:1/ token=abc';
      final String out = redactVideoDiagSecrets(text);
      expect(out, isNot(contains('deadbeef')));
      expect(out, isNot(contains('cafebabe')));
      expect(out, contains('X-Emby-Token: [redacted]'));
    });

    test('没有敏感字段的行逐字节不变', () {
      const String line = '[vo/gpu] using d3d11 1920x1080 hwdec=d3d11va';
      expect(redactVideoDiagSecrets(line), line);
    });
  });

  group('trimTail', () {
    test('未超限原样返回', () {
      final List<int> bytes = 'a\nb\n'.codeUnits;
      expect(VideoDiagLog.trimTail(bytes, maxBytes: 100), 'a\nb\n');
    });

    test('超限保尾并丢掉第一段残行', () {
      final List<int> bytes = 'aaaa\nbbbb\ncccc\n'.codeUnits;
      final String out = VideoDiagLog.trimTail(bytes, maxBytes: 12);
      expect(out.startsWith('aaaa'), isFalse, reason: '最旧的行应被丢弃');
      expect(out.endsWith('cccc\n'), isTrue);
      expect(
        out.split('\n').first.isEmpty || out.startsWith('bbbb'),
        isTrue,
        reason: '截断处必须对齐行首，不得留半行',
      );
    });
  });

  group('门控（关着时一行都不记）', () {
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      dir = await Directory.systemTemp.createTemp('video-diag-log-test');
      VideoDiagLog.instance.resetForTesting();
    });

    tearDown(() async {
      VideoDiagLog.instance.resetForTesting();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('未启用时 add 不进内存环、不建文件', () async {
      await VideoDiagLog.instance.init(
        directoryOverride: dir,
        prefsOverride: await SharedPreferences.getInstance(),
      );
      videoDiag(VideoDiagCategory.frame, VideoDiagLevel.warn, 'should not log');
      await VideoDiagLog.instance.flush();
      expect(VideoDiagLog.instance.lines, isEmpty);
      expect(
        videoDiagEnabledFor(VideoDiagCategory.frame, VideoDiagLevel.warn),
        isFalse,
      );
    });

    test('启用后落内存环并追加到文件', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        VideoDiagLog.enabledPrefKey: true,
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await VideoDiagLog.instance.init(
        directoryOverride: dir,
        prefsOverride: prefs,
      );
      videoDiag(VideoDiagCategory.frame, VideoDiagLevel.warn, 'jank window');
      await VideoDiagLog.instance.flush();

      expect(
        VideoDiagLog.instance.lines.any(
          (String l) => l.contains('jank window'),
        ),
        isTrue,
      );
      final File file = File('${dir.path}/${VideoDiagLog.fileName}');
      expect(file.existsSync(), isTrue);
      final String body = await file.readAsString();
      expect(body, contains('[warn][frame] jank window'));
      // init 自己会打一条 session start（启用时），证明文件链路通。
      expect(body, contains('[session] session start'));
    });

    test('过滤串把某类压下去后该类不再落行', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        VideoDiagLog.enabledPrefKey: true,
        VideoDiagLog.msgLevelPrefKey: 'all=error',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await VideoDiagLog.instance.init(
        directoryOverride: dir,
        prefsOverride: prefs,
      );
      videoDiag(VideoDiagCategory.frame, VideoDiagLevel.v, 'verbose line');
      videoDiag(VideoDiagCategory.video, VideoDiagLevel.error, 'error line');
      await VideoDiagLog.instance.flush();
      final List<String> lines = VideoDiagLog.instance.lines;
      expect(lines.any((String l) => l.contains('verbose line')), isFalse);
      expect(lines.any((String l) => l.contains('error line')), isTrue);
    });

    test('mpvLogFilePath 在未 init（目录未知）时为 null，不瞎猜路径', () {
      VideoDiagLog.instance.resetForTesting();
      expect(VideoDiagLog.instance.mpvLogFilePath, isNull);
    });

    test('init 后 mpvLogFilePath 指向同目录的 mpv 日志', () async {
      await VideoDiagLog.instance.init(
        directoryOverride: dir,
        prefsOverride: await SharedPreferences.getInstance(),
      );
      expect(
        VideoDiagLog.instance.mpvLogFilePath,
        '${dir.path}/${VideoDiagLog.mpvLogFileName}',
      );
    });

    test('关掉诊断不清空已记录的流水（复现完先关再导出是常见顺序）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        VideoDiagLog.enabledPrefKey: true,
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await VideoDiagLog.instance.init(
        directoryOverride: dir,
        prefsOverride: prefs,
      );
      videoDiag(VideoDiagCategory.video, VideoDiagLevel.info, 'keep me');
      await VideoDiagLog.instance.setEnabled(false, prefsOverride: prefs);
      await VideoDiagLog.instance.flush();
      expect(
        VideoDiagLog.instance.lines.any((String l) => l.contains('keep me')),
        isTrue,
      );
      expect(VideoDiagLog.instance.enabled, isFalse);
    });
  });
}
