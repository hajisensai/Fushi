import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1110 守卫：窄屏（compact）状态卡不得把降级原因整行藏掉。
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

    // 以类声明的真实代码锚点 + 花括号配对抽体，邻接类增删不会把窗口误扩/截断。
    final String searchable = maskComments(source);
    final int start = searchable.indexOf('class _SessionOverviewCard');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 _SessionOverviewCard，测试锚点过期');
    cardSource = balancedBlockFrom(
      source,
      start,
      what: '_SessionOverviewCard 类体',
    );
  });

  test('降级原因不再被 compact 整行丢弃（BUG-1110）', () {
    expect(
      containsCodeLine(cardSource, 'if (state.fallbackReason != null)'),
      isTrue,
      reason: '降级原因的渲染条件必须只看 fallbackReason，不看屏宽',
    );
    expect(
      containsCodeLine(
        cardSource,
        '!compact && state.fallbackReason != null',
      ),
      isFalse,
      reason: '窄屏藏掉降级原因正是 BUG-1110，不得回退',
    );
  });

  test('compact 只收窄行数，不丢弃内容（BUG-1110）', () {
    expect(
      containsCodeLine(cardSource, 'maxLines: compact ? 2 : 3'),
      isTrue,
      reason: '降级原因在窄屏应收窄到 2 行，而不是整行消失',
    );
  });

  test('compact 省掉的是次要信息而非诊断线索（BUG-1110）', () {
    // 采样率/声道/位深（format）这类次要信息仍可以在窄屏省掉——这是 compact 的正当
    // 用途。2026-10 工作台重做后它落在「音频源 chip」的标签上：compact 时只显示
    // 音频源名，宽屏才缀 format（窄屏的 format 收进 chip tooltip）。
    final String code = maskComments(cardSource);
    final String? label = initializerExpression(code, 'audioChipLabel');
    expect(label, isNotNull, reason: '找不到 audioChipLabel；改写了就同步改本守卫');
    final String expr = label!;
    final int question = expr.indexOf('?');
    final int colon = expr.indexOf(':', question);
    expect(question, greaterThan(0), reason: 'audioChipLabel 应是 compact 三元');
    expect(expr.substring(0, question).contains('compact'), isTrue,
        reason: '音频 chip 标签按 compact 分支');
    expect(expr.substring(question, colon).contains('format'), isFalse,
        reason: 'compact 分支不该带 format（采样率/声道/位深是次要信息）');
    expect(expr.substring(colon).contains('format'), isTrue,
        reason: '非 compact 分支必须仍带 format');
  });

  test('降级徽章与降级原因的显示条件必须对称（BUG-1110）', () {
    // 不对称正是这个 bug 的本质：徽章无条件亮，原因却被藏。
    final EnclosingCall pill = enclosingCallOf(
      cardSource,
      'label: state.isDegraded',
    );
    expect(pill.text.startsWith('_StatusPill('), isTrue,
        reason: '降级标签应由 _StatusPill 承载');
    expect(
      pill.text.contains('state.isDegraded'),
      isTrue,
      reason: '徽章按 isDegraded 亮',
    );
    expect(
      pill.text.contains('compact'),
      isFalse,
      reason: '徽章不看屏宽；原因也不该看——两者必须对称',
    );
    // 徽章被放进 chip 行时的条件也不看屏宽。
    expect(
      containsCodeLine(
        cardSource,
        'if (state.phase != GalHookSessionPhase.idle) statusPill,',
      ),
      isTrue,
      reason: '徽章在 chip 行里只按会话阶段出现，不看屏宽',
    );
  });
}
