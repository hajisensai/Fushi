import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

void main() {
  group('DictionaryPopupWebView', () {
    test('forces dictionary collapse for creator lookup popups', () {
      expect(
        DictionaryPopupWebView.shouldCollapseDictionaries(
          appPreference: false,
          forceCollapse: true,
        ),
        isTrue,
      );
    });

    test('uses the app preference outside forced popup contexts', () {
      expect(
        DictionaryPopupWebView.shouldCollapseDictionaries(
          appPreference: true,
          forceCollapse: false,
        ),
        isTrue,
      );
      expect(
        DictionaryPopupWebView.shouldCollapseDictionaries(
          appPreference: false,
          forceCollapse: false,
        ),
        isFalse,
      );
    });
  });
}
