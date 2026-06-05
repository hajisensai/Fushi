import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

/// 划词弹窗内容 CSS `zoom` 系数的纯函数守卫。
///
/// 弹窗内容跟随「界面大小」(appUiScale) 与「词典字号」(dictionaryFontSize) 一起
/// 放大，与 Dart 侧盒子尺寸（base_source_page / dictionary_page_mixin 乘 appUiScale）
/// 一致。基准 (appUiScale=1, fontSize=16) → 1.0，保持改动前观感。真正的 zoom 注入
/// 进 WebView，归设备集成验证；此处只锁公式。
void expectClose(double a, double b) => expect(a, closeTo(b, 1e-9));

void main() {
  group('DictionaryPopupWebViewState.popupContentZoom', () {
    test('default scale + default font size yields 1.0 (unchanged look)', () {
      expectClose(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 1.0,
          dictionaryFontSize: 16.0,
        ),
        1.0,
      );
    });

    test('UI scale alone scales the popup content proportionally', () {
      expectClose(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 2.0,
          dictionaryFontSize: 16.0,
        ),
        2.0,
      );
    });

    test('font size alone scales relative to the 16px baseline', () {
      expectClose(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 1.0,
          dictionaryFontSize: 24.0,
        ),
        1.5,
      );
    });

    test('UI scale and font size compound', () {
      expectClose(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 2.0,
          dictionaryFontSize: 8.0,
        ),
        1.0,
      );
    });

    test('non-finite or non-positive inputs fall back to 1.0', () {
      expect(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: double.nan,
          dictionaryFontSize: 16.0,
        ),
        1.0,
      );
      expect(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 1.0,
          dictionaryFontSize: 0.0,
        ),
        1.0,
      );
    });

    test('extreme values are clamped into [0.3, 8.0]', () {
      expect(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 3.0,
          dictionaryFontSize: 200.0,
        ),
        8.0,
      );
      expect(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: 0.3,
          dictionaryFontSize: 1.0,
        ),
        0.3,
      );
    });
  });
}
