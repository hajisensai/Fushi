import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_country_display.dart';

void main() {
  group('formatVideoCountriesForDisplay', () {
    test('有全称时丢弃 ISO alpha-2 代码，消除同一国家双词条堆叠', () {
      expect(
        formatVideoCountriesForDisplay(
          const <String>['United States of America', 'US'],
        ),
        const <String>['United States of America'],
      );
    });

    test('纯代码列表原样保留（AniList/Bangumi 只有 countryOfOrigin 代码）', () {
      expect(
        formatVideoCountriesForDisplay(const <String>['JP']),
        const <String>['JP'],
      );
      expect(
        formatVideoCountriesForDisplay(const <String>['JP', 'US']),
        const <String>['JP', 'US'],
      );
    });

    test('去空白与重复，多全称保序', () {
      expect(
        formatVideoCountriesForDisplay(
          const <String>[' Japan ', 'Japan', 'JP', '', 'United Kingdom', 'GB'],
        ),
        const <String>['Japan', 'United Kingdom'],
      );
    });

    test('非 ASCII 全称（豆瓣中文国家名）不会被当代码丢弃', () {
      expect(
        formatVideoCountriesForDisplay(const <String>['美国', 'US']),
        const <String>['美国'],
      );
    });

    test('空输入返回空列表', () {
      expect(formatVideoCountriesForDisplay(const <String>[]), isEmpty);
    });
  });
}
