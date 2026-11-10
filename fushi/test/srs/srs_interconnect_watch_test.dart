// 复习同步互联快速通道（srs_interconnect_watch.dart）：第一次长轮询只拿基线，令牌变了才同步；断线后补一轮；
// 老 host（不支持）不同步、也不刷请求；本机变动去抖成一次推送。
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fushi_engine/sync/srs_change_feed.dart' show SrsChangePoll;
import 'package:test/test.dart';
import 'package:fushi/src/srs/srs_interconnect_watch.dart';

void main() {
  test('基线不算变化；令牌变了同步一次', () async {
    final List<int?> asked = <int?>[];
    final List<int> replies = <int>[5, 5, 6];
    int changes = 0;
    final Completer<void> done = Completer<void>();
    late SrsInterconnectWatcher w;
    w = SrsInterconnectWatcher(
      ready: () async => true,
      wait: (int? after) async {
        asked.add(after);
        if (replies.isEmpty) {
          w.stop();
          if (!done.isCompleted) done.complete();
          return after == null ? null : SrsChangePoll(after);
        }
        return SrsChangePoll(replies.removeAt(0));
      },
      onChange: () async => changes++,
    );
    w.start();
    await done.future;
    expect(asked, <int?>[null, 5, 5, 6]);
    expect(changes, 1);
  });

  test('断线：退避后令牌作废并补同步一轮', () async {
    int calls = 0;
    int changes = 0;
    final Completer<void> done = Completer<void>();
    late SrsInterconnectWatcher w;
    w = SrsInterconnectWatcher(
      ready: () async => true,
      maxBackoff: const Duration(milliseconds: 5),
      wait: (int? after) async {
        calls++;
        if (calls == 1) return const SrsChangePoll(1);
        if (calls == 2) throw const SocketExceptionStub();
        w.stop();
        if (!done.isCompleted) done.complete();
        return const SrsChangePoll(1);
      },
      onChange: () async => changes++,
    );
    w.start();
    await done.future;
    expect(changes, 1, reason: '有过基线的连接断了：重连前先补一轮');
  });

  // BUG-4380：本机写完 head，host 推进令牌也叫醒本机自己的长轮询；以前照样空跑一轮，「立即同步」报完「已同步」后
  // 同步状态行又从「准备」走一遍。
  test('令牌推进全是本机自己写的（ownOnly）：只记新令牌、不同步；之后别人写的照常同步', () async {
    final List<int?> asked = <int?>[];
    final List<SrsChangePoll> replies = <SrsChangePoll>[
      const SrsChangePoll(5),
      const SrsChangePoll(7, ownOnly: true),
      const SrsChangePoll(8),
    ];
    int changes = 0;
    final Completer<void> done = Completer<void>();
    late SrsInterconnectWatcher w;
    w = SrsInterconnectWatcher(
      ready: () async => true,
      wait: (int? after) async {
        asked.add(after);
        if (replies.isEmpty) {
          w.stop();
          if (!done.isCompleted) done.complete();
          return after == null ? null : SrsChangePoll(after);
        }
        return replies.removeAt(0);
      },
      onChange: () async => changes++,
    );
    w.start();
    await done.future;
    expect(asked, <int?>[null, 5, 7, 8], reason: '自己写的那段也要把令牌往前挪');
    expect(changes, 1, reason: '只有别人写的那次（8）同步');
  });

  test('老 host 不支持：不同步，按长间隔重查', () async {
    int calls = 0;
    int changes = 0;
    final SrsInterconnectWatcher w = SrsInterconnectWatcher(
      ready: () async => true,
      unsupportedRecheck: const Duration(hours: 1),
      wait: (int? after) async {
        calls++;
        return null;
      },
      onChange: () async => changes++,
    );
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    w.stop();
    expect(calls, 1);
    expect(changes, 0);
  });

  test('没准备好（后台 / 互联没开）：不发请求', () async {
    int calls = 0;
    final SrsInterconnectWatcher w = SrsInterconnectWatcher(
      ready: () async => false,
      idleRecheck: const Duration(hours: 1),
      wait: (int? after) async {
        calls++;
        return const SrsChangePoll(1);
      },
      onChange: () async {},
    );
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    w.stop();
    expect(calls, 0);
  });

  test('本机连续变动去抖成一次推送', () async {
    int pushes = 0;
    final SrsLocalPush push = SrsLocalPush(
      push: () async {
        pushes++;
        return true;
      },
      debounce: const Duration(milliseconds: 20),
    );
    for (int i = 0; i < 5; i++) {
      push.trigger();
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(pushes, 1);
    push.dispose();
  });

  // 反馈 XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL：host 不可达时每答一张卡（去抖 5 s）就探测一轮死地址。
  test('推送失败后指数退避（有上限），期间的触发合并到到期时一次；成功 / 重置清零', () {
    fakeAsync((FakeAsync fa) {
      final List<Duration> at = <Duration>[];
      bool reachable = false;
      final SrsLocalPush push = SrsLocalPush(
        push: () async {
          at.add(fa.elapsed);
          return reachable;
        },
        debounce: const Duration(seconds: 5),
        backoffBase: const Duration(seconds: 30),
        maxBackoff: const Duration(minutes: 2),
        clock: () => DateTime(2026).add(fa.elapsed),
      );
      // 用户不停答卡：每 5 s 一次变动，共 10 分钟。
      for (int i = 0; i < 120; i++) {
        push.trigger();
        fa.elapse(const Duration(seconds: 5));
      }
      // 不退避的话是 120 次；退避 30 s → 60 s → 120 s（封顶）……
      expect(at.length, lessThan(12), reason: 'pushes at $at');
      for (int i = 2; i < at.length; i++) {
        final Duration gap = at[i] - at[i - 1];
        expect(gap, lessThanOrEqualTo(const Duration(minutes: 2, seconds: 6)));
      }
      expect(
        at[2] - at[1],
        greaterThanOrEqualTo(const Duration(seconds: 30)),
        reason: 'backs off after the first failure',
      );
      expect(push.failures, at.length);
      expect(push.blockedUntil, isNotNull);

      // 网络恢复（长轮询连上 / 手动同步）：清掉退避，下一次变动按普通去抖推。
      push.resetBackoff();
      reachable = true;
      final int before = at.length;
      final Duration t0 = fa.elapsed;
      push.trigger();
      fa.elapse(const Duration(seconds: 6));
      expect(at.length, before + 1);
      expect(at.last - t0, const Duration(seconds: 5));
      expect(push.failures, 0);
      expect(push.blockedUntil, isNull);
      push.dispose();
    });
  });

  // 审查 S-8：复习中几乎每答一张卡就推一轮（新小段 + 写 head + 唤醒对端）。改为最长等待批量，离开复习页立即推。
  test('复习中按最长等待批量推送（变动不顺延），离开复习页 / 进后台立即推', () {
    fakeAsync((FakeAsync fa) {
      final List<Duration> at = <Duration>[];
      bool reviewing = true;
      final SrsLocalPush push = SrsLocalPush(
        push: () async {
          at.add(fa.elapsed);
          return true;
        },
        batching: () => reviewing,
        clock: () => DateTime(2026).add(fa.elapsed),
      );
      expect(
        kSrsLocalPushMaxWait,
        greaterThanOrEqualTo(const Duration(seconds: 30)),
      );
      expect(
        kSrsLocalPushMaxWait,
        lessThanOrEqualTo(const Duration(seconds: 60)),
      );
      // 每 5 s 答一张卡，共 3 分钟：去抖的话一张卡一轮（或一直顺延），这里是每 maxWait 一轮。
      for (int i = 0; i < 36; i++) {
        push.trigger();
        fa.elapse(const Duration(seconds: 5));
      }
      final int expected =
          const Duration(minutes: 3).inSeconds ~/
          kSrsLocalPushMaxWait.inSeconds;
      expect(
        at.length,
        inInclusiveRange(expected - 1, expected + 1),
        reason: '$at',
      );
      for (int i = 1; i < at.length; i++) {
        expect(at[i] - at[i - 1], greaterThanOrEqualTo(kSrsLocalPushMaxWait));
      }
      // 再答一张，然后离开复习页：不等 maxWait，立即推。
      push.trigger();
      fa.elapse(const Duration(seconds: 1));
      final int before = at.length;
      reviewing = false;
      push.flush();
      fa.flushMicrotasks();
      fa.elapse(Duration.zero);
      expect(at.length, before + 1, reason: 'flush pushes right away');
      expect(push.pending, isFalse);
      // 没有待推的 flush 什么都不做。
      push.flush();
      fa.elapse(const Duration(seconds: 1));
      expect(at.length, before + 1);
      // 不在复习页：普通去抖（10 s）。
      push.trigger();
      fa.elapse(kSrsLocalPushDebounce - const Duration(seconds: 1));
      expect(at.length, before + 1);
      fa.elapse(const Duration(seconds: 2));
      expect(at.length, before + 2);
      push.dispose();
    });
  });

  // BUG-4380：「立即同步」报完「已同步」后，排着的推送去抖到期又各跑一轮空同步，同步状态行在提示后继续走。
  group('srsSyncSupersedingPushes（立即同步带上排着的推送）', () {
    test('排着的推送被这一轮带上：同步成功后不再单独推；之后的新变动照常推', () {
      fakeAsync((FakeAsync fa) {
        int pushes = 0;
        final SrsLocalPush push = SrsLocalPush(
          push: () async {
            pushes++;
            return true;
          },
          debounce: const Duration(seconds: 10),
        );
        push.trigger();
        fa.elapse(const Duration(seconds: 3));
        bool ok = false;
        unawaited(
          srsSyncSupersedingPushes<bool>(
            <SrsLocalPush>[push],
            () async => true,
            synced: (bool r) => r,
          ).then((bool r) => ok = r),
        );
        fa.flushMicrotasks();
        expect(ok, isTrue);
        expect(push.pending, isFalse);
        fa.elapse(const Duration(minutes: 1));
        expect(pushes, 0, reason: '立即同步已经带上了，不再空跑一轮');
        push.trigger();
        fa.elapse(const Duration(seconds: 11));
        expect(pushes, 1);
        push.dispose();
      });
    });

    test('这一轮没同步成功（有错 / 抛错）：撤掉的推送排回去；原本没排着的不凭空加一轮', () {
      fakeAsync((FakeAsync fa) {
        int pushesA = 0;
        int pushesB = 0;
        final SrsLocalPush a = SrsLocalPush(
          push: () async {
            pushesA++;
            return true;
          },
          debounce: const Duration(seconds: 10),
        );
        final SrsLocalPush b = SrsLocalPush(
          push: () async {
            pushesB++;
            return true;
          },
          debounce: const Duration(seconds: 10),
        );
        a.trigger();
        unawaited(
          srsSyncSupersedingPushes<bool>(
            <SrsLocalPush>[a, b],
            () async => false,
            synced: (bool r) => r,
          ),
        );
        fa.flushMicrotasks();
        expect(a.pending, isTrue);
        expect(b.pending, isFalse);
        fa.elapse(const Duration(seconds: 11));
        expect(pushesA, 1);
        expect(pushesB, 0);

        a.trigger();
        Object? thrown;
        unawaited(
          srsSyncSupersedingPushes<bool>(
            <SrsLocalPush>[a, b],
            () async => throw StateError('offline'),
            synced: (bool r) => r,
          ).catchError((Object e) {
            thrown = e;
            return false;
          }),
        );
        fa.flushMicrotasks();
        expect(thrown, isA<StateError>(), reason: '错误原样抛给调用方');
        expect(a.pending, isTrue);
        fa.elapse(const Duration(seconds: 11));
        expect(pushesA, 2);
        a.dispose();
        b.dispose();
      });
    });

    test('清掉推送的失败退避（用户明说「现在就同步」）', () {
      fakeAsync((FakeAsync fa) {
        final SrsLocalPush push = SrsLocalPush(
          push: () async => false,
          debounce: const Duration(seconds: 1),
          clock: () => DateTime(2026).add(fa.elapsed),
        );
        push.trigger();
        fa.elapse(const Duration(seconds: 2));
        expect(push.blockedUntil, isNotNull);
        unawaited(
          srsSyncSupersedingPushes<bool>(
            <SrsLocalPush>[push],
            () async => true,
            synced: (bool r) => r,
          ),
        );
        fa.flushMicrotasks();
        expect(push.failures, 0);
        expect(push.blockedUntil, isNull);
        push.dispose();
      });
    });
  });

  test('推送抛错与返回 false 同样退避', () {
    fakeAsync((FakeAsync fa) {
      int calls = 0;
      final SrsLocalPush push = SrsLocalPush(
        push: () async {
          calls++;
          throw StateError('No reachable Fushi server address');
        },
        debounce: const Duration(seconds: 5),
        clock: () => DateTime(2026).add(fa.elapsed),
      );
      push.trigger();
      fa.elapse(const Duration(seconds: 6));
      push.trigger();
      fa.elapse(const Duration(seconds: 6));
      expect(calls, 1, reason: 'second trigger waits for the backoff');
      fa.elapse(const Duration(seconds: 30));
      expect(calls, 2);
      push.dispose();
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
