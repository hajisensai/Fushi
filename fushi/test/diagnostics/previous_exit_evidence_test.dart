// 崩溃报告正文里的证据取舍（BUG-5497 / BUG-5498 / BUG-5499）：
// - macOS `.ips` 的 ObjC 异常原因与抛出处的栈不能丢（反馈 3LRSlAOkXu）；
// - 会话标记的长内存采样挤不掉平台证据（反馈 rfmUsTI66G）；
// - 同一进程之后还活着的死亡记录不是死因（反馈 632O8xFQSV）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';

Map<String, Object?> _frame(int image, int offset, String symbol) =>
    <String, Object?>{
      'imageIndex': image,
      'imageOffset': offset,
      'symbol': symbol,
    };

void main() {
  group('BUG-5497：.ips 的 ObjC 异常', () {
    // 真实形态：未捕获的 unrecognized selector，崩溃线程前 8 帧是 abort 链，
    // 第 13 帧才是调用方。
    final String header = jsonEncode(<String, Object?>{
      'app_name': 'fushi',
      'app_version': '3.4.0',
      'bug_type': '309',
      'timestamp': '2026-11-26 16:32:44.00 +0900',
    });
    final List<Object?> images = <Object?>[
      <String, Object?>{'name': 'libsystem_kernel.dylib'},
      <String, Object?>{'name': 'libsystem_pthread.dylib'},
      <String, Object?>{'name': 'libsystem_c.dylib'},
      <String, Object?>{'name': 'libc++abi.dylib'},
      <String, Object?>{'name': 'libobjc.A.dylib'},
      <String, Object?>{'name': 'CoreFoundation'},
      <String, Object?>{'name': 'fushi_caller_plugin'},
    ];
    final List<Object?> crashedFrames = <Object?>[
      _frame(0, 0x9650, '__pthread_kill'),
      _frame(1, 0x697c, 'pthread_kill'),
      _frame(2, 0x7b458, 'abort'),
      _frame(3, 0x10, 'abort_message'),
      _frame(3, 0x20, 'demangling_terminate_handler()'),
      _frame(4, 0x30, '_objc_terminate()'),
      _frame(3, 0x40, 'std::__terminate(void (*)())'),
      _frame(3, 0x50, '__cxa_throw'),
      _frame(4, 0x60, 'objc_exception_throw'),
      _frame(5, 0x70, '-[NSObject(NSObject) doesNotRecognizeSelector:]'),
      _frame(5, 0x80, '___forwarding___'),
      _frame(5, 0x90, '_CF_forwarding_prep_0'),
      _frame(6, 0xabc, '-[FushiCaller handleEvent:]'),
    ];
    final String body = jsonEncode(<String, Object?>{
      'exception': <String, Object?>{
        'type': 'EXC_CRASH',
        'signal': 'SIGABRT',
        'codes': '0x0000000000000000, 0x0000000000000000',
      },
      'exceptionReason': <String, Object?>{
        'arguments': <Object?>['-[NSView fooBar:]', '0x600000001'],
        'format_string': '%@: unrecognized selector sent to instance %p',
        'name': 'NSInvalidArgumentException',
        'type': 'objc-exception',
        'composed_message':
            '-[NSView fooBar:]: unrecognized selector sent to instance 0x600000001',
        'class': 'NSException',
      },
      'termination': <String, Object?>{
        'namespace': 'SIGNAL',
        'code': 6,
        'indicator': 'Abort trap: 6',
      },
      'faultingThread': 0,
      'usedImages': images,
      'lastExceptionBacktrace': <Object?>[
        _frame(5, 0x1, '__exceptionPreprocess'),
        _frame(4, 0x60, 'objc_exception_throw'),
        _frame(5, 0x70, '-[NSObject(NSObject) doesNotRecognizeSelector:]'),
        _frame(5, 0x80, '___forwarding___'),
        _frame(5, 0x90, '_CF_forwarding_prep_0'),
        _frame(6, 0xabc, '-[FushiCaller handleEvent:]'),
      ],
      'threads': <Object?>[
        <String, Object?>{
          'queue': 'com.apple.main-thread',
          'frames': crashedFrames,
        },
      ],
    });

    test('摘要带异常原因、抛出处的栈，崩溃线程跳过 abort 链露出调用方', () {
      final String summary = summarizeMacIpsReport('$header\n$body')!;
      expect(
        summary,
        contains(
          'exceptionReason: objc-exception NSInvalidArgumentException: '
          '-[NSView fooBar:]: unrecognized selector sent to instance',
        ),
      );
      final int backtraceAt = summary.indexOf('last exception backtrace:');
      final int threadAt = summary.indexOf('faulting thread #0');
      expect(backtraceAt, greaterThan(0));
      expect(threadAt, greaterThan(backtraceAt));
      expect(
        summary.substring(backtraceAt, threadAt),
        contains('fushi_caller_plugin+0xabc -[FushiCaller handleEvent:]'),
      );
      final String thread = summary.substring(threadAt);
      expect(thread, contains('（跳过开头 8 帧 abort 机制）'));
      expect(thread, isNot(contains('__pthread_kill')));
      expect(thread, contains('libobjc.A.dylib+0x60 objc_exception_throw'));
      expect(
        thread,
        contains('fushi_caller_plugin+0xabc -[FushiCaller handleEvent:]'),
        reason: '默认 12 帧上限下，调用方（原第 13 帧）也要在',
      );
    });

    test('没有 exceptionReason / 不以 abort 开头时照旧输出', () {
      final String plain = jsonEncode(<String, Object?>{
        'exception': <String, Object?>{
          'type': 'EXC_BAD_ACCESS',
          'signal': 'SIGSEGV',
        },
        'faultingThread': 0,
        'usedImages': images,
        'threads': <Object?>[
          <String, Object?>{
            'frames': <Object?>[_frame(6, 0x10, 'crashHere')],
          },
        ],
      });
      final String summary = summarizeMacIpsReport('$header\n$plain')!;
      expect(summary, isNot(contains('exceptionReason')));
      expect(summary, isNot(contains('last exception backtrace')));
      expect(summary, isNot(contains('跳过开头')));
      expect(summary, contains('fushi_caller_plugin+0x10 crashHere'));
    });
  });

  group('BUG-5498：长内存采样挤不掉平台证据', () {
    // 每条采样约 2000 字，6 条就超过 6000 字的正文上限。
    final List<String> samples = <String>[
      for (int i = 0; i < kSessionMemorySampleCount; i++)
        '14:4$i:06 rss=1987MB ${'fcb=[x@y.dart:1×9]' * 110}',
    ];
    final PreviousSession previous = PreviousSession(
      pid: 19160,
      startedAt: 1000,
      version: '3.3.0',
      lifecycle: 'inactive',
      lifecycleAt: 5000,
      clean: false,
      memorySamples: samples,
    );

    test('会话标记条目的判定标签在内存采样之前', () {
      final String text = describeUncleanPreviousSession(previous)!.text;
      expect(text.indexOf('疑似闪退'), lessThan(text.indexOf('memory=[')));
    });

    test('决定种类的平台证据排最前且完整，会话标记条目单独限长', () {
      final List<ExitReportEntry> entries = <ExitReportEntry>[
        describeUncleanPreviousSession(previous)!,
        ...formatWindowsCrashSummary(
          'at=2026-11-25T14:48:00 code=0xc0000005 module=fushidicts.dll+0x1234',
        ),
      ];
      final PreviousExitVerdict v = classifyPreviousExit(
        entries,
        version: '3.3.0',
        nowMs: 9000,
      )!;
      expect(v.kind, PreviousExitKind.nativeCrash);
      expect(v.summary, startsWith('[$kWindowsCrashSummarySource]'));
      expect(v.summary, contains('fushidicts.dll+0x1234'));
      expect(v.summary, contains('[$kPreviousExitUncleanSource]'));
      expect(v.summary, contains('疑似闪退'));
      expect(
        v.summary.length,
        lessThanOrEqualTo(kExitVerdictSummaryMaxChars + 40),
      );
    });
  });

  group('BUG-5499：同一进程之后还活着的死亡记录不是死因', () {
    // 反馈 632O8xFQSV 的时间线：28.404 厂商 vss 告警转储记成 CRASH_NATIVE，28.501
    // Dart 会话起来，34.057 最后一次记生命周期，36.626 因改权限被 KILL UID。
    const int crashAt = 28404;
    const int startedAt = 28501;
    const int lifecycleAt = 34057;
    const int killAt = 36626;
    const PreviousSession previous = PreviousSession(
      pid: 7975,
      startedAt: startedAt,
      version: '3.3.0',
      lifecycle: 'resumed',
      lifecycleAt: lifecycleAt,
      clean: false,
    );

    Map<String, Object?> record(String reason, String description, int at) =>
        <String, Object?>{
          'reason': reason,
          'status': 0,
          'description': description,
          'importance': reason == 'CRASH_NATIVE' ? 1000 : 100,
          'pssKb': 0,
          'rssKb': 0,
          'timestamp': at,
          'processName': 'app.fushi.reader',
          'pid': 7975,
        };

    PreviousExitVerdict? verdictFor(List<Map<String, Object?>> reasons) =>
        classifyPreviousExit(
          <ExitReportEntry>[
            describeUncleanPreviousSession(previous)!,
            ...formatAndroidExitReports(<Object?, Object?>{
              'sdk': 35,
              'reasons': reasons,
            }, previous: previous),
          ],
          version: '3.3.0',
          nowMs: 40000,
        );

    test('更晚的 KILL UID 记录才是死因，前面的告警转储不算原生崩溃', () {
      final PreviousExitVerdict v = verdictFor(<Map<String, Object?>>[
        record('OTHER', '[KILL UID] MANAGE_EXTERNAL_STORAGE changed.', killAt),
        record('CRASH_NATIVE', "APP's vss abnormal", crashAt),
      ])!;
      expect(v.kind, PreviousExitKind.permissionChanged);
      expect(v.worthReporting, isFalse);
      expect(v.atMs, killAt);
      expect(v.summary, startsWith('[$kAndroidExitInfoSource] reason=OTHER'));
      expect(v.summary, contains('（同一进程之后仍在运行，不是死因）reason=CRASH_NATIVE'));
    });

    test('没有更晚的记录、但会话标记之后还记到生命周期：转储同样不算', () {
      final PreviousExitVerdict v = verdictFor(<Map<String, Object?>>[
        record('CRASH_NATIVE', "APP's vss abnormal", crashAt),
      ])!;
      expect(v.kind, PreviousExitKind.unexpected);
    });

    test('死在最后一次生命周期之后的 CRASH_NATIVE 照常是原生崩溃', () {
      final PreviousExitVerdict v = verdictFor(<Map<String, Object?>>[
        record('CRASH_NATIVE', '', lifecycleAt + 500),
      ])!;
      expect(v.kind, PreviousExitKind.nativeCrash);
      expect(v.summary, isNot(contains('不是死因')));
    });
  });
}
