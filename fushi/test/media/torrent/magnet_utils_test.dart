import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/torrent/magnet_utils.dart';

void main() {
  group('parseMagnetInfoHash', () {
    test('40-hex btih normalizes to lowercase', () {
      const String m =
          'magnet:?xt=urn:btih:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&dn=x';
      expect(
          parseMagnetInfoHash(m), 'c12fe1c06bba254a9dc9f519b335aa7c1367a88a');
    });

    test('32-char base32 btih decodes to 40-hex', () {
      // base32 of the 20 bytes 0x00..0x13 → known hex.
      // 使用一个真实等价对：hex 全 0xFF → base32 '77777777777777777777777777777777'
      const String m = 'magnet:?xt=urn:btih:77777777777777777777777777777777';
      expect(
          parseMagnetInfoHash(m), 'ffffffffffffffffffffffffffffffffffffffff');
    });

    test('non-magnet URI → null', () {
      expect(parseMagnetInfoHash('http://example.com/x.torrent'), isNull);
      expect(parseMagnetInfoHash('just some text'), isNull);
    });

    test('missing btih → null', () {
      expect(parseMagnetInfoHash('magnet:?dn=foo'), isNull);
    });

    test('wrong-length hash → null', () {
      expect(parseMagnetInfoHash('magnet:?xt=urn:btih:abcd'), isNull);
    });

    test('multiple xt: picks the btih one', () {
      const String m =
          'magnet:?xt=urn:ed2k:deadbeef&xt=urn:btih:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A';
      expect(
          parseMagnetInfoHash(m), 'c12fe1c06bba254a9dc9f519b335aa7c1367a88a');
    });
  });

  group('parseMagnetDisplayName', () {
    test('extracts dn', () {
      expect(parseMagnetDisplayName('magnet:?xt=urn:btih:abc&dn=My%20Book'),
          'My Book');
    });

    test('no dn → null', () {
      expect(parseMagnetDisplayName('magnet:?xt=urn:btih:abc'), isNull);
    });
  });

  group('magnetUriFromInfoHash', () {
    test('40-hex → 最小磁链，往返能被 parseMagnetInfoHash 解回', () {
      final String? m = magnetUriFromInfoHash(
        'C12FE1C06BBA254A9DC9F519B335AA7C1367A88A',
        displayName: 'Frieren 01',
      );
      expect(
          m,
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a'
          '&dn=Frieren+01');
      expect(
          parseMagnetInfoHash(m!), 'c12fe1c06bba254a9dc9f519b335aa7c1367a88a');
      expect(parseMagnetDisplayName(m), 'Frieren 01');
    });

    test('32-char base32 → 十六进制；空 dn 不带参数', () {
      expect(magnetUriFromInfoHash('77777777777777777777777777777777'),
          'magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff');
    });

    test('长度不对 / 非十六进制 → null', () {
      expect(magnetUriFromInfoHash('abc'), isNull);
      expect(magnetUriFromInfoHash('z' * 40), isNull);
    });
  });
}
