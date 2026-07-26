// BUG-1095（第二阶段）源码守卫：galgame Hook 台词浮窗**装不下时必须能滚**。
//
// 第一阶段（字号与窗高解耦）之后，字号调大 + 窗口不够高仍会把句尾硬裁掉，用户
// 看不到被裁的内容。这个浮窗是 runner 自有的 Win32 分层窗（Direct2D/DirectWrite
// 直绘），既不是 Flutter widget 也没有系统滚动条，C++ 无法在 Dart 测试里执行，
// 故在源码层锁死修复结构：
//   ① 滚动状态存在，且每帧由实测排版高度重算行程；
//   ② 绘制原点随偏移上移（滚动的实现方式），裁剪框不动；
//   ③ 命中测试在视口判边界、在布局取坐标（滚动后点字不错行）；
//   ④ 新台词回到顶部；
//   ⑤ 接管条件（hook 模式 / 非穿透 / 有溢出）集中在 ScrollBy，滚到头不吞事件；
//   ⑥ 滚动条画在文本区右侧留白里，且只在 hook 模式真溢出时画；
//   ⑦ 不滚动时逐像素不变（歌词条 / 剪贴板文本窗完全不受影响）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String src =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
  final String hdr =
      File('windows/runner/floating_lyric_window.h').readAsStringSync();

  test('① 滚动状态存在，行程由实测排版高度每帧重算（BUG-1095）', () {
    expect(hdr.contains('float scroll_offset_px_ = 0.0f;'), isTrue,
        reason: '滚动偏移必须是窗口自己的状态');
    expect(hdr.contains('float scroll_max_px_ = 0.0f;'), isTrue,
        reason: '可滚行程必须是窗口自己的状态');
    expect(hdr.contains('bool ScrollBy(float delta_px);'), isTrue,
        reason: 'ScrollBy 是唯一的滚动入口');
    expect(
      src.contains(
          'scroll_max_px_ = std::max(0.0f, metrics.height - text_rect_.height);'),
      isTrue,
      reason: '行程 = 实测排版高度 - 文本区高度；写死常量或按行数估算都会在换字号 / '
          '换窗高之后失准',
    );
    // 每帧先归零再重算：字号、窗高、文本任一变化都不会把旧行程留下来
    // （另一处归零在 UpdateText 里）。
    expect(
      'scroll_max_px_ = 0.0f;'.allMatches(src).length >= 2,
      isTrue,
      reason: '每帧必须从零重算行程，UpdateText 也要一起归零',
    );
    expect(
      src.contains(
          'scroll_offset_px_ = std::clamp(scroll_offset_px_, 0.0f, scroll_max_px_);'),
      isTrue,
      reason: '行程变小（拖高窗口 / 调小字号）后偏移必须重新夹紧，否则会卡在空白处',
    );
  });

  test('② 滚动 = 绘制原点上移，裁剪框不动', () {
    expect(
      src.contains(
          'const float text_origin_y = text_rect_.top - scroll_offset_px_;'),
      isTrue,
      reason: '分层窗没有第二个渲染目标，滚动只能靠移动绘制原点',
    );
    expect(
      src.contains('D2D1::Point2F(text_rect_.left, text_origin_y)'),
      isTrue,
      reason: '正文必须按滚动后的原点画',
    );
    expect(
      src.contains(
          'D2D1::RectF(text_rect_.left + m.left, text_origin_y + m.top,'),
      isTrue,
      reason: '高亮底框必须跟着一起滚，否则滚动后高亮会留在原地',
    );
    // 裁剪框仍以 text_rect_ 为准（BUG-1070 的成果不得被顺手改掉）。
    expect(
      src.contains('render_target_->PushAxisAlignedClip(text_clip,'),
      isTrue,
      reason: '视口裁剪是滚动能成立的前提，也是 BUG-1070（文字溢进工具条）的修复',
    );
  });

  test('③ 命中测试：视口判边界、布局取坐标', () {
    expect(src.contains('const float viewport_y = y - text_rect_.top;'), isTrue,
        reason: '用户只点得到看得见的字，边界必须判在视口里');
    expect(
      src.contains('const float local_y = viewport_y + scroll_offset_px_;'),
      isTrue,
      reason: '换算到布局坐标要加回偏移，否则滚动后点第一行会命中被滚走的那一行',
    );
    expect(
      src.contains(
          'out_char_rect->top = text_rect_.top + metrics.top - scroll_offset_px_;'),
      isTrue,
      reason: '查词卡的锚点矩形是客户区坐标，必须减回偏移才对得上屏幕上的那个字',
    );
  });

  test('④ 新台词回到顶部', () {
    final int i = src.indexOf('void FloatingLyricWindow::UpdateText(');
    expect(i, greaterThan(0));
    final int end = src.indexOf('void FloatingLyricWindow::Highlight(', i);
    expect(end, greaterThan(i));
    final String updateText = src.substring(i, end);
    expect(
      updateText.contains('scroll_offset_px_ = 0.0f;'),
      isTrue,
      reason: '换的是整句而不是往下追加：保留旧偏移只会把用户扔到一句他还没读过的'
          '话的中间，比跳回开头糟得多',
    );
  });

  test('⑤ 接管条件集中在 ScrollBy，滚到头不吞事件', () {
    expect(
      src.contains(
          'if (!hook_text_mode_ || pass_through_ || scroll_max_px_ <= 0.0f) {'),
      isTrue,
      reason: '三个前置条件必须写在一处：hook 模式 / 非穿透 / 真有溢出。'
          '穿透 = 鼠标整个属于游戏，顶部恢复带也不例外',
    );
    expect(src.contains('case WM_MOUSEWHEEL:'), isTrue, reason: '滚轮是最低交互要求');
    expect(
      src.contains('GET_WHEEL_DELTA_WPARAM(wparam)'),
      isTrue,
      reason: '滚动量要按真实 wheel delta 折算，不能一格一个固定值',
    );
    // 到顶 / 到底时 ScrollBy 返回 false，滚轮落回 DefWindowProc，
    // 窗口不做吃掉滚轮的黑洞。
    final int i = src.indexOf('bool FloatingLyricWindow::ScrollBy(');
    expect(i, greaterThan(0));
    final String scrollBy = src.substring(
        i, src.indexOf('void FloatingLyricWindow::SetLocked(', i));
    expect(
      scrollBy.contains('if (next == scroll_offset_px_) {'),
      isTrue,
      reason: '偏移没变就不能返回 true，否则窗口会变成吃掉滚轮的黑洞',
    );
    final int w = src.indexOf('case WM_MOUSEWHEEL:');
    final String wheelCase = src.substring(w, src.indexOf('case WM_SIZE:', w));
    expect(
      wheelCase
          .contains('return DefWindowProc(hwnd_, message, wparam, lparam);'),
      isTrue,
      reason: '不接管的滚轮必须落回 DefWindowProc',
    );
  });

  test('⑥ 滚动条画在右侧留白，且只在 hook 模式真溢出时出现', () {
    expect(src.contains('kScrollBarWidthDip'), isTrue);
    expect(src.contains('kScrollBarMinThumbDip'), isTrue);
    expect(
      src.contains('if (hook_text_mode_ && scroll_max_px_ > 0.0f) {'),
      isTrue,
      reason: '没有溢出就一个像素都不画（不滚动时逐像素不变）',
    );
    expect(
      src.contains('static_cast<float>(width) - pad * 0.5f - bar_w * 0.5f;'),
      isTrue,
      reason: '轨道必须落在 text_rect_ 右侧的留白里：压到文字就要缩窄换行宽度，'
          '而换行宽度会反过来改行程，形成回环',
    );
    expect(
      src.contains('text_rect_.height - ScaleForDpi(kResizeGripDip)'),
      isTrue,
      reason: '轨道底端要让开右下角 resize grip，两个可拖拽的东西不叠在一起',
    );
  });

  test('⑦ 歌词条 / 剪贴板文本窗不受滚动影响', () {
    // 非 hook 模式行程恒为 0：归零发生在排版分支之前，只有 hook 分支会重新赋值。
    final int layout =
        src.indexOf('  if (text_format_ != nullptr && !text_.empty()) {');
    expect(layout, greaterThan(0));
    final int zero = src.lastIndexOf('  scroll_max_px_ = 0.0f;', layout);
    expect(zero, greaterThan(0), reason: '归零必须发生在排版分支之前，且只有 hook 分支会重新赋值');
    expect(layout - zero, lessThan(400),
        reason: '归零要紧挨着排版分支，中间塞了别的逻辑就说明它跑到别处去了');
    // 第一阶段的成果不得被本次改动顺手撤掉。
    expect(src.contains('hook_text_mode_ ? 1.0f'), isTrue,
        reason: 'BUG-1095 第一阶段：hook 字号与窗高解耦，不得回退');
    expect(
        src.contains('strip_height_dip_ / kBaseStripHeightForFontDip'), isTrue,
        reason: '有声书歌词条「拖高放大」是既有行为，不得连坐');
  });
}
