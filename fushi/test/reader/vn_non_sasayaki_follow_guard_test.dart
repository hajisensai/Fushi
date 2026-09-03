import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1742 接线守卫：VN 模式下**非 sasayaki 书**的有声书自动跟随。
///
/// 分叉在 [AudiobookBridge.highlight]：cue 的 textFragmentId 能被
/// `SubtitleRematchCodec` 解码（sasayaki）时走 `window.fushiReader` 的方法调用，
/// VN 实现了它、一切正常；否则（纯 SRT/VTT/LRC 合成书，textFragmentId 是
/// `[data-cue-id="N"]` 这样的裸 CSS 选择器）走 `__fushiHighlight`，而后者用
/// `document.querySelector` 找元素。
///
/// VN 的 `detachChapterSource` 把整章正文搬进一个游离的 div，document 里任一时刻
/// 只剩当前一屏的克隆——目标 cue 只要不在当前屏，querySelector 就返回 null 并
/// **静默早退**，跟随永远不会翻到目标屏。即便恰好在当前屏，后续的
/// `__fushiRevealTarget` 也只能落到 `scrollIntoView`，而 VN stage 是定屏无滚动。
///
/// 所以这条路径必须优先走 VN 的 `highlightSelectorCue`（选择器 → 字符偏移 →
/// 翻屏），分页/连续模式没有该方法、自动回落原路径。
///
/// headless 无真 InAppWebView，逐句翻屏须真机复验；本守卫只锁接线不变量。
void main() {
  final String source =
      File('lib/src/media/audiobook/audiobook_bridge.dart').readAsStringSync();

  final int start = source.indexOf('  static Future<void> highlight(');
  final int end =
      source.indexOf('  static Future<void> resetImagePauseAnchor(');

  test('方法边界可定位（防守卫因重命名失效）', () {
    expect(start, greaterThanOrEqualTo(0),
        reason: 'AudiobookBridge.highlight 丢失');
    expect(end, greaterThan(start));
  });

  final String body = source.substring(start, end);

  test('非 sasayaki 分支优先走 VN 的 highlightSelectorCue', () {
    expect(
      body.contains('window.fushiReader.highlightSelectorCue'),
      isTrue,
      reason: '非 sasayaki cue 未接 VN 原语 —— VN 下自动跟随会静默失效',
    );
    expect(
      body.contains(
          'typeof window.fushiReader.highlightSelectorCue==="function"'),
      isTrue,
      reason: '必须带存在性判定，否则分页/连续模式会抛 TypeError',
    );
  });

  test('分页/连续模式仍回落 __fushiHighlight（行为零变化）', () {
    expect(
      body.contains('__fushiHighlight('),
      isTrue,
      reason: '丢了 __fushiHighlight 回落，分页/连续模式的跟随会一起坏掉',
    );
    final int vnCall = body.indexOf('highlightSelectorCue(');
    final int fallback = body.indexOf('}else if(typeof __fushiHighlight');
    expect(fallback, greaterThan(vnCall),
        reason: 'VN 原语必须在前、__fushiHighlight 作为 else 回落');
  });

  test('清除高亮仍走原路径（VN 侧无需特例）', () {
    expect(
      body.contains('__fushiHighlight("")'),
      isTrue,
      reason: 'cue==null 的清除路径不应被本次改动波及',
    );
  });
}
