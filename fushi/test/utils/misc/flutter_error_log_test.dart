import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/flutter_error_log.dart';

void main() {
  group('flutterErrorLogSource', () {
    test('extracts the human-readable ErrorDescription text', () {
      final FlutterErrorDetails details = FlutterErrorDetails(
        exception: const FormatException('bad response'),
        context: ErrorDescription('while resolving an image codec'),
      );

      expect(
        flutterErrorLogSource(details),
        'FlutterError: while resolving an image codec',
      );
      expect(
        flutterErrorLogSource(details),
        isNot(contains("Instance of 'ErrorDescription'")),
      );
    });

    test('keeps an explicit fallback when Flutter supplies no context', () {
      const FlutterErrorDetails details = FlutterErrorDetails(
        exception: FormatException('bad response'),
      );

      expect(flutterErrorLogSource(details), 'FlutterError: unknown');
    });
  });
  // BUG-5601: integration tests run the real main() inside flutter_test. The
  // app's FlutterError.onError must hand errors to the handler it found (the
  // test binding) instead of replacing it.
  group('flutterErrorPresenterFor', () {
    test('keeps the framework presenter when nothing else owns the hook', () {
      expect(
        identical(
          flutterErrorPresenterFor(FlutterError.presentError),
          FlutterError.presentError,
        ),
        isTrue,
      );
      expect(
        identical(flutterErrorPresenterFor(null), FlutterError.presentError),
        isTrue,
      );
    });

    test('forwards non-silent errors to a host handler, not silent ones', () {
      final List<Object> seen = <Object>[];
      final FlutterExceptionHandler present = flutterErrorPresenterFor(
        (FlutterErrorDetails d) => seen.add(d.exception),
      );
      present(const FlutterErrorDetails(exception: 'loud'));
      present(const FlutterErrorDetails(exception: 'quiet', silent: true));
      expect(seen, <Object>['loud']);
    });

    testWidgets('a test binding sees errors the app presenter reports', (
      WidgetTester tester,
    ) async {
      // FlutterError.onError is the binding's handler here, exactly as it is
      // when an itest launches main().
      final FlutterExceptionHandler present = flutterErrorPresenterFor(
        FlutterError.onError,
      );
      present(const FlutterErrorDetails(exception: 'framework error'));
      expect(tester.takeException(), 'framework error');
    });
  });
}
