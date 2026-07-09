import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

/// TODO-1353 guard: Ctrl+滚轮在查词弹窗内缩放内容（改词典字号，持久化）。
///
/// 缩放本体（documentElement.style.zoom）注入进 WebView、归设备集成验证；此处锁：
///  1. 词典字号的步进 / 夹紧纯函数（[steppedPopupZoomFontSize] /
///     [clampPopupZoomFontSize]）——JS wheel 监听与 Dart 持久化两侧共用同一语义。
///  2. 源码里 Ctrl+滚轮监听（`_zoomWheelJs`）、其 onLoadStop 注入、`popupZoomFont`
///     回调、以及 buildPopupSettingsJs 暴露的 `__hoshiPopupFontSize/UiScale` 都在位，
///     防止后续重构悄悄拆掉某一环导致缩放不生效 / 不持久化。
void main() {
  group('DictionaryPopupWebViewState 字号步进/夹紧 (TODO-1353)', () {
    test('上滚放大一档、下滚缩小一档（16 基准）', () {
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(16, zoomIn: true),
        17,
      );
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(16, zoomIn: false),
        15,
      );
    });

    test('夹到 [8, 72] 区间，杜绝缩没 / 撑爆', () {
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(1000), 72);
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(2), 8);
      // 步进在边界处不越界。
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(72, zoomIn: true),
        72,
      );
      expect(
        DictionaryPopupWebViewState.steppedPopupZoomFontSize(8, zoomIn: false),
        8,
      );
    });

    test('非法（非有限 / 非正）字号回退默认 16', () {
      expect(
        DictionaryPopupWebViewState.clampPopupZoomFontSize(double.nan),
        16,
      );
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(0), 16);
      expect(DictionaryPopupWebViewState.clampPopupZoomFontSize(-5), 16);
    });
  });

  group('Ctrl+滚轮缩放接线在位 (TODO-1353)', () {
    final String webviewSrc = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final String injectionSrc = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();

    test('wheel 监听只在 ctrlKey 时拦截并 preventDefault', () {
      expect(webviewSrc.contains('__hoshiZoomWheelInstalled'), isTrue);
      expect(webviewSrc.contains("addEventListener('wheel'"), isTrue);
      expect(webviewSrc.contains('e.ctrlKey'), isTrue);
      expect(webviewSrc.contains('e.preventDefault()'), isTrue);
    });

    test('监听在 onLoadStop 注入、并有 popupZoomFont 持久化回调', () {
      expect(
        webviewSrc.contains('evaluateJavascript(source: _zoomWheelJs)'),
        isTrue,
      );
      expect(webviewSrc.contains("handlerName: 'popupZoomFont'"), isTrue);
      expect(webviewSrc.contains('setDictionaryFontSize('), isTrue);
    });

    test('注入体暴露 __hoshiPopupFontSize / __hoshiPopupUiScale 供 JS 就地算 zoom', () {
      expect(injectionSrc.contains('window.__hoshiPopupFontSize'), isTrue);
      expect(injectionSrc.contains('window.__hoshiPopupUiScale'), isTrue);
    });
  });
}
