import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// TODO-821：检查阶段「正在连接更新源」卡很久 → 把串行逐候选 `fetchFirstSuccessfulBody`
/// 改成并发竞速选最快活源（`raceFirstSuccessfulBody`）。这些守卫固化并发语义的真实行为，
/// 撤回成串行实现任意一条都会红：
///   - 全部候选并发发起（不串行）；
///   - 胜出条件 = 合法响应（非 null），**不是最先返回**：镜像快速 403（返 null）不会赢过
///     慢但唯一可成功的直连；
///   - 直连优先 tie-break（直连在窗口内成功则优先）；
///   - 全失败才返 null；
///   - 总耗时 ≈ 最快活源那一份，而非 N 个候选超时之和（fakeAsync 计时）。
void main() {
  group('raceFirstSuccessfulBody 并发竞速（TODO-821）', () {
    test('空列表 → null', () async {
      expect(
          await raceFirstSuccessfulBody(const <String>[],
              fetch: (_) async => 'x'),
          isNull);
    });

    test('单候选 → 退化跑那一个（无并发开销，单请求行为不变）', () async {
      var count = 0;
      final String? body = await raceFirstSuccessfulBody(
        <String>['only'],
        fetch: (String url) async {
          count += 1;
          return 'BODY($url)';
        },
      );
      expect(body, 'BODY(only)');
      expect(count, 1);
    });

    test('全部候选并发发起（不串行逐个等）', () async {
      final List<String> launched = <String>[];
      await raceFirstSuccessfulBody(
        <String>['direct', 'm1', 'm2', 'm3'],
        fetch: (String url) async {
          launched.add(url);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return null; // 全失败，确保所有候选都被发起
        },
      );
      expect(launched, unorderedEquals(<String>['direct', 'm1', 'm2', 'm3']),
          reason: '并发：所有候选同时发起，不等前一个失败');
    });

    test('胜出=合法响应而非最先返回：镜像快速失败(null)不赢慢但成功的直连', () async {
      const String direct = 'https://api.github.com/x';
      const String mirror = 'https://ghfast.top/$direct';
      final String? body = await raceFirstSuccessfulBody(
        <String>[direct, mirror],
        fetch: (String url) async {
          if (url == mirror) {
            // 镜像：快速返回失败（模拟 api.github.com 经镜像必 403 → null）。
            return null;
          }
          // 直连：慢但唯一可成功。
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return 'DIRECT-OK';
        },
      );
      expect(body, 'DIRECT-OK', reason: '镜像快速 403(null) 不具胜出资格；直连虽慢但合法成功 → 胜出');
    });

    test('直连在 tie-break 窗口内成功 → 直连优先（即便镜像先到）', () async {
      const String direct = 'https://api.github.com/x';
      const String mirror = 'https://ghfast.top/$direct';
      final String? body = await raceFirstSuccessfulBody(
        <String>[direct, mirror],
        fetch: (String url) async {
          if (url == mirror) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return 'MIRROR-OK';
          }
          // 直连 100ms 到，< 镜像 10ms + 500ms tie-break 窗口 → 直连优先。
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return 'DIRECT-OK';
        },
      );
      expect(body, 'DIRECT-OK', reason: '直连在 tie-break 窗口内成功 → 直连优先');
    });

    test('直连明显慢于镜像（超出 tie-break 窗口）→ 镜像胜出', () {
      fakeAsync((FakeAsync async) {
        const String direct = 'https://api.github.com/x';
        const String mirror = 'https://ghfast.top/$direct';
        String? body;
        var done = false;
        raceFirstSuccessfulBody(
          <String>[direct, mirror],
          fetch: (String url) async {
            if (url == mirror) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return 'MIRROR-OK';
            }
            // 直连 2s 才到，远超 10ms + 500ms 窗口 → 不 tie-break。
            await Future<void>.delayed(const Duration(seconds: 2));
            return 'DIRECT-OK';
          },
        ).then((String? b) {
          body = b;
          done = true;
        });
        // 镜像 10ms 到 → 启动 500ms tie-break；窗口内直连未到 → 镜像胜出。
        async.elapse(const Duration(milliseconds: 600));
        async.flushMicrotasks();
        expect(done, isTrue, reason: 'tie-break 到点即裁决，不等慢直连');
        expect(body, 'MIRROR-OK');
      });
    });

    test('全部候选失败 → null（onFailure 记每一条）', () async {
      final List<String> failed = <String>[];
      final String? body = await raceFirstSuccessfulBody(
        <String>['a', 'b', 'c'],
        fetch: (_) async => null,
        onFailure: (String host, Object? error) => failed.add(host),
      );
      expect(body, isNull);
      expect(failed.length, 3, reason: '全失败前每个候选都记一条 onFailure');
    });

    test(
      '总耗时 ≈ 最快活源那一份，而非 N 个候选超时之和（串行回归会红）',
      () {
        fakeAsync((FakeAsync async) {
          const String direct = 'https://api.github.com/x';
          // 5 个镜像各吃满 8s 超时式失败；直连 1s 成功。串行实现要先等 8s×? 才轮到直连，
          // 并发实现只付 1s。
          final List<String> urls = <String>[
            direct,
            for (int i = 0; i < 5; i++) 'https://m$i.example/$direct',
          ];
          String? body;
          var done = false;
          raceFirstSuccessfulBody(
            urls,
            fetch: (String url) async {
              if (url == direct) {
                await Future<void>.delayed(const Duration(seconds: 1));
                return 'DIRECT-OK';
              }
              // 镜像：8s 后才失败（模拟吃满超时返 null）。
              await Future<void>.delayed(const Duration(seconds: 8));
              return null;
            },
          ).then((String? b) {
            body = b;
            done = true;
          });
          // 推进 1.1s：直连成功胜出，无需等任何镜像的 8s 超时。
          async.elapse(const Duration(milliseconds: 1100));
          async.flushMicrotasks();
          expect(done, isTrue, reason: '并发竞速：直连 1s 成功即胜出，不叠加 5×8s 镜像超时');
          expect(body, 'DIRECT-OK');
        });
      },
    );
  });

  group('UpdateCheckCancellation abort wiring (TODO-821 检查侧中断)', () {
    test('cancel() 触发已登记 abort 回调恰一次（幂等）', () {
      final UpdateCheckCancellation cancellation = UpdateCheckCancellation();
      var abortCalls = 0;
      cancellation.registerAbort(() => abortCalls += 1);

      expect(abortCalls, 0, reason: 'cancel 前不该触发');
      cancellation.cancel();
      expect(abortCalls, 1, reason: 'cancel 触发 abort 一次');
      cancellation.cancel();
      expect(abortCalls, 1, reason: '二次 cancel 不重复触发（abort 已消费）');
      expect(cancellation.isCancelled, isTrue);
    });

    test('registerAbort 晚于已 cancel → 立即触发（覆盖竞态）', () {
      final UpdateCheckCancellation cancellation = UpdateCheckCancellation()
        ..cancel();
      var abortCalls = 0;
      cancellation.registerAbort(() => abortCalls += 1);
      expect(abortCalls, 1, reason: '中断早于 client 建好时，登记即触发');
    });

    test('clearAbort 后再 cancel 不触碰旧 client', () {
      final UpdateCheckCancellation cancellation = UpdateCheckCancellation();
      var abortCalls = 0;
      cancellation.registerAbort(() => abortCalls += 1);
      cancellation.clearAbort();
      cancellation.cancel();
      expect(abortCalls, 0, reason: '已清空的 abort 不触发（避免关已释放 client）');
    });

    test('abort 回调抛异常不逃逸 cancel（强断 best-effort）', () {
      final UpdateCheckCancellation cancellation = UpdateCheckCancellation();
      cancellation
          .registerAbort(() => throw StateError('client already closed'));
      expect(cancellation.cancel, returnsNormally);
      expect(cancellation.isCancelled, isTrue);
    });
  });
}
