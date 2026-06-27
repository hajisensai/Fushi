import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';

void main() {
  group('buildHttpHeaderFieldsProperty (TODO-850 stage1)', () {
    test('empty headers -> empty props (no-op, local/plain stream unaffected)',
        () {
      expect(buildHttpHeaderFieldsProperty(const <String, String>{}), isEmpty);
    });

    test('single header -> "Key: Value"', () {
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        const <String, String>{'Referer': 'https://a.test/'},
      );
      expect(p['http-header-fields'], 'Referer: https://a.test/');
    });

    test('multiple headers joined by comma; trims key/value', () {
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        const <String, String>{
          '  Referer ': ' https://a.test/ ',
          'User-Agent': 'Mozilla/5.0',
        },
      );
      expect(
        p['http-header-fields'],
        'Referer: https://a.test/,User-Agent: Mozilla/5.0',
      );
    });

    test('blank key is dropped; all-blank keys -> empty props', () {
      expect(
        buildHttpHeaderFieldsProperty(const <String, String>{'   ': 'x'}),
        isEmpty,
      );
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        const <String, String>{'   ': 'x', 'Referer': 'r'},
      );
      expect(p['http-header-fields'], 'Referer: r');
    });
  });
}
