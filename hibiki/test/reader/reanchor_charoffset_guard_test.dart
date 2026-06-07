import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-109 回归守卫（源码扫描，沿用 `reader_live_settings_guard_test.dart` 的
/// `File(...).readAsStringSync()` + `contains` 模式）。
///
/// 现象：在阅读器里切换主题 / 字体时，正文会「翻页」——当前阅读位置跳到相邻页，
/// 而切字号同样走这条路径却（相对）稳。
///
/// 根因：切字号 / 字体 / 主题 live 变更最终都进 `_applyStylesLive` →
/// `reanchorAfterStyleChange`。旧实现按**粗粒度进度分数**重锚：
///   reflow 前 `calculateProgress()`（已读字符/总字符）→ 换样式 →
///   `scrollToProgressPaged(progress)` → `findNodeAtProgress`（`Math.ceil(总字×progress)`
///   反推节点）→ `alignToPage` 取整到分页边界。
/// 字体 / 主题改变后字形宽度与列宽变化，同一进度分数反推出的字符落点 + 取整后落到
/// **相邻页边界**，于是「翻页」。
///
/// 修复：对齐到同文件 `setChromeInsets` 已验证的**精确字符偏移**重锚——reflow 前
/// `getFirstVisibleCharOffset()` 记下首个可见字符，换样式后 rAF
/// `scrollToCharOffset(charOffset, scrollBefore)` 落到该字符真实所在页，并用
/// page-stable hint（±1 列保持原页）抑制微小重排的可见跳动。复用成熟路径，根因修复。
///
/// 谁把 `reanchorAfterStyleChange` 退回 `calculateProgress` / `scrollToProgressPaged`
/// 的粗粒度重锚，本测试红。
void main() {
  final String src = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  /// 截取 `reanchorAfterStyleChange = function(...) { ... };` 的函数体，避免误命中
  /// 同文件别处（如 `updatePageSize` 仍用 progress）的字符串。
  String reanchorBody() {
    const String marker = 'reanchorAfterStyleChange = function';
    final int start = src.indexOf(marker);
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 reanchorAfterStyleChange 函数定义');
    final int end = src.indexOf('\n};', start);
    expect(end, greaterThan(start),
        reason: '找不到 reanchorAfterStyleChange 函数体结尾');
    return src.substring(start, end);
  }

  test('reanchorAfterStyleChange 用精确字符偏移重锚（BUG-109）', () {
    final String body = reanchorBody();

    expect(
      body,
      contains('getFirstVisibleCharOffset'),
      reason: 'reanchorAfterStyleChange 必须 reflow 前用 getFirstVisibleCharOffset '
          '捕捉首个可见字符（对齐 setChromeInsets 的精确锚定），否则切主题/字体翻页（BUG-109）。',
    );
    expect(
      body,
      contains('scrollToCharOffset'),
      reason: 'reanchorAfterStyleChange 必须用 scrollToCharOffset 恢复到该字符真实所在页，'
          '勿退回 scrollToProgressPaged 的进度分数重锚（BUG-109）。',
    );
  });

  test('reanchorAfterStyleChange 不再用粗粒度进度分数（BUG-109）', () {
    final String body = reanchorBody();

    // 查「调用形式」（带括号），注释里作对比说明的提及（`calculateProgress →`）不算。
    expect(
      body,
      isNot(contains('scrollToProgressPaged(')),
      reason: 'scrollToProgressPaged 按 alignToPage 取整到分页边界，字体/主题重排后会跳页。'
          '改用 scrollToCharOffset（BUG-109）。',
    );
    expect(
      body,
      isNot(contains('calculateProgress(')),
      reason: 'calculateProgress 返回粗粒度已读字符比例，重排后映射到不同页。'
          '改用 getFirstVisibleCharOffset 精确捕捉（BUG-109）。',
    );
  });

  test('reanchorAfterStyleChange 传 page-stable hint（scrollBefore）抑制微跳', () {
    final String body = reanchorBody();
    expect(
      body,
      contains('getPagePosition'),
      reason: 'reflow 前须记 getPagePosition 作为 scrollToCharOffset 的 hintScroll，'
          '让 ±1 列的微小重排保持原页，避免可见跳动（对齐 setChromeInsets）。',
    );
  });
}
