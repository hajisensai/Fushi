import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';

void main() {
  group('dictionaryMediaWebResourceResponse', () {
    test('returns 404 for malformed image scheme before dictionary init', () {
      final response = dictionaryMediaWebResourceResponse(
        Uri.parse('image://?dictionary=Dict'),
      );

      expect(response, isNotNull);
      expect(response!.statusCode, 404);
      expect(response.contentType, 'text/plain');
      expect(response.data, isEmpty);
    });

    test('returns 404 for malformed dictmedia scheme before dictionary init', () {
      final response = dictionaryMediaWebResourceResponse(
        Uri.parse('dictmedia://styles.css'),
      );

      expect(response, isNotNull);
      expect(response!.statusCode, 404);
      expect(response.contentType, 'text/plain');
      expect(response.data, isEmpty);
    });
  });

  group('dictionaryMediaCustomSchemeResponse', () {
    test('handles malformed image scheme before dictionary init', () {
      final response = dictionaryMediaCustomSchemeResponse(
        Uri.parse('image://?dictionary=Dict'),
      );

      expect(response, isNotNull);
      expect(response!.contentType, 'text/plain');
      expect(response.contentEncoding, 'utf-8');
      expect(response.data, isEmpty);
    });

    test('handles malformed dictmedia scheme before dictionary init', () {
      final response = dictionaryMediaCustomSchemeResponse(
        Uri.parse('dictmedia://styles.css'),
      );

      expect(response, isNotNull);
      expect(response!.contentType, 'text/plain');
      expect(response.contentEncoding, 'utf-8');
      expect(response.data, isEmpty);
    });
  });
}
