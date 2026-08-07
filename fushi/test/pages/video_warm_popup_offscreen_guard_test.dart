import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-135 source guard: the seeded hidden warm popup slot (BUG-094) is an
/// Android `InAppWebView` — a native platform view that eats touches even under
/// `Visibility`'s `Opacity(0)+IgnorePointer`, killing the video controls (top
/// bar + bottom bar) it overlaps on mobile. The fix parks the hidden slot fully
/// off-screen (`left = screen.width + 8`) at real size (so it still warms) and
/// makes the host Stack `Clip.none` so the off-screen slot isn't clipped away.
/// Locks the call-site invariant (platform-view touch behavior has no headless
/// test).
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('parkedPopupLayer 把隐藏热槽停到屏幕右外侧（收口的单一真相）', () {
    // BUG-135 parking 几何已收口到 dictionary_popup_layer.parkedPopupLayer；
    // 平台视图触摸行为无 headless 测试，锁这条结构不变式。
    final String src =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(src.contains('Widget parkedPopupLayer('), isTrue);
    expect(src.contains('visible ? pos.left : screen.width + 8'), isTrue,
        reason: '隐藏(!visible)层停到屏外 left=screen.width+8，可见层用真实位置');
  });

  test('mixin 经 parkedPopupLayer 渲染弹窗层', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(src.contains('parkedPopupLayer('), isTrue,
        reason: '弹窗层渲染经 parkedPopupLayer（BUG-135 parking 收口处）');
  });

  test('reader base_source_page: 经 parkedPopupLayer + Stack Clip.none', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    expect(src.contains('parkedPopupLayer('), isTrue,
        reason: '阅读器弹窗层也经 parkedPopupLayer 停屏外');
    expect(src.contains('clipBehavior: Clip.none'), isTrue,
        reason: '宿主 Stack 用 Clip.none，让屏外热槽不被裁掉仍预热');
  });

  test('app 外查词窗 popup_dictionary_page: 隐藏层经 parkedPopupLayer 停真屏外', () {
    final String src =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');
    expect(src.contains('parkedPopupLayer('), isTrue,
        reason: 'TODO-1379：卡片局部坐标 cardWidth+8 停靠在窄卡/宽屏时仍在屏内，'
            '隐藏原生 WebView 截获触摸（弹窗滚动/点击全死）；必须经 BUG-135 收口停真屏外');
    expect(src.contains('clipBehavior: Clip.none'), isTrue,
        reason: '宿主 Stack 用 Clip.none，屏外热槽不被裁掉仍预热');
    expect(src.contains('left: cardWidth + 8'), isFalse,
        reason: '禁止回退到卡片局部坐标（屏内）停靠');
  });

  test('video 弹窗 Overlay Stack 用 Clip.none', () {
    final String src =
        read('lib/src/pages/implementations/video_fushi_page.dart');
    expect(src.contains('clipBehavior: Clip.none'), isTrue,
        reason: '视频根 Overlay 弹窗 Stack 用 Clip.none，屏外热槽保持预热');
  });
}
