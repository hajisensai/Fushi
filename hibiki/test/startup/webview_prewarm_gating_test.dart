import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/startup/webview_prewarm.dart';

void main() {
  group('shouldPrewarmWebView', () {
    test('mobile prewarms when not low-memory', () {
      expect(
        shouldPrewarmWebView(
            isMobile: true, isDesktop: false, lowMemory: false),
        isTrue,
      );
    });

    test('mobile skips under low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: true, isDesktop: false, lowMemory: true),
        isFalse,
      );
    });

    test('desktop prewarms (regression: was mobile-only)', () {
      expect(
        shouldPrewarmWebView(
            isMobile: false, isDesktop: true, lowMemory: false),
        isTrue,
      );
    });

    test('desktop skips under low-memory', () {
      expect(
        shouldPrewarmWebView(isMobile: false, isDesktop: true, lowMemory: true),
        isFalse,
      );
    });

    test('neither mobile nor desktop does not prewarm', () {
      expect(
        shouldPrewarmWebView(
            isMobile: false, isDesktop: false, lowMemory: false),
        isFalse,
      );
    });
  });
}
