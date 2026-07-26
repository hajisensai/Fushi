import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1109 守卫：窄屏（compact）状态卡不得把降级原因整行藏掉。
///
/// 原实现是 `if (!compact && state.fallbackReason != null)` —— 窗口宽度不足 840px
/// 时降级原因**完全不渲染**。而同一张卡右侧的 `_StatusPill` 在 compact 下照常亮
/// 「已降级」，于是窄屏用户看到的是「出事了 + 不告诉你出了什么事」，比两个都不显示
/// 更难排查：用户知道降级了，却拿不到任何可执行处置。
///
/// compact 该省的是**次要信息**（采样率 / 声道 / 位深，即 `format`），不是唯一的
/// 诊断线索。修复后只收窄行数（`maxLines: compact ? 2 : 3`），不整行丢弃。
///
/// 捕获工作台整页依赖真实 WebView 平台视图，widget test 起不来，故守住源码接线。
void main() {
  late String cardSource;

  setUpAll(() {
    final String source = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();

    // 抽 _SessionOverviewCard 的类体，避免「整文件命中」把断言蒙混过去。
    final int start = source.indexOf('class _SessionOverviewCard');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 _SessionOverviewCard，测试锚点过期');
    final int end = source.indexOf('class _LatestLineCard', start);
    expect(end, greaterThan(start), reason: '找不到类体结束锚点');
    cardSource = source.substring(start, end);
  });

  test('降级原因不再被 compact 整行丢弃（BUG-1109）', () {
    expect(
      cardSource.contains('if (state.fallbackReason != null)'),
      isTrue,
      reason: '降级原因的渲染条件必须只看 fallbackReason，不看屏宽',
    );
    expect(
      cardSource.contains('!compact && state.fallbackReason != null'),
      isFalse,
      reason: '窄屏藏掉降级原因正是 BUG-1109，不得回退',
    );
  });

  test('compact 只收窄行数，不丢弃内容（BUG-1109）', () {
    expect(
      cardSource.contains('maxLines: compact ? 2 : 3'),
      isTrue,
      reason: '降级原因在窄屏应收窄到 2 行，而不是整行消失',
    );
  });

  test('compact 省掉的是次要信息而非诊断线索（BUG-1109）', () {
    // 采样率/声道/位深这类次要信息仍可以在窄屏省掉——这是 compact 的正当用途。
    expect(
      cardSource
          .contains("compact\n                      ? '\$phase · \$audio'"),
      isTrue,
      reason: 'compact 仍应省掉 format（次要信息），这是它的正当用途',
    );
  });

  test('降级徽章与降级原因的显示条件必须对称（BUG-1109）', () {
    // 不对称正是这个 bug 的本质：徽章无条件亮，原因却被藏。
    final int pill = cardSource.indexOf('_StatusPill(');
    expect(pill, greaterThanOrEqualTo(0), reason: '找不到 _StatusPill');
    final String pillSource = cardSource.substring(pill);
    expect(
      pillSource.contains('state.isDegraded'),
      isTrue,
      reason: '徽章按 isDegraded 亮',
    );
    expect(
      pillSource.contains('compact'),
      isFalse,
      reason: '徽章不看屏宽；原因也不该看——两者必须对称',
    );
  });
}
