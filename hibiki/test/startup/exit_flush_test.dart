import 'dart:async';
import 'dart:io';

import '../pages/reader_hibiki_page_source_corpus.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';

bool hasExitFlushRegistration(String source) {
  return RegExp(
    r'ExitFlushRegistry\.instance\.register\s*\(\s*'
    r'_flushAllForProcessExit\s*,?\s*\)',
  ).hasMatch(source);
}

/// TODO-086 / BUG-192：桌面退出快杀（exit(0)）前必须 await flush 所有活跃页面尚未
/// 落库的阅读位置/统计/观看时长，否则进程一死这些 debounce/周期写就丢。本测试锁住
/// [ExitFlushRegistry] 的行为契约，以及 main.dart/reader/video 退出路径的源码结构
/// （守卫——纯运行时无法触达 windowManager / exit(0)）。
void main() {
  group('ExitFlushRegistry behaviour', () {
    setUp(() => ExitFlushRegistry.instance.clear());
    tearDown(() => ExitFlushRegistry.instance.clear());

    test('flushAll awaits every registered callback', () async {
      bool a = false;
      bool b = false;
      ExitFlushRegistry.instance.register(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        a = true;
      });
      ExitFlushRegistry.instance.register(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        b = true;
      });

      await ExitFlushRegistry.instance.flushAll();

      expect(a, isTrue, reason: 'exit flush must await page-A pending write');
      expect(b, isTrue, reason: 'exit flush must await page-B pending write');
    });

    test('unregister removes a callback so it is not run on exit', () async {
      int runs = 0;
      final ExitFlushCallback cb =
          ExitFlushRegistry.instance.register(() async => runs++);
      ExitFlushRegistry.instance.unregister(cb);

      await ExitFlushRegistry.instance.flushAll();

      expect(runs, 0,
          reason: 'unregistered (disposed page) must not be flushed');
    });

    test('a throwing callback does not abort the other callbacks', () async {
      bool other = false;
      ExitFlushRegistry.instance.register(() async => throw StateError('boom'));
      ExitFlushRegistry.instance.register(() async => other = true);

      // Must not throw — exit cleanup failure cannot block exit.
      await ExitFlushRegistry.instance.flushAll();

      expect(other, isTrue,
          reason: 'one source failing must not lose the others');
    });

    test(
        'a stuck callback is bounded by perCallbackTimeout (does not hang exit)',
        () async {
      bool fast = false;
      // Never completes — simulates a wedged native flush.
      ExitFlushRegistry.instance.register(() => Completer<void>().future);
      ExitFlushRegistry.instance.register(() async => fast = true);

      final Stopwatch sw = Stopwatch()..start();
      await ExitFlushRegistry.instance.flushAll().timeout(
          ExitFlushRegistry.perCallbackTimeout + const Duration(seconds: 2));
      sw.stop();

      expect(fast, isTrue);
      expect(
          sw.elapsed,
          lessThan(ExitFlushRegistry.perCallbackTimeout +
              const Duration(seconds: 1)),
          reason: 'stuck source must be timed out, not block exit forever');
    });

    test('flushAll clears the registry (no double-flush on a second call)',
        () async {
      int runs = 0;
      ExitFlushRegistry.instance.register(() async => runs++);
      await ExitFlushRegistry.instance.flushAll();
      await ExitFlushRegistry.instance.flushAll();
      expect(runs, 1,
          reason: 'callbacks consumed once; second flush is a no-op');
    });
  });

  group(
      'source guard: main.dart desktop close = fast exit, not engine teardown',
      () {
    final String main = File('lib/main.dart').readAsStringSync();

    test('onWindowClose no longer synchronously tears down the engine', () {
      expect(main.contains('windowManager.destroy()'), isFalse,
          reason: 'destroy()串行逐插件拆引擎是几秒~十几秒卡顿根因；退出改 exit(0)');
    });

    test('desktop close path flushes data, closes DB, then exit(0)', () {
      final int hookAt = main.indexOf('_flushAndExitForWindowClose() async');
      expect(hookAt, greaterThanOrEqualTo(0),
          reason: 'onWindowClose 必须走 flush+closeDB+exit 的快杀路径');

      final int flushAt =
          main.indexOf('ExitFlushRegistry.instance.flushAll()', hookAt);
      final int closeAt = main.indexOf('appModel.closeDatabase()', hookAt);
      final int exitAt =
          main.indexOf('platformServices.lifecycle.exitApp()', hookAt);

      expect(flushAt, greaterThan(hookAt),
          reason: '退出前必须 flush 活跃页面 pending 进度/统计');
      expect(closeAt, greaterThan(flushAt),
          reason: 'flush 之后 close database 做 WAL checkpoint 排空 pending 写');
      expect(exitAt, greaterThan(closeAt),
          reason: '数据落库（flush+closeDB）之后才 exit(0)——顺序即数据完整性保证');
    });

    test(
        'Bonsoir teardown on close uses the fast (background native stop) path',
        () {
      expect(main.contains('shutdownForExitFast()'), isTrue,
          reason: '退出切断 Bonsoir 事件源用 fast 变体（原生 stop 后台化）');
      // 收紧后超时上限 1.5s（不再 3s 吃满）。
      expect(main.contains('milliseconds: 1500'), isTrue,
          reason: '根因B：Bonsoir 退出超时从 3s 收紧到 1.5s');
    });
  });

  group('source guard: active pages register an exit flush', () {
    test('reader registers its exit flush in initState and unregisters', () {
      final String reader = readReaderPageSource();
      expect(hasExitFlushRegistration(reader), isTrue,
          reason: '阅读器活跃时必须登记退出 flush，否则退出丢最后进度/统计');
      expect(reader.contains('ExitFlushRegistry.instance.unregister('), isTrue,
          reason: 'dispose 必须注销，避免对已销毁页面 flush');
      // 退出 flush 不得依赖 WebView eval（退出期 WebView2 正在拆，eval 会挂死退出）。
      final int methodAt = reader.indexOf('_flushAllForProcessExit() async');
      expect(methodAt, greaterThanOrEqualTo(0));
      final int methodEnd = reader.indexOf('\n  }', methodAt);
      final String body = reader.substring(methodAt, methodEnd);
      expect(body.contains('_syncPositionFromWebViewProgress'), isFalse,
          reason: '退出 flush 用 debounce 缓存值落库，不能 await WebView eval');
    });

    test('video registers its exit flush in initState and unregisters', () {
      final String video =
          File('lib/src/pages/implementations/video_hibiki_page.dart')
              .readAsStringSync();
      expect(hasExitFlushRegistration(video), isTrue,
          reason: '视频活跃时必须登记退出 flush（播放位置 + 观看统计）');
      expect(video.contains('ExitFlushRegistry.instance.unregister('), isTrue,
          reason: 'dispose 必须注销');
    });
  });
}
