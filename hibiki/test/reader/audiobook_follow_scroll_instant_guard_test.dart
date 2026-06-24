import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-803：连续/滚动模式有声书逐句高亮跟随滚动，「画面移动结束时闪一下屏幕」。
///
/// 真因：连续模式 cue reveal 走 `hoshiReader.scrollToTarget`（位于
/// `_continuousShellScript`），它用 `window.scrollBy({behavior:'smooth'})` 做平滑滚动。
/// smooth 动画跨多帧逐帧派发 scroll 事件，每帧经 onReaderScroll 回弹回 Dart 触发
/// `_refreshProgress`；而 cue reveal 这条程序化滚动**不武装 B-3 / `_reanchorPending`**
/// （那三道归零保护只武装 restore / uiScale / style 三条 reanchor commit），不受 250ms
/// settle 窗保护 → 动画落定那一发 setState 重绘，且可能命中 TODO-798 非自愿归零判据被
/// 反手复位二次滚动，视觉上「停下 → 被拽回」= 闪屏；另 smooth 在快速句子切换/快进时还会
/// 排队堆积导致视口抖动（历史 commit d6b99b95c 已因此从 smooth 改 instant，f2c984b3b 又
/// 为「拉回动画」改回，是回归）。
///
/// 根因修复：连续模式 reveal 滚动改用 `behavior:'instant'`（与分页模式 reveal 一直用的
/// instant `scrollToRange` 对齐——分页一直不闪）。本守卫锁住修复点：连续 shell 的
/// `scrollToTarget` 只能用 instant，禁止 smooth。
void main() {
  final String src = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  /// 取 `_continuousShellScript` 函数体（连续模式那份 hoshiReader），避免误把分页 shell
  /// 的滚动函数当成命中。从签名起到下一个 `static String` 顶层声明之间。
  String continuousShellBody() {
    final int start = src.indexOf('static String _continuousShellScript(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 _continuousShellScript 定义');
    final int next = src.indexOf('\n  static ', start + 1);
    final int end = next >= 0 ? next : src.length;
    return src.substring(start, end);
  }

  group('TODO-803 连续模式有声书跟随滚动必须 instant（禁 smooth，防闪屏回归）', () {
    test('连续 shell 的 scrollToTarget 不得使用 behavior:smooth', () {
      final String body = continuousShellBody();
      final int fnIdx = body.indexOf('scrollToTarget: function(target)');
      expect(fnIdx, greaterThanOrEqualTo(0),
          reason: '连续 shell 必须有 scrollToTarget（有声书 cue reveal 跟随滚动原语）');
      expect(
        RegExp(r"behavior:\s*'smooth'").hasMatch(body),
        isFalse,
        reason: 'smooth 平滑滚动是「滚动结束闪一下屏幕」的根因（多帧 scroll 回弹 + 动画'
            '落定重绘/非自愿归零复位二次滚动）；连续模式 reveal 必须 instant',
      );
    });

    test('连续 shell 的 scrollToTarget 三条滚动分支均为 behavior:instant', () {
      final String body = continuousShellBody();
      final int hits = RegExp(r"behavior:\s*'instant'").allMatches(body).length;
      expect(
        hits,
        greaterThanOrEqualTo(3),
        reason: 'scrollToTarget 竖排 rl / 竖排 lr / 横排三条 scrollBy 都必须 instant',
      );
    });
  });
}
