import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-129 source guard: the seeded hidden warm popup slot (BUG-094) is an
/// Android `InAppWebView` — a native platform view that eats touches even under
/// `Visibility`'s `Opacity(0)+IgnorePointer`, killing the video controls (top
/// bar + bottom bar) it overlaps on mobile. The fix parks the hidden slot fully
/// off-screen (`left = screen.width + 8`) at real size (so it still warms) and
/// makes the host Stack `Clip.none` so the off-screen slot isn't clipped away.
/// Locks the call-site invariant (platform-view touch behavior has no headless
/// test).
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('mixin: 隐藏热槽停到屏幕右外侧', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(src.contains('screen.width + 8'), isTrue,
        reason: '隐藏热槽必须停到屏外（left=screen.width+8），否则原生 WebView 吃掉控件触摸');
    expect(src.contains('!entry.visible'), isTrue,
        reason: '只对隐藏(!visible)的热槽停屏外，可见查词层用真实位置');
  });

  test('reader base_source_page: 隐藏热槽停屏外 + Stack Clip.none', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    expect(src.contains('screen.width + 8'), isTrue, reason: '阅读器隐藏热槽也要停屏外');
    expect(src.contains('clipBehavior: Clip.none'), isTrue,
        reason: '宿主 Stack 用 Clip.none，让屏外热槽不被裁掉仍预热');
  });

  test('video 弹窗 Overlay Stack 用 Clip.none', () {
    final String src =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    expect(src.contains('clipBehavior: Clip.none'), isTrue,
        reason: '视频根 Overlay 弹窗 Stack 用 Clip.none，屏外热槽保持预热');
  });
}
