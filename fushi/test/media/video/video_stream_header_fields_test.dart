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

    test('a comma inside a value stays inside that value (BUG-2617)', () {
      // 在线视频源扩展给的 UA 几乎人手一个 `(KHTML, like Gecko)`：裸逗号连接会把它
      // 拆成半条 UA + 一条没有冒号的垃圾项，防盗链 CDN 直接拒 → 点开必转圈到超时。
      const String ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
      final Map<String, String> p = buildHttpHeaderFieldsProperty(
        <String, String>{'User-Agent': ua, 'Referer': 'https://a.test/'},
      );
      final String value = p['http-header-fields']!;
      // 值里的逗号转义成 `\,`：mpv 的 get_nextsep 只认这一种，读回来仍是一整条 UA。
      expect(
        value,
        'User-Agent: ${ua.replaceAll(',', '\\,')},Referer: https://a.test/',
      );
      // 分项时未转义的逗号只有一个：项与项之间的那个。
      expect(
        RegExp(r'(?<!\\),').allMatches(value).length,
        1,
        reason: 'UA 内部的逗号必须全部带转义，否则会被拆成半条 UA + 无冒号垃圾项',
      );
    });

    test('backslash escaping is what libmpv actually parses (probed)', () {
      // 随包 libmpv 实测（写字符串、按 MPV_FORMAT_NODE 读回项数组）：
      //   'a\,b'   -> ['a,b']      转义逗号不分项
      //   'a\b'    -> ['a\b']      裸反斜杠原样保留（不是通用转义符）
      //   'a\\b'   -> ['a\\b']     连续反斜杠也原样保留
      // 长度前缀 `%n%` 在字符串列表上完全不生效（会原样留在头名里且逗号照拆），
      // 所以只转义逗号、其它字符一律不动。
      expect(encodeMpvListItem('X-A: a,b'), 'X-A: a\\,b');
      expect(encodeMpvListItem('X-A: a\\b'), 'X-A: a\\b');
      expect(encodeMpvListItem('X-Note: 日本語'), 'X-Note: 日本語',
          reason: '非 ASCII 不需要任何编码：mpv 按字节流原样保留');
      expect(encodeMpvListItem('X-A: plain'), 'X-A: plain');
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
