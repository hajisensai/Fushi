import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2790：app 外查词窗（`:popup` 热引擎）第二次打开起只剩冻住的旧 WebView、
/// 释义滑不动。根因：热引擎关窗只 detach，查词 WebView 若是老式 Hybrid Composition，
/// raster 线程并进 platform 线程，`~GPUSurfaceGLImpeller` 析构时不清当前上下文
/// （flutter#174495），复挂后每帧 `EGL_BAD_ACCESS`。
///
/// 全线 Impeller（2026-10-24 所有者拍板，不留 Skia 回退）后，修法是让热引擎里的查词
/// WebView 走 TLHC（不合并线程），而不是给 `:popup` 引擎关 Impeller。这里钉住两侧：
/// 引擎不带任何关 Impeller 的参数；`popupMain` 在建任何 WebView 之前把查词 WebView
/// 切到 TLHC，且这个开关真的接到了 `useHybridComposition`。
void main() {
  const String holder =
      'android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt';
  const String popupMainPath = 'lib/popup_main.dart';
  const String webviewPath =
      'lib/src/pages/implementations/dictionary_popup_webview.dart';

  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  test(':popup 引擎不关 Impeller', () {
    final String src = read(holder);
    final int at = src.indexOf('val engine = FlutterEngine(');
    expect(at, isNot(-1), reason: '找不到 :popup 引擎的创建点');
    final String call = src.substring(at, src.indexOf(')\n', at) + 1);
    expect(call, isNot(contains('enable-impeller')));
    expect(src, isNot(contains('--enable-impeller=false')));
    expect(src, contains('BUG-2790'), reason: '创建点要带着根因说明');
  });

  test('popupMain 在 runApp 之前把查词 WebView 切到 TLHC', () {
    final String src = read(popupMainPath);
    final int flag = src.indexOf(
      'dictionaryPopupWebViewUsesHybridComposition = false;',
    );
    final int run = src.indexOf('runApp(');
    expect(flag, isNot(-1), reason: '热引擎里的查词 WebView 必须走 TLHC');
    expect(run, isNot(-1));
    expect(flag, lessThan(run), reason: '必须在建任何 WebView 之前置位');
  });

  test('开关接到查词 WebView 的 useHybridComposition', () {
    final String src = read(webviewPath);
    expect(
      src,
      contains('bool dictionaryPopupWebViewUsesHybridComposition = true;'),
      reason: '主进程默认保持 HC，只有热引擎改 TLHC',
    );
    expect(
      src,
      contains(
        'useHybridComposition: dictionaryPopupWebViewUsesHybridComposition,',
      ),
    );
  });
}
