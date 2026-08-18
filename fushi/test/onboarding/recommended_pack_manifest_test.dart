import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';

void main() {
  group('parseRecommendedPackManifest', () {
    test('valid manifest parses and lowercases sha256', () {
      final String sha = 'A' * 64;
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
        '{"version":"2026-09-01",'
        '"url":"https://dl.wrds.xyz/fushi-recommended-2026-09-01.fushi.zip",'
        '"sha256":"$sha","size_bytes":10200000000}',
      );
      expect(m, isNotNull);
      expect(
          m!.url, 'https://dl.wrds.xyz/fushi-recommended-2026-09-01.fushi.zip');
      expect(m.version, '2026-09-01');
      expect(m.sha256, 'a' * 64);
      expect(m.sizeBytes, 10200000000);
    });

    test('url is required and must be https', () {
      expect(parseRecommendedPackManifest('{"version":"x"}'), isNull);
      expect(
        parseRecommendedPackManifest('{"url":"http://dl.wrds.xyz/a.zip"}'),
        isNull,
      );
    });

    test('bad sha256 shape rejects the whole manifest', () {
      // 长度不对 / 非 hex：与其带着一个坏校验值下 9.5 GB，不如整体回退内置直链。
      expect(
        parseRecommendedPackManifest(
            '{"url":"https://dl.wrds.xyz/a.zip","sha256":"zz"}'),
        isNull,
      );
    });

    test('optional fields tolerate absence and wrong types', () {
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
          '{"url":"https://dl.wrds.xyz/a.zip","size_bytes":"big","version":3}');
      expect(m, isNotNull);
      expect(m!.sha256, isNull);
      expect(m.sizeBytes, isNull);
      expect(m.version, isNull);
    });

    test('malformed json / non-object returns null', () {
      expect(parseRecommendedPackManifest('not json'), isNull);
      expect(parseRecommendedPackManifest('[1,2,3]'), isNull);
    });
  });
}
