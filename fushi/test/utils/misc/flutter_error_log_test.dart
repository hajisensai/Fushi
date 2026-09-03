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
}
