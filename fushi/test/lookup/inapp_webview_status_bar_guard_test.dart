// BUG-1105 源码守卫：**app 内**的查词/阅读 WebView 也不得画 WebView2 的链接地址预览。
//
// BUG-1097 只修了一半：那一轮只在 runner 自有的原生覆盖窗
// （windows/runner/global_lookup_window.cpp 的 ConfigureWebView）关了 status bar，
// 那是「app 外查词」独有的裸 WebView2。**app 内**的查词弹窗 / 阅读器 / 词典 tab
// （入口 lib/src/pages/implementations/dictionary_popup_webview.dart）走的是 vendored fork
// packages/flutter_inappwebview_windows，渲染的是同一份 popup.js（同一行
// `setAttribute('href', node.href)`），hover 词典内链照样在左下角冒地址。
//
// 修复是在 fork 的 C++ 里**无条件** put_IsStatusBarEnabled(FALSE)：Dart 侧字段住在
// pub-cache 的 flutter_inappwebview_platform_interface，本仓只 vendor 了 windows 包、
// 没 vendor platform_interface，加开关要么再 vendor 一个（影响全平台）要么就无条件设；
// 而 Hibiki 的每个 WebView 都只渲染 EPUB / 词典内容，没有任何 surface 想要浏览器状态栏。
//
// C++ 在 Dart 测试里跑不了，所以在源码层锁定两处 apply 点都设了：
//   ① prepare()   —— WebView 创建后的初始 settings 下发；
//   ② setSettings() —— Dart 侧热更新（弹窗改主题/缩放时会重推 InAppWebViewSettings）。
// 只锁一处的话，另一处将来被人重写就会悄悄把预览放回来。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// fork 的 WebView 实现源码（相对 `fushi/` 的测试 cwd）。
const String _forkSourcePath =
    '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp';

/// 取出 `InAppWebView::[name]` 的函数体源码（到下一个成员函数定义为止）。
/// 在 main() 顶层调用，故不能用 expect（那是 OutsideTestException），直接抛。
String _memberSource(String src, String name) {
  final int start = src.indexOf('InAppWebView::$name(');
  if (start < 0) {
    throw StateError('InAppWebView::$name 必须存在（守卫依赖它作为 settings 下发点）');
  }
  final int next = src.indexOf('\n  }\n', start);
  return src.substring(start, next == -1 ? src.length : next);
}

void main() {
  final String src = File(_forkSourcePath).readAsStringSync();

  test('① 创建路径 prepare() 里关掉 status bar（BUG-1105）', () {
    final String prepare = _memberSource(src, 'prepare');
    expect(
      prepare.contains('put_IsStatusBarEnabled(FALSE)'),
      isTrue,
      reason: 'prepare() 是 WebView 创建后唯一的初始 settings 下发点；'
          '不在这里关，app 内弹窗一开就带着链接地址预览',
    );
    expect(
      prepare.contains('webView->get_Settings(&webView2Settings)'),
      isTrue,
      reason: 'put_IsStatusBarEnabled 在基类 ICoreWebView2Settings 上，'
          'get_Settings 拿到的指针就够，不需要 QI 新版本接口',
    );
  });

  test('② 热更新路径 setSettings() 里同样关掉', () {
    final String setSettings = _memberSource(src, 'setSettings');
    expect(
      setSettings.contains('put_IsStatusBarEnabled(FALSE)'),
      isTrue,
      reason: 'Dart 侧任何时候都可能重推 InAppWebViewSettings；'
          '只在创建时设一次，将来有人在这里重建 settings 就会把预览放回来',
    );
  });

  test('③ 是无条件设置，不吊在某个 Dart 开关上', () {
    // 结构性理由：Dart 侧字段在未 fork 的 platform_interface 包里，
    // 加开关就得再 vendor 一个包。真加了字段，下面这个断言会红——那时请连同
    // 本注释一起重写，别默默删掉断言。
    expect(
      src.contains('fl_map_contains_not_null(newSettingsMap, "statusBar'),
      isFalse,
      reason: '本仓没有 fork flutter_inappwebview_platform_interface，'
          '没有对应 Dart 字段；一旦出现条件判断说明有人加了半个开关',
    );
  });

  test('④ 词典内链的 href 保持不动（与 BUG-1097 同口径）', () {
    final String popupJs = File('assets/popup/popup.js').readAsStringSync();
    expect(
      popupJs.contains("setAttribute('href', node.href)"),
      isTrue,
      reason: 'href 是点击处理的输入，不得为了消掉预览而删链接',
    );
  });
}
