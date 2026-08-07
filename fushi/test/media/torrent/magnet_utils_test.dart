import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/magnet_utils.dart';

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
}
