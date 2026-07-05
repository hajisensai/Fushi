import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1152 静态守卫：锁住「in-app 查词结果区 WebView 渲染完补表面重绘 nudge」的
/// 接线，防止静默回退到下半屏黑。
///
/// 根因：结果区 WebView 填满 [Expanded]（全高固定大区域）。Windows 上 WebView2 内容
/// 在 put_Bounds 撑高后 render 完即 idle 无 damage，宿主 WGC 帧池采不到新暴露的下半区
/// → 下半屏黑。修复是渲染完成（popupRendered）后在 WebView 内逼一帧全页合成，让 WGC
/// 捕获完整视口。此守卫锁三点：
///  - DictionaryPopupWebView 暴露 nudgeSurfaceOnRender 开关（默认 false）。
///  - popupRendered 处理器在开关为真时调 _nudgeSurfaceRepaint（且 nudge 仅 Windows）。
///  - home_dictionary_page 的结果区 WebView 开了 nudgeSurfaceOnRender: true。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test(
      'DictionaryPopupWebView exposes an opt-in surface-repaint nudge (default off)',
      () {
    final src =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    // 开关字段存在，且默认关（不破坏 nested 弹窗等自适应宿主的原行为）。
    expect(src.contains('final bool nudgeSurfaceOnRender;'), isTrue,
        reason: 'the widget must expose a nudgeSurfaceOnRender flag');
    expect(src.contains('this.nudgeSurfaceOnRender = false,'), isTrue,
        reason: 'the nudge must default OFF (Never break userspace)');
  });

  test('popupRendered fires the surface nudge only when opted-in, Windows-only',
      () {
    final src =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    // popupRendered → onRendered → 条件触发 nudge。
    final int renderedCallIdx = src.indexOf('widget.onRendered?.call();');
    expect(renderedCallIdx, greaterThanOrEqualTo(0));
    final int nudgeCallIdx =
        src.indexOf('if (widget.nudgeSurfaceOnRender) _nudgeSurfaceRepaint();');
    expect(nudgeCallIdx, greaterThan(renderedCallIdx),
        reason:
            'the nudge must fire right after onRendered, gated by the flag');
    // nudge 实现存在，且用不可见 opacity 触发一帧合成，且仅 Windows 执行。
    final int methodIdx = src.indexOf('void _nudgeSurfaceRepaint() {');
    expect(methodIdx, greaterThanOrEqualTo(0),
        reason: 'the nudge method must exist');
    final int windowsGateIdx =
        src.indexOf('if (!isWindowsPlatform) return;', methodIdx);
    expect(windowsGateIdx, greaterThan(methodIdx),
        reason: 'the nudge must be a no-op off Windows (WebView2/WGC quirk)');
    expect(src.contains('_surfaceRepaintNudgeJs'), isTrue,
        reason: 'the nudge must evaluate the repaint JS');
    expect(src.contains("el.style.opacity = '0.9999';"), isTrue,
        reason: 'the nudge forces one imperceptible full-page composite');
  });

  test('home dictionary result WebView opts into the surface nudge', () {
    final src = read('lib/src/pages/implementations/home_dictionary_page.dart');
    final int resultKeyIdx = src.indexOf('key: _resultWebViewKey,');
    expect(resultKeyIdx, greaterThanOrEqualTo(0),
        reason: 'the result WebView must exist');
    // nudgeSurfaceOnRender: true 必须挂在结果区 WebView 上（在其 key 之后、其
    // 构造收尾之前）。用结果 WebView 的收尾锚点 onTopPullReleased 定界。
    final int tailIdx = src.indexOf(
        'onTopPullReleased: _clearSearchFromResultPull,', resultKeyIdx);
    expect(tailIdx, greaterThan(resultKeyIdx));
    final int nudgeIdx =
        src.indexOf('nudgeSurfaceOnRender: true,', resultKeyIdx);
    expect(nudgeIdx, greaterThan(resultKeyIdx),
        reason: 'the result WebView must enable nudgeSurfaceOnRender');
  });
}
