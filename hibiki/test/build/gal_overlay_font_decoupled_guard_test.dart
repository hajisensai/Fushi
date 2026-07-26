// BUG-1095 源码守卫：galgame Hook 台词浮窗的字号必须与窗口高度解耦。
//
// 浮窗不是 Flutter widget，是 runner 自有的 Win32 分层窗（Direct2D/DirectWrite 直绘），
// C++ 无法在 Dart 测试里执行，故在源码层锁死修复结构：
//   ① hook 模式不再按窗高缩放字号（三个缩放常量必须消失）；
//   ② hook 分支的缩放系数恒为 1.0f，即直接用 style_.font_size；
//   ③ 有声书歌词条的历史行为（按窗高缩放）不得被顺手砍掉；
//   ④ 溢出时 hook 台词顶端对齐（保住阅读起点）。
//
// 注：第一阶段写的“溢出仍是硬裁”已经过时——第二阶段给这个浮窗加了真正的
// 垂直滚动（滚轮 + 指示条），句尾不再永久丢失，见
// hibiki/test/build/gal_overlay_scroll_guard_test.dart。顶端对齐从“止损”变成了
// 滚动能成立的前提：排版必须从 text_rect_.top 起画，滚动才等于平移绘制原点。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String src =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();

  test('① 按窗高缩放 hook 字号的三个常量必须消失（BUG-1095）', () {
    for (final String name in <String>[
      'kHookTextBaseHeightForFontDip',
      'kHookTextFontScaleMin',
      'kHookTextFontScaleMax',
    ]) {
      expect(
        src.contains(name),
        isFalse,
        reason: '$name 是「拖高浮窗 = 放大台词」的耦合来源；'
            '它一旦回来，用户「放不下想拖高」就又拖不出更多行了',
      );
    }
  });

  test('② hook 分支的高度缩放系数恒为 1.0f', () {
    expect(
      src.contains('hook_text_mode_ ? 1.0f'),
      isTrue,
      reason: 'hook 模式必须直接用 style_.font_size（真值来自 gal_hook_text_font_size '
          '偏好），不得再从 strip_height_dip_ 推导字号',
    );
    // 缩放仍旧只作用在 style_.font_size 上（没有把整支字号逻辑删掉）。
    expect(
      src.contains(
          'const float scaled_font = static_cast<float>(style_.font_size) *'),
      isTrue,
      reason: '字号仍必须以 style_.font_size 为基准（channel 送来的用户偏好值）',
    );
  });

  test('③ 有声书歌词条保持按窗高缩放（never break userspace）', () {
    expect(
      src.contains('strip_height_dip_ / kBaseStripHeightForFontDip'),
      isTrue,
      reason: '本次修复只解耦 hook 模式；歌词条「拖高放大」是既有行为，不得连坐',
    );
  });

  test('④ hook 台词溢出时顶端对齐，装得下仍居中', () {
    expect(
      src.contains('DWRITE_PARAGRAPH_ALIGNMENT_NEAR'),
      isTrue,
      reason: '顶端对齐是滚动的前提（排版从 text_rect_.top 起画，滚动 = 平移绘制原点）；'
          '改回居中会让滚动偏移与实际排版对不上，且未滚动时头尾一起被裁',
    );
    expect(
      src.contains('metrics.height > text_rect_.height'),
      isTrue,
      reason: '顶端对齐必须由「实测排版高度超出文本区」触发，而不是无条件改对齐',
    );
  });
}
