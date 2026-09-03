import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

import '../helpers/source_guard.dart';

// BUG-1918 ②：词典样式预览白屏。
//
// 内联 popup HTML 的四份资产（popup.css / dict-media.js / selection.js /
// popup.js）有两条装载路径：启动时 fire-and-forget 的 preloadInlinePopupAssets，
// 和真弹窗 build 里的同步兜底 _ensureInlinePopupAssetsLoaded。修前对外只暴露
// 裸的构造函数，它假定四份都在；词典样式预览直接调它，于是在预读没跑完（或曾
// 瞬时读盘失败）时拼出 `<style></style><script></script>` 的空壳——没有 popup.js，
// 预览白屏，连 window.renderPopup 都不存在。
//
// 修法是把「确保装载 + 四项非空 + 拼装」收成一个原语
// buildInlinePopupHtmlIfReady，未就绪返回 null 让调用方回退 file:// URL。
void main() {
  tearDown(DictionaryPopupWebViewState.debugResetInlinePopupAssets);

  test('资产未装载时返回 null，而不是拼出空壳 HTML', () {
    DictionaryPopupWebViewState.debugResetInlinePopupAssets();

    // widget/unit 测试进程里 flutter assets 目录不存在，_ensureInlinePopupAssetsLoaded
    // 的同步读盘必然失败 —— 正是「资产不可用」这一支。
    final String? html = DictionaryPopupWebViewState.buildInlinePopupHtmlIfReady(
      themeAttr: 'dark',
      bgHex: '#101010',
    );

    if (html != null) {
      // 极少数环境（就地跑在已构建产物旁）真能读到资产：那就必须是**实心**的，
      // 空壳一律算失败。这条分支保证本用例在两种环境下都不是恒真。
      //
      // 两种空壳形状都要查：资产字段是 `String?`，实现若退化成不判就绪就直接插值，
      // 产物是 `<style>null</style>` 而不是 `<style></style>`——只查后者会把真正的
      // 退化放过去（这正是本条判据原先的写法）。
      for (final String shell in const <String>[
        '<script></script>',
        '<style></style>',
        '<script>null</script>',
        '<style>null</style>',
      ]) {
        expect(html.contains(shell), isFalse,
            reason: '返回非 null 就必须带着真资产，不能是空壳 $shell');
      }
      return;
    }
    expect(html, isNull);
  });

  test('资产装载后返回的 HTML 真的带着那四份资产', () {
    DictionaryPopupWebViewState.debugResetInlinePopupAssets();
    DictionaryPopupWebViewState.debugSetInlinePopupAssets(
      css: '.fake-css-marker{}',
      dictMediaJs: 'window.__fakeDictMedia = 1;',
      selectionJs: 'window.__fakeSelection = 1;',
      popupJs: 'window.renderPopup = function () {};',
    );

    final String? html = DictionaryPopupWebViewState.buildInlinePopupHtmlIfReady(
      themeAttr: 'light',
      bgHex: '#ffffff',
    );

    expect(html, isNotNull);
    expect(html!.contains('.fake-css-marker{}'), isTrue);
    expect(html.contains('window.__fakeDictMedia = 1;'), isTrue);
    expect(html.contains('window.__fakeSelection = 1;'), isTrue);
    expect(html.contains('window.renderPopup = function () {};'), isTrue);
    expect(html.contains('id="entries-container"'), isTrue,
        reason: 'popup.js 的 __fushiContainer() 靠它取容器，缺了就直接静默返回');
  });

  test('预览与真弹窗都只能经这个原语拿内联 HTML', () {
    // 两个入口一旦有一个自己拼「确保装载 + 判空 + 构造」，就会重新漂移出白屏那一支。
    final String preview = maskComments(
      File('lib/src/pages/implementations/dict_style_preview.dart')
          .readAsStringSync(),
    );
    final String webview = maskComments(
      File('lib/src/pages/implementations/dictionary_popup_webview.dart')
          .readAsStringSync(),
    );

    expect(preview.contains('buildInlinePopupHtmlIfReady'), isTrue,
        reason: '预览必须走 buildInlinePopupHtmlIfReady');

    // 裸构造 _buildInlinePopupHtml 已是私有，外部拿不到；唯一还能绕过就绪检查的
    // 公开面是测试专用别名 debugBuildInlinePopupHtml，生产入口不得碰。
    expect(preview.contains('debugBuildInlinePopupHtml'), isFalse,
        reason: 'debugBuildInlinePopupHtml 不判就绪，是测试别名，生产入口不得调用');

    // 真弹窗侧断言**调用点**，不是「本文件出现过这个名字」——定义就在本文件，
    // 那样写恒真（这正是本条判据原先的写法）。
    expect(
      webview.contains('buildInlinePopupHtmlIfReady('),
      isTrue,
      reason: 'dictionary_popup_webview 的 build() 必须经就绪原语取内联 HTML',
    );

    // 裸构造只允许出现三次：定义自身 + 就绪原语内的调用 + 测试别名内的调用。
    // 多一处就是新开的绕过口，白屏那一支会从那里重新长出来。
    expect(
      RegExp(r'_buildInlinePopupHtml\s*\(').allMatches(webview).length,
      3,
      reason: '裸构造多了一个调用点：新入口必须改走 buildInlinePopupHtmlIfReady',
    );
  });
}
