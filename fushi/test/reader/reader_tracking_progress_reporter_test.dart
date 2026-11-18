import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_tracking_progress_reporter.dart';

import '../helpers/source_guard.dart';

/// BUG-4807：阅读器关书（返回键）等着追踪上报。
///
/// 上半是 [ReaderTrackingProgressReporter] 的真行为（不等、落定后去重、没落定 /
/// 抛错后再报、退出时可等完）；下半是接线守卫——规则接在 `_persistPosition` 上，且「读完」
/// 写库仍在被等待的那一段。
void main() {
  group('ReaderTrackingProgressReporter', () {
    late List<Object> errors;
    late ReaderTrackingProgressReporter reporter;

    setUp(() {
      errors = <Object>[];
      reporter = ReaderTrackingProgressReporter(
        onError: (Object error, StackTrace stack) => errors.add(error),
      );
    });

    test('report 不等上报完成：send 还挂着就已经返回', () async {
      final Completer<bool> gate = Completer<bool>();
      int started = 0;
      final bool reported = reporter.report(
        completedChapterCount: 3,
        completed: false,
        send: () {
          started++;
          return gate.future;
        },
      );
      // 同步返回，且 send 已经起跑（不是排到以后——页面可能马上销毁）。
      expect(reported, isTrue);
      expect(started, 1);

      bool settled = false;
      unawaited(reporter.whenSettled().then((_) => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse, reason: '上报在途，whenSettled 不得提前完成');

      gate.complete(true);
      await reporter.whenSettled();
      expect(errors, isEmpty);
    });

    test('已落定的进度：完成章数与是否读完都没变就不再上报', () async {
      final List<String> sent = <String>[];
      ReaderTrackingProgressSend sendOf(String tag) => () async {
        sent.add(tag);
        return true;
      };

      expect(
        reporter.report(
          completedChapterCount: 3,
          completed: false,
          send: sendOf('a'),
        ),
        isTrue,
      );
      await reporter.whenSettled();
      // 章内翻页：位置落库每页都来，这两个值不变。
      for (int i = 0; i < 5; i++) {
        expect(
          reporter.report(
            completedChapterCount: 3,
            completed: false,
            send: sendOf('dup$i'),
          ),
          isFalse,
        );
      }
      await reporter.whenSettled();
      expect(sent, <String>['a']);
    });

    test('同一份进度还在途：不重复发起', () async {
      final Completer<bool> gate = Completer<bool>();
      int started = 0;
      Future<bool> slow() {
        started++;
        return gate.future;
      }

      reporter.report(completedChapterCount: 3, completed: false, send: slow);
      for (int i = 0; i < 3; i++) {
        expect(
          reporter.report(
            completedChapterCount: 3,
            completed: false,
            send: slow,
          ),
          isFalse,
          reason: '未映射的书搜索在途时每翻一页都来，不得叠出一串并发上报',
        );
      }
      expect(started, 1);
      gate.complete(true);
      await reporter.whenSettled();
    });

    test('服务正常返回但没落定（没映射上 / 搜索失败被吞）：下次照常再报', () async {
      // BUG-4807 审查发现：服务把搜索的网络错误吞成正常返回。把「没抛错」记成已报，
      // 单章节的书本次阅读里就再也不报了。
      final List<String> sent = <String>[];
      ReaderTrackingProgressSend sendOf(String tag, {required bool settled}) =>
          () async {
            sent.add(tag);
            return settled;
          };

      reporter.report(
        completedChapterCount: 0,
        completed: false,
        send: sendOf('miss 1', settled: false),
      );
      await reporter.whenSettled();
      expect(errors, isEmpty, reason: '没落定不是错误');

      // 同一份进度，下一次位置落库：照常调服务。
      expect(
        reporter.report(
          completedChapterCount: 0,
          completed: false,
          send: sendOf('miss 2', settled: false),
        ),
        isTrue,
      );
      await reporter.whenSettled();
      expect(
        reporter.report(
          completedChapterCount: 0,
          completed: false,
          send: sendOf('linked', settled: true),
        ),
        isTrue,
      );
      await reporter.whenSettled();
      // 落定之后才停。
      expect(
        reporter.report(
          completedChapterCount: 0,
          completed: false,
          send: sendOf('dup', settled: true),
        ),
        isFalse,
      );
      expect(sent, <String>['miss 1', 'miss 2', 'linked']);
    });

    test('完成章数变了、或只有「读完」变了，都要上报', () async {
      final List<String> sent = <String>[];
      ReaderTrackingProgressSend sendOf(String tag) => () async {
        sent.add(tag);
        return true;
      };

      reporter.report(
        completedChapterCount: 3,
        completed: false,
        send: sendOf('3/false'),
      );
      // 章末（progress >= 0.999）让完成章数 +1，章号没变。
      reporter.report(
        completedChapterCount: 4,
        completed: false,
        send: sendOf('4/false'),
      );
      // 末章章末：完成章数不变，只有「读完」翻了。
      reporter.report(
        completedChapterCount: 4,
        completed: true,
        send: sendOf('4/true'),
      );
      // 往回翻：读完撤回、章数回退，同样是新进度。
      reporter.report(
        completedChapterCount: 3,
        completed: false,
        send: sendOf('3/false again'),
      );
      await reporter.whenSettled();
      expect(sent, <String>['3/false', '4/false', '4/true', '3/false again']);
    });

    test('上报抛错：记错误，同一份进度下次照常再报', () async {
      int calls = 0;
      Future<bool> failing() async {
        calls++;
        throw StateError('network');
      }

      reporter.report(
        completedChapterCount: 2,
        completed: false,
        send: failing,
      );
      await reporter.whenSettled();
      expect(calls, 1);
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());

      // 没报出去的进度不算「已报」。
      final bool again = reporter.report(
        completedChapterCount: 2,
        completed: false,
        send: () async {
          calls++;
          return true;
        },
      );
      expect(again, isTrue);
      await reporter.whenSettled();
      expect(calls, 2);
      expect(errors, hasLength(1));
    });

    test('send 同步抛错也走 onError，不逃成未捕获错误', () async {
      reporter.report(
        completedChapterCount: 1,
        completed: false,
        send: () => throw ArgumentError('sync'),
      );
      await reporter.whenSettled();
      expect(errors.single, isA<ArgumentError>());
    });

    test('旧进度没落定 / 抛错，不抹掉之后已发起的新进度', () async {
      final Completer<bool> first = Completer<bool>();
      final Completer<bool> second = Completer<bool>();
      final List<int> sent = <int>[];
      reporter.report(
        completedChapterCount: 1,
        completed: false,
        send: () => first.future,
      );
      reporter.report(
        completedChapterCount: 2,
        completed: false,
        send: () => second.future,
      );
      reporter.report(
        completedChapterCount: 3,
        completed: false,
        send: () async {
          sent.add(3);
          return true;
        },
      );
      first.completeError(StateError('late failure'));
      second.complete(false);
      await reporter.whenSettled();
      expect(errors, hasLength(1));
      // 3 已经落定：再来一次 3 不重报。
      expect(
        reporter.report(
          completedChapterCount: 3,
          completed: false,
          send: () async {
            sent.add(33);
            return true;
          },
        ),
        isFalse,
      );
      expect(sent, <int>[3]);
    });

    test('whenSettled 等完所有在途上报，自己不抛', () async {
      final Completer<bool> a = Completer<bool>();
      final Completer<bool> b = Completer<bool>();
      reporter.report(
        completedChapterCount: 1,
        completed: false,
        send: () => a.future,
      );
      reporter.report(
        completedChapterCount: 2,
        completed: false,
        send: () => b.future,
      );
      bool settled = false;
      final Future<void> done = reporter.whenSettled().then(
        (_) => settled = true,
      );
      a.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      b.completeError(StateError('x'));
      await done;
      expect(settled, isTrue);
      // 没有在途上报时立刻完成。
      await reporter.whenSettled();
    });
  });

  group('接线：位置落库不等追踪上报', () {
    final String navigation = File(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String persist = maskComments(
      methodBody(navigation, 'Future<void> _persistPosition('),
    );

    test('_persistPosition 经上报口发起，不 await recordBookProgress', () {
      final int report = persist.indexOf('_trackingProgressReporter.report(');
      expect(report, isNonNegative);
      final int record = persist.indexOf('.recordBookProgress(');
      expect(
        record,
        greaterThan(report),
        reason: 'recordBookProgress 只能出现在 send 里',
      );
      expect(
        RegExp(r'await\s+[^;]*recordBookProgress\(').hasMatch(persist),
        isFalse,
        reason:
            '返回键等着 _persistPosition；recordBookProgress 里有站点搜索，'
            '耗时无上界，不得回到等待链上',
      );
      expect(
        persist.substring(report),
        contains(
          'send: () => appModel.mediaTrackingService.recordBookProgress(',
        ),
      );
    });

    test('去重键是「完成章数 + 是否读完」，不是章号', () {
      expect(
        compactCode(persist),
        contains(
          'finalintcompletedChapterCount=section+(progress>=0.999?1:0);',
        ),
      );
      final String call = persist.substring(
        persist.indexOf('_trackingProgressReporter.report('),
      );
      expect(call, contains('completedChapterCount: completedChapterCount,'));
      expect(call, contains('completed: completed,'));
    });

    test('「读完」写库仍被等待，且在发起上报之前', () {
      final int mark = persist.indexOf(
        'await appModel.database.markEpubBookCompletedIfUnset(',
      );
      expect(mark, isNonNegative, reason: '读完时间戳必须在被等待的路径上落库');
      expect(
        persist.indexOf('_trackingProgressReporter.report('),
        greaterThan(mark),
      );
    });

    test('追踪关着时不发起上报（也不记成「已报」）', () {
      final int gate = persist.indexOf(
        'if (!appModel.isMediaTrackingOn) return;',
      );
      expect(gate, isNonNegative);
      expect(
        persist.indexOf('_trackingProgressReporter.report('),
        greaterThan(gate),
      );
    });

    test('进程退出把在途上报等完，且排在本地写穿之后', () {
      final String exit = maskComments(
        methodBody(
          navigation,
          'Future<void> _flushAllForProcessExit() async {',
        ),
      );
      final int settled = exit.indexOf(
        'await _trackingProgressReporter.whenSettled();',
      );
      expect(settled, isNonNegative);
      for (final String local in <String>[
        'await _flushPosition();',
        'await _flushReadingStats();',
        'await _audiobookController?.flushPosition();',
      ]) {
        final int at = exit.indexOf(local);
        expect(at, isNonNegative);
        expect(settled, greaterThan(at), reason: '慢网不得拖累本地落盘：$local');
      }
    });

    test('关书后在途上报仍有人等：dispose 交给退出汇合点的那一笔带着它', () {
      final String deferred = maskComments(
        methodBody(
          navigation,
          'Future<void> _flushPositionAndTrackingReport() async {',
        ),
      );
      final int flush = deferred.indexOf('await _flushPosition();');
      final int settled = deferred.indexOf(
        'await _trackingProgressReporter.whenSettled();',
      );
      expect(flush, isNonNegative);
      expect(
        settled,
        greaterThan(flush),
        reason: '位置先落盘，再等上报：慢网不得拖累位置；且这次 flush 自己发起的上报也要等到',
      );
      // 页面自己登记的退出回调在 dispose 时注销；不经 defer 交出去，关书之后
      // （读完最后一章 → 返回 → 立刻关 app）就没有任何退出路径等这次上报。
      final String dispose = maskComments(methodBody(page, 'void dispose() {'));
      expect(
        dispose,
        contains(
          'ExitFlushRegistry.instance.defer(_flushPositionAndTrackingReport);',
        ),
      );
    });

    test('上报的落定与否取自服务返回值', () {
      final String service = File(
        '../packages/fushi_engine/lib/media/tracking/media_tracking_service.dart',
      ).readAsStringSync();
      expect(service, contains('Future<bool> recordBookProgress({'));
      final String reporterSource = File(
        'lib/src/reader/reader_tracking_progress_reporter.dart',
      ).readAsStringSync();
      expect(
        reporterSource,
        contains(
          'typedef ReaderTrackingProgressSend = Future<bool> Function();',
        ),
      );
    });

    test('返回键那条链（_syncAndFlushPosition）不等上报', () {
      final String flush = maskComments(
        methodBody(navigation, 'Future<void> _syncAndFlushPosition() async {'),
      );
      expect(containsIdentifier(flush, '_trackingProgressReporter'), isFalse);
      expect(containsIdentifier(flush, 'whenSettled'), isFalse);
    });

    test('上报口的失败回调落 ErrorLogService', () {
      final int field = page.indexOf(
        'final ReaderTrackingProgressReporter _trackingProgressReporter =',
      );
      expect(field, isNonNegative);
      final String init = page.substring(field, page.indexOf(');\n', field));
      expect(init, contains('ErrorLogService.instance.log('));
      expect(init, contains("'ReaderFushi.recordBookProgress'"));
    });
  });
}
