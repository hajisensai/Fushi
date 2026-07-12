import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-748：VN 居中竖排布局下「点击空白翻页」永不触发。_hoshiVnTapIsBlank 靠
// caretPositionFromPoint/caretRangeFromPoint，它们把任意点（含空白边距）clamp 到
// 最近字符，故旧判据「resolve 到 text node 即非空白」把整个视口都判成词 → blank-tap
// advance 从不触发（Windows 离屏 289 点扫描 0 blank）。根因修复：拿到 clamp 后的 caret
// 再用该字符的 client rect 精确命中测试——点真落在字形盒内=词（查词），落在盒外（被
// clamp 过去的边距）=空白（翻页）。headless 跑不到真实几何，这里钉死源码里必须有精确
// 命中测试（getClientRects）而不是只看 text node。
void main() {
  test(
      'BUG-748: _hoshiVnTapIsBlank uses client-rect hit-test, not just a '
      'clamped text-node check', () {
    final String src = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync();

    final int fnStart = src.indexOf('function _hoshiVnTapIsBlank(');
    expect(fnStart, greaterThanOrEqualTo(0),
        reason: '_hoshiVnTapIsBlank must exist');
    // isolate the function body up to the next top-level function decl so the
    // assertions are about THIS function, not the whole file.
    final int fnEnd =
        src.indexOf('function _hoshiReaderCaretRangeAtPoint(', fnStart);
    expect(fnEnd, greaterThan(fnStart));
    final String body = src.substring(fnStart, fnEnd);

    expect(
      body.contains('getClientRects()'),
      isTrue,
      reason: 'blank-detection must hit-test the resolved glyph box '
          '(getClientRects) so margin taps clamped to a char are still blank',
    );
    expect(
      body.contains('r.left') &&
          body.contains('r.right') &&
          body.contains('r.top') &&
          body.contains('r.bottom'),
      isTrue,
      reason:
          'hit-test must compare the tap point against the char rect bounds',
    );
  });
}
