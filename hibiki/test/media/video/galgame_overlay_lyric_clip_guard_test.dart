import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1070 接线守卫：galgame hook 台词浮窗（Windows 原生 Direct2D，
/// `floating_lyric_window.cpp`）的台词文本垂直居中且无裁剪，多行溢出时顶部行会挤进顶部
/// 控制条按钮带（[kControlsTopDip, +kButtonSizeDip]）两侧无按钮处透显、把 UI 盖住。
///
/// 修复：给台词绘制（highlight 填充 + DrawTextLayout）加 PushAxisAlignedClip 到 text_rect_，
/// 使台词像素严格画在 y ≥ controls_h（控制带下沿）以下；Pop 必须在工具条/控制带绘制前，
/// 按钮不被裁剪。
///
/// 原生无 Dart 单测宿主，用源码扫描守卫盯死裁剪成对包裹台词绘制不回归（native 编译验证
/// 走 Windows 真机）。
void main() {
  final String src =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();

  test('台词绘制被 PushAxisAlignedClip(text_rect_) 裁剪、且成对 Pop', () {
    expect(src, contains('PushAxisAlignedClip'),
        reason: '台词绘制前必须压入裁剪');
    expect(src, contains('PopAxisAlignedClip'), reason: '必须成对弹出裁剪');
    // 裁剪矩形必须由 text_rect_ 构成（top==controls_h 即控制带下沿）。
    final String flat = src.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      flat,
      contains('D2D1::RectF( text_rect_.left, text_rect_.top,'),
      reason: '裁剪矩形须取 text_rect_（其 top 即控制带下沿 controls_h）',
    );
  });

  test('裁剪 Push 在台词绘制前、Pop 在 DrawTextLayout 后', () {
    // 用 `->` 调用形匹配真实调用点，避开注释里提到的 DrawTextLayout（BUG-1070 注释）。
    final int pushIdx = src.indexOf('->PushAxisAlignedClip(');
    final int drawIdx = src.indexOf('->DrawTextLayout(');
    final int popIdx = src.indexOf('->PopAxisAlignedClip(');
    expect(pushIdx, greaterThanOrEqualTo(0));
    expect(drawIdx, greaterThan(pushIdx),
        reason: 'Push 必须在 DrawTextLayout 之前，台词才被裁剪');
    expect(popIdx, greaterThan(drawIdx),
        reason: 'Pop 必须在 DrawTextLayout 之后（且在控制带/工具条绘制前），按钮不被裁剪');
  });
}
