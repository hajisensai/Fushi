import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3388：悬浮字幕多句时，上下文行的 per-range 降亮画刷（`SetDrawingEffect`）
/// 曾在描边 / 投影遍之前就挂在 layout 上——drawing effect 会盖掉 DrawTextLayout
/// 传入的画刷，于是上下文行的描边被画成降亮的字色、与字形糊成一团。并且 layout
/// 跨帧复用，上一帧挂的效果会一直留着。
///
/// 修法的两个不变式（native 渲染无单测装置，只能钉源码顺序）：
///   ① 描边遍之前先把整段 layout 的 drawing effect 清空；
///   ② 降亮 / 当前句画刷只在最后那一遍填充 DrawTextLayout 之前挂上。
void main() {
  final String src = File(
    'windows/runner/floating_lyric_window.cpp',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  final int render = src.indexOf('void FloatingLyricWindow::Render()');
  final String body = src.substring(render);

  test('描边遍之前清空 layout 上残留的 drawing effect', () {
    final int clear = body.indexOf(RegExp(r'SetDrawingEffect\(\s*nullptr,'));
    final int outline = body.indexOf('for (const D2D1_POINT_2F& off : ring)');
    expect(clear, greaterThan(0), reason: '必须先 SetDrawingEffect(nullptr, 全段)');
    expect(outline, greaterThan(0));
    expect(clear, lessThan(outline));
  });

  test('降亮画刷只在填充遍之前挂上，且挂在描边遍之后', () {
    final int outline = body.indexOf('for (const D2D1_POINT_2F& off : ring)');
    final int apply = body.indexOf('apply_line_effects();');
    expect(apply, greaterThan(outline), reason: '效果必须在描边遍画完之后才挂');
    final String afterApply = body.substring(apply);
    expect(
      RegExp(
        r'^apply_line_effects\(\);\s*render_target_->DrawTextLayout\(',
      ).hasMatch(afterApply),
      isTrue,
      reason: '挂效果后紧接的必须是填充遍 DrawTextLayout',
    );
  });

  test('多句跟随：换句开启跟随，手动滚轮 / 拖滚动条后停止', () {
    expect(
      src.contains(
        'follow_current_line_ = current_line_start >= 0 && current_line_length > 0;',
      ),
      isTrue,
    );
    final int wheel = src.indexOf('case WM_MOUSEWHEEL: {');
    final String wheelBlock = src.substring(
      wheel,
      src.indexOf('case WM_SIZE:', wheel),
    );
    expect(wheelBlock.contains('follow_current_line_ = false;'), isTrue);
  });
}
