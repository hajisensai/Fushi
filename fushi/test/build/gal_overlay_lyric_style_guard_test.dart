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

  test('① 描边/投影是同一 text_layout_ 的偏移多遍绘制', () {
    expect(
      window.contains('kLyricOutlineRadiusDip'),
      isTrue,
      reason: '描边半径常量必须存在，否则桌面歌词渲染根本没接上',
    );
    expect(
      window.contains('kLyricShadowOffsetDip'),
      isTrue,
      reason: '投影偏移常量必须存在',
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

  test('② 描边只在「hook 模式 × 近透明底板」生效，其余浮窗逐像素不变', () {
    // fx 判据必须以 hook_text_mode_ 为第一门（歌词条 / 剪贴板窗永远进不来），
    // 第二门是底板 alpha（白卡模式深字无描边）+ 穿透强制清底。
    expect(
      RegExp(r'lyric_text_fx =\s*hook_text_mode_ &&\s*'
              r'\(pass_through_ \|\| \(style_\.bg_color >> 24\) < '
              r'kLyricTextFxBgAlphaMax\)')
          .hasMatch(window),
      isTrue,
      reason: '描边开关必须是 hook 模式 && (穿透 || 底板近透明)；'
          '任何一门被拆掉，白卡会脏描边或歌词条被改观感',
    );
    // 主文本门与注音门分别锁：两处同形门若只锁其一，另一处被拆掉时守卫不响。
    expect(
      RegExp(r'if \(lyric_text_fx && lyric_outline != nullptr &&\s*'
              r'lyric_shadow != nullptr\)')
          .hasMatch(window),
      isTrue,
      reason: '主文本描边/投影遍必须被 lyric_text_fx 门住',
    );
    expect(
      RegExp(r'if \(lyric_text_fx && lyric_outline != nullptr\) \{')
          .hasMatch(window),
      isTrue,
      reason: '注音描边遍必须被 lyric_text_fx 门住',
    );
    expect(
      RegExp(r'hook_text_mode_\s*\?\s*DWRITE_FONT_WEIGHT_SEMI_BOLD'
              r'\s*:\s*DWRITE_FONT_WEIGHT_NORMAL')
          .hasMatch(window),
      isTrue,
      reason: '半粗字重同样只允许在 hook 模式启用',
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

  test('④ Dart 两态调色板：白卡默认非零、◐ 恢复值非零、透明态白字', () {
    final RegExp def = RegExp(r'_defaultOpacity = (\d+(?:\.\d+)?);');
    final Match? dm = def.firstMatch(controller);
    expect(dm, isNotNull, reason: '默认底板常量必须存在');
    expect(
      double.parse(dm!.group(1)!),
      greaterThan(0),
      reason: '默认是白色磨砂卡（参考桌面翻译器浅色浮窗），不是透明',
    );
    final RegExp restore = RegExp(r'_defaultRestoreOpacity = (\d+(?:\.\d+)?);');
    final Match? m = restore.firstMatch(controller);
    expect(m, isNotNull, reason: '◐ 的恢复常量必须存在');
    expect(
      double.parse(m!.group(1)!),
      greaterThan(0),
      reason: '恢复值为 0 会让 ◐ 在 0 ↔ 0 之间空转',
    );
    // 两态文字色必须跟着底板走：白卡深字 / 透明白字。任何一半被写死，另一态
    // 就是白字白底或黑字黑底。
    expect(
      RegExp(r'_textColor => _isCardMode \? 0xFF[0-9A-Fa-f]{6} : 0xFFFFFFFF')
          .hasMatch(controller),
      isTrue,
      reason: '文字颜色必须按 _isCardMode 分派：卡片深字、透明白字',
    );
  });

  test('⑤ 工具条悬停提示：文案条数 == 槽位数，两个工具条窗共用一张表', () {
    final String toolbarHeader =
        File('windows/runner/hook_toolbar_window.h').readAsStringSync();
    final String toolbarImpl =
        File('windows/runner/hook_toolbar_window.cpp').readAsStringSync();
    final RegExp slotCount = RegExp(r'constexpr int kSlotCount = (\d+);');
    final Match? sc = slotCount.firstMatch(toolbarHeader);
    expect(sc, isNotNull, reason: '共享槽位表必须存在');
    final int slots = int.parse(sc!.group(1)!);
    // Dart 下发的文案条数必须与槽位数一致——差一条就是「按错位的提示」，比
    // 没有提示更糟。
    expect(
      RegExp(r't\.game_hook_btn_\w+').allMatches(controller).length,
      slots,
      reason: '控制器 _slotTooltips 的条数必须等于 native kSlotCount（$slots）',
    );
    // 两个工具条窗都必须从共享表取词并真的接了悬停事件。
    expect(
      toolbarHeader.contains('void SetSlotTooltips('),
      isTrue,
      reason: '共享文案入口必须在 hook_toolbar 命名空间（单一真相）',
    );
    for (final (String file, String src) in <(String, String)>[
      ('floating_lyric_window.cpp', window),
      ('hook_toolbar_window.cpp', toolbarImpl),
    ]) {
      expect(
        RegExp(r'(slot_)?tooltip_\.Update\(hwnd_, slot').hasMatch(src),
        isTrue,
        reason: '$file 的鼠标移动路径必须驱动槽位提示（两窗不许只接一半）',
      );
    }
  });
}
