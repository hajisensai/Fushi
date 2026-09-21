import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';

void main() {
  group('buildHttpHeaderFieldsProperty (TODO-850 stage1)', () {
    test('empty headers -> empty props (no-op, local/plain stream unaffected)',
        () {
      expect(buildHttpHeaderFieldsProperty(const <String, String>{}), isEmpty);
    });

    test('single header -> length-prefixed "Key: Value"', () {
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        const <String, String>{'Referer': 'https://a.test/'},
      );
      expect(p['http-header-fields'], '%24%Referer: https://a.test/');
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
        '%24%Referer: https://a.test/,%23%User-Agent: Mozilla/5.0',
      );
    });

    test('a comma inside a value stays inside that value (BUG-2617)', () {
      // 在线视频源扩展给的 UA 几乎人手一个 `(KHTML, like Gecko)`：裸逗号连接会把它
      // 拆成半条 UA + 一条没有冒号的垃圾项，防盗链 CDN 直接拒 → 点开必转圈到超时。
      const String ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        <String, String>{'User-Agent': ua, 'Referer': 'https://a.test/'},
      );
      final String value = p['http-header-fields']!;
      const String item = 'User-Agent: $ua';
      expect(value, startsWith('%${item.length}%$item'));
      // 长度前缀之后紧跟的必须是下一项的前缀，不能是 UA 被截断的残段。
      expect(value, '%${item.length}%$item,%24%Referer: https://a.test/');
    });

    test('length prefix counts UTF-8 bytes, not UTF-16 code units', () {
      // 扩展给的头里出现非 ASCII（日文站点的自定义头 / 带中文的 Cookie）时，按 Dart
      // 的 String.length 算会短报，mpv 会从值中间截断。
      const String item = 'X-Note: 日本語';
      expect(encodeMpvListItem(item), '%17%$item');
      expect(item.length, 11, reason: 'UTF-16 码元数确实与字节数不同，测试才有意义');
    });

    test('blank key is dropped; all-blank keys -> empty props', () {
      expect(
        buildHttpHeaderFieldsProperty(const <String, String>{'   ': 'x'}),
        isEmpty,
      );
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        const <String, String>{'   ': 'x', 'Referer': 'r'},
      );
      expect(p['http-header-fields'], '%10%Referer: r');
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
