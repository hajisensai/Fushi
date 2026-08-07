import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// [WebViewDeathGuard] 的处置策略行为测试。
///
/// 救命动作（「传了非 null 回调」）由源码守卫
/// `webview_render_process_gone_guard_test.dart` 钉住；这里钉的是死亡之后那套
/// 顺序：先抢救数据、再重建、重建有预算。
void main() {
  test('先 flush 再重建：顺序不能反（否则重建把易失增量丢掉）', () async {
    final List<String> order = <String>[];
    final WebViewDeathGuard guard = WebViewDeathGuard(
      surface: 'test',
      flushBeforeRebuild: () async => order.add('flush'),
      afterRebuild: () => order.add('rebuild'),
      reporter: (_, __) {},
    );
    await guard.handleDeath(didCrash: true);
    expect(order, <String>['flush', 'rebuild']);
  });

  test('epoch 递增换出新 rebuildKey（同一 key 不会重建平台视图）', () async {
    final WebViewDeathGuard guard = WebViewDeathGuard(
      surface: 'reader',
      reporter: (_, __) {},
    );
    final Key first = guard.rebuildKey;
    expect(guard.epoch, 0);
    await guard.handleDeath();
    expect(guard.epoch, 1);
    expect(guard.rebuildKey, isNot(first));
  });

  test('flush 抛错不挡重建（丢一次增量好过永久白屏）', () async {
    bool rebuilt = false;
    final WebViewDeathGuard guard = WebViewDeathGuard(
      surface: 'test',
      flushBeforeRebuild: () async => throw StateError('db closed'),
      afterRebuild: () => rebuilt = true,
      reporter: (_, __) {},
    );
    await guard.handleDeath();
    expect(rebuilt, isTrue);
    expect(guard.epoch, 1);
  });

  test('重建预算用尽后只抢救不重建（内存压力下的重建风暴止损）', () async {
    int flushes = 0;
    int rebuilds = 0;
    final WebViewDeathGuard guard = WebViewDeathGuard(
      surface: 'test',
      maxRebuilds: 2,
      flushBeforeRebuild: () async => flushes++,
      afterRebuild: () => rebuilds++,
      reporter: (_, __) {},
    );
    for (int i = 0; i < 5; i++) {
      await guard.handleDeath();
    }
    expect(flushes, 5, reason: '每次死亡都要抢救数据，预算与它无关');
    expect(rebuilds, 2, reason: '重建次数封顶在 maxRebuilds');
    expect(guard.epoch, 2);
    expect(guard.isRebuildBudgetExhausted, isTrue);
    expect(guard.deathCount, 5);
  });

  test('afterRebuild 为 null = 只救命不重建（阅读器那种恢复锚会写回退的宿主）', () async {
    int flushes = 0;
    final WebViewDeathGuard guard = WebViewDeathGuard(
      surface: 'reader_fushi',
      flushBeforeRebuild: () async => flushes++,
      reporter: (_, __) {},
    );
    await guard.handleDeath();
    expect(flushes, 1);
    expect(guard.deathCount, 1);
  });

  test('同一次死亡的重入回调被丢弃（epoch 不会一次跳两代）', () async {
    late final WebViewDeathGuard guard;
    int rebuilds = 0;
    guard = WebViewDeathGuard(
      surface: 'test',
      flushBeforeRebuild: () async {
        // 抢救途中再进来一次（宿主自己也挂了监听 / 平台重复发事件）。
        await guard.handleDeath();
      },
      afterRebuild: () => rebuilds++,
      reporter: (_, __) {},
    );
    await guard.handleDeath();
    expect(guard.epoch, 1);
    expect(guard.deathCount, 1);
    expect(rebuilds, 1);
  });
}
