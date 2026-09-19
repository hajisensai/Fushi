import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';

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

    test('clear property resets http-header-fields to empty (episode switch)',
        () {
      // 换集复用同一 Player：上一站的 Referer 若不清会带到下一站的 hoster。
      expect(kClearHttpHeaderFieldsProperty, <String, String>{
        'http-header-fields': '',
      });
      expect(buildHttpHeaderFieldsProperty(const <String, String>{}), isEmpty,
          reason: '空 header 本身不产生属性，清空要走专门的 clear 路径');
    });
  });
}
