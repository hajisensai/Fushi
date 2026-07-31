import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_input_bridge.dart';
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

  test('popup input bridge carries the host spec and stays idempotent', () {
    // BUG-1071 复诉：旧桥的键表硬编码 ArrowLeft/ArrowRight/Escape、且被
    // capturesDictionaryPopupNavigationKeys 门控成漫画页专属，阅读器/视频页压根没装
    // ——「关闭词典」的鼠标键与快捷键在弹窗持焦时因此全无反应。现在表由宿主按注册表
    // 当前绑定下发。行为面（谁被转发、改键跟不跟随）由 test/focus/
    // webview_key_bridge_behavior_test.dart 真跑 JS 验证，这里只锁注入面。
    final String bound = DictionaryPopupWebViewState.debugHostInputBridgeScript(
      const DictionaryPopupInputSpec(
        keyTokens: <String>['Escape', 'Ctrl+KeyD'],
        mouseButtons: <int>[3],
      ),
    );
    final String empty = DictionaryPopupWebViewState.debugHostInputBridgeScript(
      const DictionaryPopupInputSpec(),
    );

    expect(bound, contains("'Escape', 'Ctrl+KeyD'"),
        reason: '宿主声明的键（含组合键）必须原样进表');
    expect(bound,
        contains("window['__hoshiKeyBridgeButtons_hostInputToken'] = [3]"),
        reason: '鼠标绑定必须进表——弹窗表面此前完全没有非左键通道');
    expect(
        empty, contains("window['__hoshiKeyBridgeKeys_hostInputToken'] = []"),
        reason: '空表也要下发，用于清掉热槽 WebView 上残留的旧表');
    expect(
        bound, contains("window['__hoshiKeyBridgeInstalled_hostInputToken']"),
        reason: '幂等安装守卫：热槽反复注入不得叠加 listener');
    expect(bound, contains('if (e.repeat) return;'),
        reason: '按住关词典键不该逐层关掉整条弹窗栈');
    expect(bound, contains('stopImmediatePropagation()'),
        reason: '交给宿主的输入不能再被 popup.js 自己的监听二次响应');
    expect(bound, contains("callHandler('hostInputToken', _hit)"));
    expect(bound, contains("addEventListener('keydown'"));
    expect(bound, contains("addEventListener('mousedown'"));
  });
}
