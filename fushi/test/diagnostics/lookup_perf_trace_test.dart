import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/lookup_perf_trace.dart';
import 'package:fushi/src/diagnostics/video_diag_log.dart';

/// [LookupPerfTrace] 的契约。
///
/// 关键在于「诊断关着时整条链路必须消失」——查词是热路径，埋点自己绝不能成为
/// 「查词卡」的新来源。其次是阶段增量的算法：汇总行读的是相对上一阶段的 Δ，找
/// 瓶颈全靠它。
void main() {
  setUp(() {
    VideoDiagLog.instance.resetForTesting();
    LookupPerfTrace.current = null;
  });

  tearDown(() {
    VideoDiagLog.instance.resetForTesting();
    LookupPerfTrace.current = null;
  });

  group('门控', () {
    test('诊断关闭时 begin 返回 null 且不装游标', () {
      final LookupPerfTrace? trace = LookupPerfTrace.begin(
        term: '辞書',
        host: 'video',
        lowMemory: false,
      );
      expect(trace, isNull);
      expect(LookupPerfTrace.current, isNull);
    });

    test('诊断开启时 begin 装上游标，finish 归还', () {
      VideoDiagLog.instance.enableForTesting();
      final LookupPerfTrace? trace = LookupPerfTrace.begin(
        term: '辞書',
        host: 'video',
        lowMemory: true,
      );
      expect(trace, isNotNull);
      expect(identical(LookupPerfTrace.current, trace), isTrue);
      trace!.finish('revealed');
      expect(LookupPerfTrace.current, isNull);
      expect(trace.isFinished, isTrue);
    });
  });

  group('阶段记录', () {
    test('同名阶段只记第一次（幂等）', () {
      VideoDiagLog.instance.enableForTesting();
      final LookupPerfTrace trace =
          LookupPerfTrace(term: 'x', host: 'video', lowMemory: false)
            ..mark('search')
            ..mark('search')
            ..mark('push');
      expect(trace.marks.map((m) => m.stage).toList(), <String>[
        'search',
        'push',
      ]);
    });

    test('finish 之后不再接受阶段，也不重复汇总', () {
      VideoDiagLog.instance.enableForTesting();
      final LookupPerfTrace trace = LookupPerfTrace(
        term: 'x',
        host: 'video',
        lowMemory: false,
      )..mark('search');
      trace.finish('revealed');
      final int before = VideoDiagLog.instance.lines.length;
      trace
        ..mark('push')
        ..finish('revealed');
      expect(trace.marks.length, 1);
      expect(
        VideoDiagLog.instance.lines.length,
        before,
        reason: 'finish 必须只打一次汇总，否则同一次查词会在流水里出现两条 done',
      );
    });
  });

  group('formatDeltas（汇总行的算法）', () {
    test('输出相对上一阶段的增量，而不是绝对时刻', () {
      final String out =
          LookupPerfTrace.formatDeltas(<({String stage, int atMs})>[
            (stage: 'warm', atMs: 1),
            (stage: 'search', atMs: 25),
            (stage: 'push', atMs: 30),
            (stage: 'rendered', atMs: 420),
          ]);
      // rendered 相对 push 是 +390ms —— 一眼看出瓶颈在 WebView 渲染而非 FFI。
      expect(out, 'warm=+1ms search=+24ms push=+5ms rendered=+390ms');
    });

    test('空阶段表给空串', () {
      expect(LookupPerfTrace.formatDeltas(const []), '');
    });
  });

  group('summary', () {
    test('带宿主、小内存状态、结局与总时长', () {
      VideoDiagLog.instance.enableForTesting();
      final LookupPerfTrace trace = LookupPerfTrace(
        term: '辞書',
        host: 'video',
        lowMemory: true,
      )..mark('warm');
      final String line = trace.summary('forced-reveal');
      expect(line, contains('host=video'));
      expect(line, contains('low-memory=true'));
      expect(line, contains('outcome=forced-reveal'));
      expect(line, contains('warm=+'));
      expect(line, contains('total='));
    });
  });

  group('redactTerm', () {
    test('短词原样', () {
      expect(LookupPerfTrace.redactTerm('辞書'), '辞書');
    });

    test('长句截断并带原长度（导出/上传时不让整句原文外流）', () {
      final String out = LookupPerfTrace.redactTerm('あいうえおかきくけこさし');
      expect(out, 'あいうえおかきく…(12)');
    });

    test('空白压平；纯空白给 (empty)', () {
      expect(LookupPerfTrace.redactTerm('  a\n b '), 'a b');
      expect(LookupPerfTrace.redactTerm('   '), '(empty)');
    });
  });
}
