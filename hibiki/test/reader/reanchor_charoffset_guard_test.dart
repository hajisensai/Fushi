import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-109 / TODO-736 回归守卫（源码扫描，沿用 `reader_live_settings_guard_test.dart` 的
/// `File(...).readAsStringSync()` + `contains` 模式）。
///
/// 现象：在阅读器里切换主题 / 字体 / 字号时，正文会「翻页」乃至多次后弹回章首。
///
/// 根因：切字号 / 字体 / 主题 live 变更最终都进 `_applyStylesLive` →
/// `reanchorAfterStyleChange`。旧实现按**粗粒度进度分数**重锚：reflow 前
/// `calculateProgress()`（已读字符/总字符）→ 换样式 →
/// `scrollToProgressPaged` / `scrollToProgressContinuous` 反推节点 → 取整落到相邻页。
/// 字体 / 主题改变后字形宽度与列宽变化，同一进度分数反推出的落点漂移 → 「翻页」/累积偏移。
///
/// 修复：对齐到同文件 `setChromeInsets` 已验证的**精确字符偏移**重锚——reflow 前
/// `getFirstVisibleCharOffset()` 记下首个可见字符，换样式后 `scrollToCharOffset(...)`
/// 落到该字符真实所在页。**分页版**额外用 page-stable hint（`getPagePosition`，±1 列保持
/// 原页）；**连续版**（TODO-736 B-2）也改成 char-precise 并去掉旧的
/// `calculateProgress → scrollToProgressContinuous` 粗粒度分数。
///
/// 谁把任一版 `reanchorAfterStyleChange` 退回 `calculateProgress` /
/// `scrollToProgress*` 的粗粒度重锚，本测试红。
void main() {
  final String src = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  /// 截取分页版 `reanchorAfterStyleChange`（文件中**首个**定义）的函数体。
  String pagedReanchorBody() {
    const String marker = 'reanchorAfterStyleChange = function';
    final int start = src.indexOf(marker);
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到分页版 reanchorAfterStyleChange 函数定义');
    final int end = src.indexOf('\n};', start);
    expect(end, greaterThan(start),
        reason: '找不到分页版 reanchorAfterStyleChange 函数体结尾');
    return src.substring(start, end);
  }

  /// 截取连续版 `reanchorAfterStyleChange`（文件中**最后一个**定义，TODO-736 B-2）的函数体。
  String continuousReanchorBody() {
    const String marker = 'reanchorAfterStyleChange = function';
    final int start = src.lastIndexOf(marker);
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到连续版 reanchorAfterStyleChange 函数定义');
    // 同 marker 出现 >=2 次才说明分页+连续两版都在（lastIndexOf 取到的是连续版）。
    expect(src.indexOf(marker), lessThan(start),
        reason: '连续版 reanchorAfterStyleChange 必须独立于分页版存在（两处定义）');
    final int end = src.indexOf('\n};', start);
    expect(end, greaterThan(start),
        reason: '找不到连续版 reanchorAfterStyleChange 函数体结尾');
    return src.substring(start, end);
  }

  group('分页版 reanchorAfterStyleChange（BUG-109）', () {
    test('用精确字符偏移重锚', () {
      final String body = pagedReanchorBody();
      expect(body, contains('getFirstVisibleCharOffset'),
          reason:
              '分页版必须 reflow 前用 getFirstVisibleCharOffset 捕捉首个可见字符（BUG-109）。');
      expect(body, contains('scrollToCharOffset'),
          reason: '分页版必须用 scrollToCharOffset 恢复到该字符真实所在页（BUG-109）。');
    });

    test('不再用粗粒度进度分数', () {
      final String body = pagedReanchorBody();
      expect(body, isNot(contains('scrollToProgressPaged(')),
          reason:
              'scrollToProgressPaged 按 alignToPage 取整到分页边界，字体/主题重排后跳页（BUG-109）。');
      expect(body, isNot(contains('calculateProgress(')),
          reason: 'calculateProgress 返回粗粒度比例，重排后映射到不同页（BUG-109）。');
    });

    test('传 page-stable hint（getPagePosition）抑制微跳', () {
      final String body = pagedReanchorBody();
      expect(body, contains('getPagePosition'),
          reason:
              'reflow 前须记 getPagePosition 作为 scrollToCharOffset 的 hintScroll（±1 列保持原页）。');
    });
  });

  group('连续版 reanchorAfterStyleChange（TODO-736 B-2）', () {
    test('用精确字符偏移重锚', () {
      final String body = continuousReanchorBody();
      expect(body, contains('getFirstVisibleCharOffset'),
          reason: '连续版必须 reflow 前用 getFirstVisibleCharOffset 捕捉首个可见字符，'
              '否则改字号/主题多次后累积偏到章首（TODO-736 B-2）。');
      expect(body, contains('scrollToCharOffset'),
          reason: '连续版必须用 scrollToCharOffset 恢复到该字符真实所在位置（TODO-736 B-2）。');
    });

    test('不再用粗粒度进度分数（calculateProgress → scrollToProgressContinuous）', () {
      final String body = continuousReanchorBody();
      // 查「调用形式」（带括号），注释里作对比说明的提及不算。
      expect(body, isNot(contains('scrollToProgressContinuous(')),
          reason: 'scrollToProgressContinuous 按进度分数反推节点，重排后落点漂移 → 累积偏到章首。'
              '改用 scrollToCharOffset（TODO-736 B-2）。');
      expect(body, isNot(contains('calculateProgress(')),
          reason: 'calculateProgress 返回粗粒度已读比例，重排后映射到不同位置。'
              '改用 getFirstVisibleCharOffset 精确捕捉（TODO-736 B-2）。');
    });

    test('去掉自驱 rAF（settle-aware 重锚改由 Dart 编排驱动 / 非编排回退同步滚回）', () {
      final String body = continuousReanchorBody();
      expect(body, isNot(contains('requestAnimationFrame')),
          reason: '连续版样式重锚已拆掉旧的 rAF+finally 自驱清旗（清太早 → 翻页多次改字号'
              '跳章首的时序根因）。settle-aware 重锚由 Dart beginStyleReanchor/'
              'commitStyleReanchor + runUiScaleReanchorOrchestration 驱动；本入口仅作'
              '不可编排时的同步回退（TODO-736 B-1）。');
    });
  });

  group('样式专用两阶段重锚入口（TODO-736 B-1）', () {
    test('_sharedJs 定义 beginStyleReanchor / commitStyleReanchor（两 shell 共用）',
        () {
      expect(src, contains('beginStyleReanchor: function'),
          reason: 'beginStyleReanchor 必须在 _sharedJs 定义（分页/连续两 shell 共用，'
              'getFirstVisibleCharOffset/scrollToCharOffset 经 this 解析各自版本）。');
      expect(src, contains('commitStyleReanchor: function'),
          reason: 'commitStyleReanchor 必须在 _sharedJs 定义（settle 后滚回 + 清旗）。');
    });

    test('beginStyleReanchor 同步换 CSS + 采锚 + 置旗，不自驱 rAF', () {
      const String marker = 'beginStyleReanchor: function';
      final int start = src.indexOf(marker);
      expect(start, greaterThanOrEqualTo(0));
      // 截到下一个属性 `commitStyleReanchor:` 之前。
      final int end = src.indexOf('commitStyleReanchor: function', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('getFirstVisibleCharOffset'),
          reason: 'beginStyleReanchor 必须同步采精确锚。');
      expect(body, contains('_reanchorPending = true'),
          reason:
              'beginStyleReanchor 必须置 _reanchorPending（挡住 reflow 归零 scroll 污染落库）。');
      expect(body, isNot(contains('requestAnimationFrame')),
          reason: 'beginStyleReanchor 不得自驱 rAF——清旗/滚回推迟到 Dart 编排的 commit。');
    });

    test('commitStyleReanchor 只在自身拥有锚时清旗（finally 不误清别处）', () {
      const String marker = 'commitStyleReanchor: function';
      final int start = src.indexOf(marker);
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('_styleReanchorOffset'),
          reason:
              'commitStyleReanchor 必须读 beginStyleReanchor 暂存的 _styleReanchorOffset。');
      expect(body, contains('scrollToCharOffset'),
          reason: 'commitStyleReanchor 必须用 scrollToCharOffset 滚回。');
      expect(body, contains('_reanchorPending = false'),
          reason: 'commitStyleReanchor 必须在 finally 清 _reanchorPending。');
    });
  });
}
