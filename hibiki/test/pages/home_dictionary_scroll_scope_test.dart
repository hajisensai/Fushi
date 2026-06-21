import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TODO-685 (原 TODO-460 阶段2 漏补)：首页查词结果区滚动 scope 守卫。
///
/// TODO-460 把鼠标滚轮的「每格步长」从粗颗粒原生滚动细化成接近浏览器的平滑滚动，
/// 修复点落在共享查词 WebView 资产 `assets/popup/popup.js` 的 wheel 通道
/// （`POPUP_WHEEL_PIXEL_FACTOR` / `POPUP_WHEEL_MAX_VISUAL_STEP` /
/// `popupClampWheelVisualStep`）。`popup_wheel_scroll_asset_test` 已守住 popup.js
/// 资产本身的常量与事件拦截，但**没有**守住「首页查词结果区确实接入这条共享
/// scope」——若有人把结果区改成普通 Flutter `ListView` 或原生未折算的 WebView，
/// popup.js 的平滑通道就再也不经过首页结果区，460 的手感静默回归而无任何测试变红。
///
/// 本守卫沿真实接线链逐环钉住（任一环断开即红，非恒真）：
///   home_dictionary_page 结果区 → DictionaryPopupWebView（共享查词 WebView）
///   → assets/popup/popup.html → <script src="popup.js"> → 460 的 wheel 平滑常量。
/// 同时钉住结果区仍在 `HibikiAppUiScaleNeutralizer`（净缩放=1）下渲染——这是
/// popup.js wheel 步长按 `documentElement.style.zoom` 折算「zoom-independent」的前提，
/// 若结果区被全局界面大小缩放，460 的 zoom 折算口径就不再成立。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String readSource(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue,
        reason: '$relativePath must exist for the scroll-scope guard.');
    return file.readAsStringSync();
  }

  group('home dictionary result area shares the TODO-460 wheel scope', () {
    test('renders results through DictionaryPopupWebView (the popup.js scope)',
        () {
      final String source = readSource(
        'lib/src/pages/implementations/home_dictionary_page.dart',
      );

      // 结果区必须 import 并实际构造共享查词 WebView，而不是回退到普通 ListView /
      // 原生 WebView——只有它会加载 460 修过的 popup.js wheel 通道。
      expect(
        source,
        contains(
            "import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';"),
        reason: 'The result area must depend on the shared dictionary popup '
            'WebView so it inherits the TODO-460 smooth-wheel channel.',
      );

      final int resultBodyAt =
          source.indexOf('Widget _buildSearchResultBody()');
      expect(resultBodyAt, greaterThanOrEqualTo(0),
          reason: 'The dictionary result body builder must exist.');
      final int webViewAt =
          source.indexOf('DictionaryPopupWebView(', resultBodyAt);
      expect(webViewAt, greaterThan(resultBodyAt),
          reason: 'The result body must render results through '
              'DictionaryPopupWebView (shared popup.js scroll scope), not a '
              'plain Flutter ListView or a raw native-scroll WebView.');
    });

    test('keeps the result WebView under the UI-scale neutralizer (zoom=1)',
        () {
      final String source = readSource(
        'lib/src/pages/implementations/home_dictionary_page.dart',
      );

      final int resultBodyAt =
          source.indexOf('Widget _buildSearchResultBody()');
      final int neutralizerAt =
          source.indexOf('HibikiAppUiScaleNeutralizer(', resultBodyAt);
      final int webViewAt =
          source.indexOf('DictionaryPopupWebView(', resultBodyAt);
      expect(neutralizerAt, greaterThan(resultBodyAt),
          reason: 'The result body must wrap the result WebView in '
              'HibikiAppUiScaleNeutralizer.');
      expect(webViewAt, greaterThan(neutralizerAt),
          reason: 'popup.js refines each wheel notch and divides by '
              'documentElement.style.zoom; this only stays zoom-independent if '
              'the result WebView renders at neutralized scale (zoom=1), so the '
              'neutralizer must wrap the DictionaryPopupWebView.');
    });
  });

  group('the shared popup WebView still loads the TODO-460 wheel asset', () {
    test('DictionaryPopupWebView loads assets/popup/popup.html', () {
      final String source = readSource(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      );
      expect(source, contains("webViewAssetUrl('assets/popup/popup.html')"),
          reason: 'The shared dictionary WebView must load the popup HTML that '
              'pulls in popup.js.');
    });

    test('popup.html pulls in popup.js', () {
      final String html = readSource('assets/popup/popup.html');
      expect(html, contains('<script src="popup.js">'),
          reason: 'popup.html must include popup.js, which carries the '
              'TODO-460 smooth-wheel channel.');
    });
  });

  test('popup.js still carries the TODO-460 smooth-wheel channel', () async {
    // Load the asset the same way the popup runtime does (rootBundle), so this
    // guard pins the actual shipped JS, not a stray copy.
    final String js = await rootBundle.loadString('assets/popup/popup.js');
    expect(js, contains('POPUP_WHEEL_PIXEL_FACTOR'),
        reason: 'TODO-460 finer per-notch factor must remain in popup.js.');
    expect(js, contains('POPUP_WHEEL_MAX_VISUAL_STEP'),
        reason:
            'TODO-460 single-notch visual-step cap must remain in popup.js.');
    expect(js, contains('popupClampWheelVisualStep'),
        reason: 'TODO-460 visual-step clamp helper must remain in popup.js.');
    expect(js, contains("document.addEventListener('wheel'"),
        reason: 'The smooth-wheel channel relies on a custom wheel listener.');
  });
}
