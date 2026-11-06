import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Android WebView 在 Hybrid Composition 下不许挂硬件层（全仓所有 WebView：
/// 浏览器、阅读器、漫画、查词弹窗、视频、歌词模式）。
///
/// 上游把默认的 `hardwareAcceleration = true` 实现成
/// `setLayerType(View.LAYER_TYPE_HARDWARE, null)`：WebView 每帧先画进一张整屏
/// 离屏层再合成。120Hz 平板实测浏览器滚动 RenderThread 一帧 13.6 ms（约 55 fps、
/// 9% 卡顿帧），改成 `LAYER_TYPE_NONE` 后 8.0 ms（74–82 fps、0.3%）。HC 下的
/// WebView 本来就挂在硬件加速窗口里，NONE 照样走 GPU。见
/// `third_party/flutter_inappwebview_android/PATCHES.md`。
///
/// 例外只有 `setStaticLayer`：查词弹窗打开期间、正文静止时由 app 显式给正文开层
///（弹窗滚动时窗口复用正文像素，不必每帧重跑正文绘制），弹窗全关即关。
void main() {
  test(
    'Hybrid Composition WebView: no hardware layer except setStaticLayer',
    () {
      const String relative =
          'third_party/flutter_inappwebview_android/android/src/main/java/com/'
          'pichillilorenzo/flutter_inappwebview_android/webview/in_app_webview/'
          'InAppWebView.java';
      final File file = <String>[relative, '../$relative']
          .map(File.new)
          .firstWhere(
            (File f) => f.existsSync(),
            orElse: () => fail('$relative not found'),
          );
      final String raw = file.readAsStringSync();
      final String src = maskComments(raw);

      // 唯一合法的硬件层：查词弹窗打开、正文静止期间由 app 显式开的静态层
      //（`setStaticLayer`，见 fushi 的 `PopupBodyStaticLayerGate`）。
      final String staticLayer = maskComments(
        methodBody(raw, 'public boolean setStaticLayer(boolean enabled)'),
      );
      expect(
        staticLayer,
        contains(
          'if (customSettings == null || !customSettings.useHybridComposition)',
        ),
        reason: 'setStaticLayer must stay a no-op off Hybrid Composition',
      );
      expect(
        'LAYER_TYPE_HARDWARE'.allMatches(staticLayer).length,
        1,
        reason: 'setStaticLayer toggles HARDWARE / NONE once',
      );
      expect(
        'LAYER_TYPE_HARDWARE'.allMatches(src).length,
        1,
        reason:
            'LAYER_TYPE_HARDWARE may only appear inside setStaticLayer: a '
            'hardware layer redraws a full-size offscreen buffer every frame '
            'while the page scrolls (~55 fps on a 120 Hz screen)',
      );

      final String prepare = maskComments(
        methodBody(raw, 'public void prepare()'),
      );
      expect(
        RegExp(
          r'if \(customSettings\.useHybridComposition\) \{\s*'
          r'setLayerType\(View\.LAYER_TYPE_NONE, null\);\s*\}',
        ).hasMatch(prepare),
        isTrue,
        reason: 'prepare() must pin LAYER_TYPE_NONE under Hybrid Composition',
      );
    },
  );
}
