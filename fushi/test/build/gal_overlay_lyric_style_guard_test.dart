// 源码守卫：gal hook 台词浮窗的「桌面歌词式」文字渲染（描边 + 投影 + 透明底板）。
//
// 浮窗是 runner 自有的 Win32 分层窗（Direct2D + DirectWrite 直绘），C++ 无法在
// Dart 测试里执行，故在源码层锁死这次重写赖以成立的结构性前提：
//   ① 描边/投影遍复用**同一个** text_layout_ 做偏移多遍绘制——不是自定义
//      IDWriteTextRenderer、不是第二份排版。一旦分叉，CharIndexAt 点字 index、
//      折行、滚动、注音四处几何就会各走各的（overlay_ruby_render_guard_test 已
//      禁 IDWriteTextRenderer，这里锁「多遍偏移」这条正路本身）。
//   ② 描边只在 hook 模式生效：有声书歌词条 / 剪贴板文字窗逐像素不变
//      （never break userspace）。
//   ③ 最终填充遍仍是滚动守卫锚定的那次原点绘制（text_rect_.left, text_origin_y）。
//   ④ Dart 侧默认背景全透明（可读性由描边承担），且 ◐ 一键底板的恢复值非零
//      ——否则 toggle 会在 0 ↔ 0 之间死循环。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String window =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
  final String controller =
      File('lib/src/lookup/gal_hook_text_overlay_controller.dart')
          .readAsStringSync();
  final String prefs =
      File('lib/src/models/preferences_repository.dart').readAsStringSync();
  final String windowHeader =
      File('windows/runner/floating_lyric_window.h').readAsStringSync();

  test('① 描边/投影是同一 text_layout_ 的偏移多遍绘制', () {
    // 描边半径从固定常量 kLyricOutlineRadiusDip 改成了用户可配的 style_.outline_width，
    // 所以这里不再钉常量名，而是钉「半径来自 style_ 且被夹在合法区间」——常量名没了不等于
    // 渲染没接上，但取值不夹区间就是能把描边拉到吃掉整块文字。
    expect(
      window.contains('std::clamp(style_.outline_width, 0.0, 8.0)'),
      isTrue,
      reason: '描边半径必须取自 style_.outline_width 并夹在 [0,8]',
    );
    expect(
      window.contains('kLyricShadowOffsetDip'),
      isTrue,
      reason: '投影偏移常量必须存在',
    );
    // 可配置化不得顺手改观感：默认值必须逐位等于改造前的硬编码值，否则所有没动过
    // 这个设置的用户会在一次升级后发现描边变了，而 diff 里看不出任何「观感改动」。
    expect(
      prefs.contains('galHookTextOutlineWidthDefault = 1.6'),
      isTrue,
      reason: '描边默认值必须等于原 kLyricOutlineRadiusDip = 1.6f',
    );
    expect(
      windowHeader.contains('bool bold = true;'),
      isTrue,
      reason: '半粗默认必须为真：改造前 hook 模式无条件半粗',
    );
    // 描边环必须把 text_layout_ 自己再画一遍（同一几何），而不是另建排版。
    expect(
      RegExp(r'for \(const D2D1_POINT_2F& off : ring\)[\s\S]{0,300}?'
              r'text_layout_\.Get\(\), lyric_outline\.Get\(\)')
          .hasMatch(window),
      isTrue,
      reason: '描边遍必须复用 text_layout_（与点字/滚动/高亮同一份几何）',
    );
  });

  test('② 描边只在 hook 模式生效，其余浮窗逐像素不变', () {
    // 主文本门与注音门分别锁：两处同形门若只锁其一，另一处被拆掉时守卫不响。
    expect(
      RegExp(r'if \(hook_text_mode_ && lyric_outline != nullptr &&\s*'
              r'lyric_shadow != nullptr\)')
          .hasMatch(window),
      isTrue,
      reason: '主文本描边/投影遍必须被 hook_text_mode_ 门住；'
          '歌词条 / 剪贴板窗不许被改观感',
    );
    expect(
      RegExp(r'if \(hook_text_mode_ && lyric_outline != nullptr\) \{')
          .hasMatch(window),
      isTrue,
      reason: '注音描边遍必须被 hook_text_mode_ 门住',
    );
    expect(
      RegExp(r'hook_text_mode_ && style_\.bold\s*\?\s*'
              r'DWRITE_FONT_WEIGHT_SEMI_BOLD'
              r'\s*:\s*DWRITE_FONT_WEIGHT_NORMAL')
          .hasMatch(window),
      isTrue,
      reason: '半粗字重同样只允许在 hook 模式启用（现在还叠一个用户开关，'
          '但 hook_text_mode_ 这一层门不能被去掉——去掉就会改到歌词条/剪贴板窗）',
    );
  });

  test('③ 最终填充遍仍是原点那次绘制（滚动守卫的锚点）', () {
    expect(
      RegExp(r'D2D1::Point2F\(text_rect_\.left, text_origin_y\), '
              r'text_layout_\.Get\(\),\s*brush\.Get\(\)')
          .hasMatch(window),
      isTrue,
      reason: '填充遍必须保持在 (text_rect_.left, text_origin_y) 原点、用正文画刷',
    );
  });

  test('④ Dart 默认底板全透明，◐ 恢复值非零', () {
    expect(
      controller.contains('_defaultOpacity = 0.0'),
      isTrue,
      reason: '桌面歌词式默认无底板；可读性由 native 描边承担',
    );
    final RegExp restore = RegExp(r'_defaultRestoreOpacity = (\d+(?:\.\d+)?);');
    final Match? m = restore.firstMatch(controller);
    expect(m, isNotNull, reason: '◐ 的恢复常量必须存在');
    expect(
      double.parse(m!.group(1)!),
      greaterThan(0),
      reason: '恢复值为 0 会让 ◐ 在 0 ↔ 0 之间空转',
    );
  });
}
