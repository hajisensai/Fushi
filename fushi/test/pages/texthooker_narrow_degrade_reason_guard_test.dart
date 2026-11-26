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
///
/// 2026-11-24 d6f2962d5a 把会话卡的文案与取舍抽成 `_SessionSummary`（M3E 色块
/// `_SessionOverviewCard` 与 Cupertino 侧栏共用同一份判据）。不变式原样搬了过去，
/// 所以本守卫查两处：**取舍**在 `_SessionSummary`（降级原因条件、行数、chip 标签、
/// 状态签文案），**渲染**在两个消费端（必须照 `hint.maxLines` 摆、状态签只按阶段出现）。
void main() {
  late String cardSource;
  late String summarySource;
  late String appleSidebarSource;

  String classBody(String source, String name) {
    final int start = maskComments(source).indexOf('class $name');
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 $name，测试锚点过期');
    return balancedBlockFrom(source, start, what: '$name 类体');
  }

  setUpAll(() {
    final String source = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    // 以类声明的真实代码锚点 + 花括号配对抽体，邻接类增删不会把窗口误扩/截断。
    cardSource = classBody(source, '_SessionOverviewCard ');
    summarySource = classBody(source, '_SessionSummary ');
    appleSidebarSource = File(
      'lib/src/pages/implementations/games/apple/apple_workbench_sidebar.part.dart',
    ).readAsStringSync();
  });

  test('两套渲染端都照 _SessionSummary 给的行数摆说明行（BUG-1110）', () {
    for (final MapEntry<String, String> e in <String, String>{
      '_SessionOverviewCard': cardSource,
      'apple_workbench_sidebar': appleSidebarSource,
    }.entries) {
      expect(
        containsCodeLine(
          e.value,
          'for (final _SessionHint hint in summary.hints)',
        ),
        isTrue,
        reason: '${e.key} 必须渲染 summary.hints（降级原因在里面）',
      );
      expect(
        namedArgumentValues(
          e.value,
          'maxLines',
        ).any((String v) => v.trim() == 'hint.maxLines'),
        isTrue,
        reason: '${e.key} 不得另写行数 / 按屏宽丢行，只能照 hint.maxLines',
      );
    }
  });

  test('降级原因不再被 compact 整行丢弃（BUG-1110）', () {
    expect(
      containsCodeLine(summarySource, 'if (state.fallbackReason != null)'),
      isTrue,
      reason: '降级原因的渲染条件必须只看 fallbackReason，不看屏宽',
    );
    expect(
      containsCodeLine(
        summarySource,
        '!compact && state.fallbackReason != null',
      ),
      isFalse,
      reason: '窄屏藏掉降级原因正是 BUG-1110，不得回退',
    );
  });

  test('compact 只收窄行数，不丢弃内容（BUG-1110）', () {
    expect(
      containsCodeLine(summarySource, 'maxLines: compact ? 2 : 3'),
      isTrue,
      reason: '降级原因在窄屏应收窄到 2 行，而不是整行消失',
    );
  });

  test('compact 省掉的是次要信息而非诊断线索（BUG-1110）', () {
    // 采样率/声道/位深（format）这类次要信息仍可以在窄屏省掉——这是 compact 的正当
    // 用途。2026-10 工作台重做后它落在「音频源 chip」的标签上：compact 时只显示
    // 音频源名，宽屏才缀 format（窄屏的 format 收进 chip tooltip）。
    final String code = maskComments(summarySource);
    final String? label = initializerExpression(code, 'audioChipLabel');
    expect(label, isNotNull, reason: '找不到 audioChipLabel；改写了就同步改本守卫');
    final String expr = label!;
    final int question = expr.indexOf('?');
    final int colon = expr.indexOf(':', question);
    expect(question, greaterThan(0), reason: 'audioChipLabel 应是 compact 三元');
    expect(
      expr.substring(0, question).contains('compact'),
      isTrue,
      reason: '音频 chip 标签按 compact 分支',
    );
    expect(
      expr.substring(question, colon).contains('format'),
      isFalse,
      reason: 'compact 分支不该带 format（采样率/声道/位深是次要信息）',
    );
    expect(
      expr.substring(colon).contains('format'),
      isTrue,
      reason: '非 compact 分支必须仍带 format',
    );
  });

  test('降级徽章与降级原因的显示条件必须对称（BUG-1110）', () {
    // 不对称正是这个 bug 的本质：徽章无条件亮，原因却被藏。
    final EnclosingCall pill = enclosingCallOf(
      cardSource,
      'label: summary.statusLabel',
    );
    expect(
      pill.text.startsWith('_StatusPill('),
      isTrue,
      reason: '降级标签应由 _StatusPill 承载',
    );
    expect(
      pill.text.contains('compact'),
      isFalse,
      reason: '徽章不看屏宽；原因也不该看——两者必须对称',
    );
    final List<String> statusLabel = namedArgumentValues(
      summarySource,
      'statusLabel',
    );
    expect(
      statusLabel,
      hasLength(1),
      reason: '_SessionSummary 只该有一处 statusLabel',
    );
    expect(
      statusLabel.single.contains('state.isDegraded'),
      isTrue,
      reason: '徽章按 isDegraded 亮',
    );
    expect(
      statusLabel.single.contains('compact'),
      isFalse,
      reason: '徽章文案不看屏宽；原因也不该看——两者必须对称',
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
