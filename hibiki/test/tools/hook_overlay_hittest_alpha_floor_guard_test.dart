// BUG-1046 源码守卫：Hook 文本浮窗隐藏背景后必须仍可点词。
//
// 浮窗是 UpdateLayeredWindow 逐像素 alpha 的分层窗口，Windows 对它按像素 alpha
// 做命中测试——alpha 0 的像素点击直接穿透，WM_NCHITTEST 说什么都没用。修复是在
// native Render() 里给 hook 文本模式（且未开点击穿透）的主体背景钳一个近不可见的
// alpha 下限。native C++ 无法在 Dart 测试里执行，此守卫锁定源码接线不被退化：
//   ① 下限常量存在且非 0；
//   ② 主体背景填充路径存在按 hook_text_mode_ && !pass_through_ 的钳制分支；
//   ③ 钳制结果（body_bg）真的被用于背景刷子，而不是钳完扔掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String src =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();

  test('① alpha 下限常量存在且非 0（BUG-1046）', () {
    final RegExp constant =
        RegExp(r'constexpr\s+uint32_t\s+kHookTextMinCatchAlpha\s*=\s*(\d+)');
    final RegExpMatch? m = constant.firstMatch(src);
    expect(m, isNotNull, reason: 'kHookTextMinCatchAlpha 常量不得被移除（隐藏背景时的可点击底线）');
    expect(int.parse(m!.group(1)!), greaterThan(0),
        reason: '下限为 0 等于没修：alpha 0 像素会被分层窗口命中测试穿透');
  });

  test('② 钳制分支绑定 hook_text_mode_ && !pass_through_', () {
    expect(
      src.contains('hook_text_mode_ && !pass_through_ &&'),
      isTrue,
      reason: '钳制必须只在「hook 文本模式且未开穿透」生效：'
          '开穿透时保持真 alpha 0（点击本就该穿到游戏）',
    );
    expect(
      src.contains(
          'body_bg = (kHookTextMinCatchAlpha << 24) | (body_bg & 0x00FFFFFF);'),
      isTrue,
      reason: '主体背景 alpha 钳制表达式不得被移除',
    );
  });

  test('③ 钳制结果真的用于背景填充刷子', () {
    expect(
      src.contains('CreateSolidColorBrush(ColorFromArgb(body_bg)'),
      isTrue,
      reason: '背景刷子必须用钳制后的 body_bg（而非原始 style_.bg_color）',
    );
  });
}
