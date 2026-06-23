import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-109 / TODO-736 回归守卫（源码扫描，沿用 `reader_live_settings_guard_test.dart` 的
/// `File(...).readAsStringSync()` + `contains` 模式）。
///
/// 现象：在阅读器里切换主题 / 字体 / 字号时，正文会「翻页」乃至多次后弹回章首。
///
/// 根因 & 修复：切字号 / 字体 / 主题 live 变更最终进 `_applyStylesLive` → Dart 两阶段
/// 编排 `beginStyleReanchor` / `commitStyleReanchor`（`runUiScaleReanchorOrchestration`
/// 驱动）。重锚必须用**精确字符偏移**（reflow 前 `getFirstVisibleCharOffset()` 记下首个
/// 可见字符，换样式后 `scrollToCharOffset(...)` 落到该字符真实所在页/位置），对齐
/// `setChromeInsets` 已验证的成熟路径，而非粗粒度进度分数（`calculateProgress` →
/// `scrollToProgress*` 反推节点 + 取整落相邻页 → 改字号/主题多次后累积偏到章首）。
///
/// 历史：旧的单函数 `reanchorAfterStyleChange`（分页版 BUG-109 + 连续版 TODO-736 B-2）曾
/// 是非编排的 rAF-finally 自驱重锚——清旗太早（reflow 未 settle）让 120ms 尾沿 scroll
/// 把归零瞬态当真滚动落库，是「翻页多次改字号跳章首」的时序根因。TODO-736 B-1 已把它
/// 整体替换为下面的 begin/commit 两阶段 settle-aware 编排（清旗推迟到 Dart postFrame
/// settle），旧的两个 `reanchorAfterStyleChange` 定义已作死代码删除（全仓零调用者）。
/// 字符精度 + settle-aware 的守护全部转嫁到本文件守的 begin/commit 入口。
///
/// 谁把 begin/commit 退回粗粒度重锚（`calculateProgress` / `scrollToProgress*`）或重新
/// 自驱 rAF 清旗，本测试红。
void main() {
  final String src = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  group('样式专用两阶段重锚入口（TODO-736 B-1，取代旧 reanchorAfterStyleChange）', () {
    test('旧单函数 reanchorAfterStyleChange 已删（死代码，零调用者）', () {
      expect(src, isNot(contains('reanchorAfterStyleChange = function')),
          reason: '旧 rAF-finally 自驱重锚已被 begin/commit 两阶段编排取代并删除；'
              '若它复活说明有人退回了非 settle-aware 的旧路径（翻页改字号跳章首根因）。');
    });

    test('_sharedJs 定义 beginStyleReanchor / commitStyleReanchor（两 shell 共用）',
        () {
      expect(src, contains('beginStyleReanchor: function'),
          reason: 'beginStyleReanchor 必须在 _sharedJs 定义（分页/连续两 shell 共用，'
              'getFirstVisibleCharOffset/scrollToCharOffset 经 this 解析各自版本）。');
      expect(src, contains('commitStyleReanchor: function'),
          reason: 'commitStyleReanchor 必须在 _sharedJs 定义（settle 后滚回 + 清旗）。');
    });

    test('beginStyleReanchor 同步换 CSS + 采精确锚 + 置旗，不自驱 rAF', () {
      const String marker = 'beginStyleReanchor: function';
      final int start = src.indexOf(marker);
      expect(start, greaterThanOrEqualTo(0));
      // 截到下一个属性 `commitStyleReanchor:` 之前。
      final int end = src.indexOf('commitStyleReanchor: function', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('getFirstVisibleCharOffset'),
          reason: 'beginStyleReanchor 必须同步采精确锚（BUG-109 / TODO-736 B-2）。');
      expect(body, isNot(contains('scrollToProgressPaged(')),
          reason: '不得退回粗粒度分页分数（BUG-109）。');
      expect(body, isNot(contains('scrollToProgressContinuous(')),
          reason: '不得退回粗粒度连续分数（TODO-736 B-2）。');
      expect(body, isNot(contains('calculateProgress(')),
          reason: 'calculateProgress 返回粗粒度比例，重排后映射到不同页（BUG-109）。');
      expect(body, contains('getPagePosition'),
          reason: 'reflow 前须记 getPagePosition 作 scrollToCharOffset 的 hintScroll'
              '（分页 ±1 列保持原页；连续 mode 经 typeof 守卫自然 undefined）。');
      expect(body, contains('_reanchorPending = true'),
          reason:
              'beginStyleReanchor 必须置 _reanchorPending（挡住 reflow 归零 scroll 污染落库）。');
      expect(body, isNot(contains('requestAnimationFrame')),
          reason: 'beginStyleReanchor 不得自驱 rAF——清旗/滚回推迟到 Dart 编排的 commit。');
    });

    test('commitStyleReanchor 用 scrollToCharOffset 滚回 + finally 只清自身旗', () {
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
          reason:
              'commitStyleReanchor 必须用 scrollToCharOffset 滚回（精确锚，BUG-109）。');
      expect(body, isNot(contains('scrollToProgressContinuous(')),
          reason: '不得退回粗粒度连续分数（TODO-736 B-2）。');
      expect(body, isNot(contains('scrollToProgressPaged(')),
          reason: '不得退回粗粒度分页分数（BUG-109）。');
      expect(body, contains('_reanchorPending = false'),
          reason: 'commitStyleReanchor 必须在 finally 清 _reanchorPending。');
    });
  });
}
