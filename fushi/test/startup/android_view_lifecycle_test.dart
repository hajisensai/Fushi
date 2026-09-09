import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/android_view_lifecycle.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late AndroidViewLifecycle lifecycle;
  final ExitFlushRegistry registry = ExitFlushRegistry.instance;

  setUp(() async {
    registry.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.setPref('position', '0');
    lifecycle = AndroidViewLifecycle(registry: registry);
  });

  tearDown(() async {
    registry.clear();
    await db.close();
  });

  test(
    'BUG-2280 detach and reattach retain DB and later page flushes',
    () async {
      int position = 12;
      registry.register(() => db.setPref('position', position.toString()));

      await lifecycle.handleState(AppLifecycleState.detached);
      expect(await db.getPref('position'), '12');
      await lifecycle.handleState(AppLifecycleState.resumed);
      await db.setPref('service-write', 'still-running');
      expect(await db.getPref('service-write'), 'still-running');

      position = 24;
      await lifecycle.handleState(AppLifecycleState.detached);
      expect(await db.getPref('position'), '24');
      expect(registry.callbackCount, 1);
    },
  );

  test(
    'reattach during pending flush never schedules a later DB shutdown',
    () async {
      final Completer<void> release = Completer<void>();
      int calls = 0;
      int active = 0;
      int maxActive = 0;
      registry.register(() async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        await release.future;
        await db.setPref('position', calls.toString());
        active--;
      });

      final Future<void> paused = lifecycle.handleState(
        AppLifecycleState.paused,
      );
      await lifecycle.handleState(AppLifecycleState.resumed);
      await db.setPref('foreground-write', 'during-flush');
      registry.defer(() => db.setPref('newly-disposed-page', 'saved'));
      final Future<void> detached = lifecycle.handleState(
        AppLifecycleState.detached,
      );
      expect(identical(paused, detached), isTrue);
      release.complete();
      await detached;
      expect(calls, 2);
      expect(maxActive, 1, reason: 'queued flushes must run serially');
      expect(await db.getPref('newly-disposed-page'), 'saved');
      expect(registry.deferredCount, 0);
      expect(await db.getPref('foreground-write'), 'during-flush');

      await db.setPref('foreground-write', 'after-flush');
      await lifecycle.handleState(AppLifecycleState.detached);
      expect(await db.getPref('position'), '3');
      expect(await db.getPref('foreground-write'), 'after-flush');
    },
  );

  test(
    'background states persist pages and consume disposed-page writes once',
    () async {
      int writes = 0;
      int deferred = 0;
      registry.register(() async {
        await db.setPref('position', (++writes).toString());
      });
      registry.defer(() async {
        deferred++;
        await db.setPref('disposed-page', '42');
      });
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        await lifecycle.handleState(state);
      }
      expect(await db.getPref('position'), '4');
      expect(await db.getPref('disposed-page'), '42');
      expect(deferred, 1);
      await lifecycle.handleState(AppLifecycleState.resumed);
      expect(writes, 4);
    },
  );

  test(
    'BUG-2280 退后台 flush 失败不得变成 unhandled async error',
    () async {
      // 唯一调用点是 `unawaited(_androidViewLifecycle.handleState(state))`
      // （fushi/lib/src/main.dart 的 didChangeAppLifecycleState），没有人 catch
      // 这个 future。所以 _drain 一旦 completeError，丢一次 flush 窗口就会升级成
      // 崩溃——而本层的既定语义恰恰相反：ExitFlushRegistry._runGuarded 已经把每个
      // 回调的异常兜住并 debugPrint，「退出清理失败不该阻止退出」。
      //
      // 为什么是源码守卫而不是行为测试：ExitFlushRegistry 的构造函数是私有的
      // （`ExitFlushRegistry._()`），测试注不进一个「flushAll 会抛」的实现；而真实
      // 的 flushAll 逐回调 _runGuarded，拿会抛的回调去驱动只会得到恒绿的空壳断言。
      final String source = File(
        'lib/src/startup/android_view_lifecycle.dart',
      ).readAsStringSync();
      final int drain = source.indexOf('Future<void> _drain(');
      expect(drain, greaterThanOrEqualTo(0), reason: '_drain 改名了，守卫要跟着改');
      final String body = source.substring(drain);

      expect(
        body,
        isNot(contains('completeError')),
        reason: '退后台 flush 是 best-effort：调用方 unawaited，以错误完成 = 崩溃',
      );
      // complete() 必须在 finally 里——放在 try 尾部时，抛异常的那一路会让 future
      // 永远不完成，下一次 _flush() 拿到的 pending 也就永远 await 不回来。
      final int fin = body.indexOf('} finally {');
      expect(fin, greaterThanOrEqualTo(0), reason: '_drain 必须有 finally 收口');
      final int done = body.indexOf('completion.complete()');
      expect(
        done,
        greaterThan(fin),
        reason: 'completion.complete() 必须在 finally 里，失败路径也要让 future 完成',
      );
    },
  );
}
