import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/book_exit_sync_scope.dart';

/// TODO-132 诉求B 契约测试：退出书触发的同步动作挂 app-scope，与页面生命周期解耦。
/// 锁住 [BookExitSyncScope] 的行为契约——它让游离的关书同步 Future 在「页面销毁后
/// 仍跑完」，并让进程退出路径能有界等它落定（不阻塞 UI、不打断式弹窗，那是
/// sync_auto_trigger 的源码守卫管的；本表只管 app-scope 收集 + drain）。
void main() {
  group('BookExitSyncScope', () {
    setUp(() => BookExitSyncScope.instance.clear());
    tearDown(() => BookExitSyncScope.instance.clear());

    test(
        'registered sync future runs to completion AFTER its page is disposed '
        '(app-scope, not page-scope)', () async {
      bool synced = false;
      final Completer<void> gate = Completer<void>();

      // 模拟 onWillPop fire-and-forget 触发的关书同步：一个游离 Future，登记进
      // app-scope。onWillPop 不 await 它（这里也不 await register 的返回）。
      BookExitSyncScope.instance.register(() async {
        await gate.future; // 远端传输尚未完成
        synced = true;
      }());

      // 模拟「页面销毁」——onWillPop 返回、widget dispose、栈 pop。app-scope 的
      // Future 与页面无任何引用关系，故不受影响。这里没有任何页面对象可销毁，
      // 正是要点：Future 的存活不依赖页面。
      expect(synced, isFalse, reason: '传输未完成时同步动作尚未落定');
      expect(BookExitSyncScope.instance.inFlightCount, 1);

      // 远端传输完成（页面早已"销毁"）。
      gate.complete();
      await BookExitSyncScope.instance.drain();

      expect(synced, isTrue, reason: '页面销毁后，app-scope 同步动作必须仍跑完（HSA 契约）');
      expect(BookExitSyncScope.instance.inFlightCount, 0,
          reason: '完成后自动注销，集合不泄漏');
    });

    test('completed future auto-unregisters (no leak)', () async {
      final Future<void> f = Future<void>.value();
      BookExitSyncScope.instance.register(f);
      await f;
      // whenComplete 注销是微任务，等一拍。
      await Future<void>.delayed(Duration.zero);
      expect(BookExitSyncScope.instance.inFlightCount, 0);
    });

    test('drain awaits every in-flight sync before returning', () async {
      bool a = false;
      bool b = false;
      BookExitSyncScope.instance.register(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        a = true;
      }());
      BookExitSyncScope.instance.register(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        b = true;
      }());

      await BookExitSyncScope.instance.drain();

      expect(a, isTrue, reason: 'drain 必须等关书同步 A 落定');
      expect(b, isTrue, reason: 'drain 必须等关书同步 B 落定');
    });

    test('drain on empty scope returns immediately', () async {
      // 无在飞同步时 drain 不挂、不抛。
      await BookExitSyncScope.instance.drain();
      expect(BookExitSyncScope.instance.inFlightCount, 0);
    });

    test('a throwing sync future does not abort drain or throw', () async {
      bool other = false;
      BookExitSyncScope.instance
          .register(Future<void>.error(StateError('remote boom')));
      BookExitSyncScope.instance.register(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        other = true;
      }());

      // drain 不得抛——退出清理失败不能阻止退出。
      await BookExitSyncScope.instance.drain();

      expect(other, isTrue, reason: '一个关书同步失败不得拖垮其余 / 不得让退出报错');
    });

    test('a stuck sync future is bounded by drain timeout (does not hang exit)',
        () async {
      final Completer<void> neverCompletes = Completer<void>();
      BookExitSyncScope.instance.register(neverCompletes.future);

      final Stopwatch sw = Stopwatch()..start();
      // 卡住的传输不得无限阻塞退出：有界放行。
      await BookExitSyncScope.instance
          .drain(timeout: const Duration(milliseconds: 50));
      sw.stop();

      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: '卡住的关书同步必须被 drain 上限放行，不能拖死退出');
      // 收尾，避免悬挂 completer 报 pending（测试卫生）。
      neverCompletes.complete();
    });
  });
}
