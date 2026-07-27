import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

/// BUG-717 ②：内联 popup HTML（Windows/iOS 路径，约 300KB 含 69KB css）此前在
/// 每次 build()（拖拽调整弹窗大小时每个指针事件一次）重拼并对 css 做整串
/// replaceAll；InAppWebView 只在创建平台视图时消费 initialData，重复构造是纯
/// 浪费。修复后按 (themeAttr, bgHex) 单槽 memo，`</style` 转义挪到装载时一次。
void main() {
  setUp(DictionaryPopupWebViewState.debugResetInlinePopupAssets);
  tearDownAll(DictionaryPopupWebViewState.debugResetInlinePopupAssets);

  void seedAssets({String css = 'body{color:red}'}) {
    DictionaryPopupWebViewState.debugSetInlinePopupAssets(
      css: css,
      dictMediaJs: 'var dm=1;',
      selectionJs: 'var sel=1;',
      popupJs: 'var pj=1;',
    );
  }

  test('same (themeAttr, bgHex) returns the identical cached instance', () {
    seedAssets();
    final String first = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'dark', bgHex: '#112233');
    final String second = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'dark', bgHex: '#112233');
    expect(identical(first, second), isTrue,
        reason: '同主题/底色必须命中 memo 返回同一实例——'
            '拖拽调整弹窗大小的每个指针事件都会走到这里');
    expect(first, contains('data-theme="dark"'));
    expect(first, contains('--background-color:#112233'));
  });

  test('theme or background change rebuilds with the new values', () {
    seedAssets();
    final String dark = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'dark', bgHex: '#112233');
    final String light = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'light', bgHex: '#ffffff');
    expect(identical(dark, light), isFalse);
    expect(light, contains('data-theme="light"'));
    expect(light, contains('--background-color:#ffffff'));
    // 单槽 memo：换回旧键重建（允许），内容必须与最初一致（不串味）。
    final String darkAgain =
        DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
            themeAttr: 'dark', bgHex: '#112233');
    expect(darkAgain, dark);
  });

  test('</style in css is escaped (load-time escape keeps byte parity)', () {
    seedAssets(css: 'a{}</style><b>break-out</b>');
    final String html = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'dark', bgHex: '#000000');
    expect(html, contains(r'a{}<\/style><b>break-out</b>'),
        reason: 'css 里的 </style 必须在装载时转义，产物与旧的每次转义逐字节一致');
    expect(html, isNot(contains('a{}</style>')),
        reason: '未转义的 </style 会提前终结 <style> 块（注入面）');
  });

  test('asset (re)load invalidates the html memo', () {
    seedAssets(css: 'body{color:red}');
    final String before = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'dark', bgHex: '#112233');
    expect(before, contains('body{color:red}'));

    seedAssets(css: 'body{color:blue}');
    final String after = DictionaryPopupWebViewState.debugBuildInlinePopupHtml(
        themeAttr: 'dark', bgHex: '#112233');
    expect(after, contains('body{color:blue}'),
        reason: '资产重装载必须清空 HTML memo，不得回吐旧 css 的产物');
  });

  test('host navigation bridge is gated, idempotent, and captures page keys',
      () {
    final String enabled =
        DictionaryPopupWebViewState.debugHostNavigationKeyScript(true);
    final String disabled =
        DictionaryPopupWebViewState.debugHostNavigationKeyScript(false);

    expect(enabled, contains('__hibikiHostNavigationKeysEnabled = true'));
    expect(disabled, contains('__hibikiHostNavigationKeysEnabled = false'));
    expect(enabled, contains('__hibikiHostNavigationKeysInstalled'));
    expect(enabled, contains("'ArrowLeft'"));
    expect(enabled, contains("'ArrowRight'"));
    expect(enabled, contains("'Escape'"));
    expect(enabled, contains('preventDefault()'));
    expect(enabled, contains('stopImmediatePropagation()'));
    expect(enabled, contains("callHandler('hostNavigationKey', key)"));
    expect(enabled, contains("addEventListener('keydown'"));
  });
}
