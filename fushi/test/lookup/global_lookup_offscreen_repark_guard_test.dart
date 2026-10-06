// BUG-2886 — 查词覆盖窗的离屏停放位只在建窗那一刻算一次（虚拟桌面右缘 + 200）。
// 显示拓扑之后变宽（分辨率 / 缩放 / 热插拔），「显示着但没 Reveal」的预热窗就落进
// 屏幕右上角，成为一块吞点击的不可见区域（真机：x=3144 落在 3840 宽的屏内，
// WindowFromPoint 命中 Chrome_RenderWidgetHostHWND）。守住：拓扑变化时重新停放。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

String _block(String src, String start, String end) {
  final int i = src.indexOf(start);
  expect(i, greaterThan(0), reason: '找不到 $start');
  final int j = src.indexOf(end, i + start.length);
  expect(j, greaterThan(i), reason: '找不到 $start 之后的 $end');
  return src.substring(i, j);
}

void main() {
  // 只断言代码：注释里解释「为什么不带 SWP_SHOWWINDOW」本身会提到这个词。
  final String src = maskComments(
    File('windows/runner/global_lookup_window.cpp').readAsStringSync(),
  );

  test('WM_DISPLAYCHANGE 与 WM_DPICHANGED 都重新停放离屏窗', () {
    final String display = _block(
      src,
      'case WM_DISPLAYCHANGE:',
      'case WM_ENTERSIZEMOVE:',
    );
    expect(
      display.contains('ReparkOffscreenIfParked();'),
      isTrue,
      reason: '桌面变宽后停放窗必须回到新的 OffscreenX()',
    );
    final String dpi = _block(
      src,
      'case WM_DPICHANGED: {',
      'case WM_DISPLAYCHANGE:',
    );
    expect(
      dpi.contains('ReparkOffscreenIfParked();'),
      isTrue,
      reason: '系统建议矩形按旧位置换算，停放窗照单全收会留在屏内',
    );
  });

  test('只挪「显示着但未上屏」的窗，且只换位置', () {
    final String body = _block(
      src,
      'void GlobalLookupWindow::ReparkOffscreenIfParked() {',
      '\n}\n',
    );
    expect(body.contains('revealed_'), isTrue, reason: '已上屏的卡片绝不能被拓扑变化甩出屏幕');
    expect(body.contains('IsWindowVisible(hwnd_)'), isTrue);
    expect(body.contains('OffscreenX()'), isTrue, reason: '停放位必须按当前拓扑现算，不能缓存');
    expect(body.contains('SWP_NOSIZE'), isTrue);
    expect(body.contains('SWP_NOACTIVATE'), isTrue);
    expect(body.contains('SWP_SHOWWINDOW'), isFalse, reason: '重新停放不得把隐藏窗弄可见');
  });
}
