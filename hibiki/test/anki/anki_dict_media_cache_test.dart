import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// A-字形 守卫：制卡词典媒体（gaiji 外字）缓存命名必须 writer（主 app 的
/// writeDictionaryMediaCache）与 reader（AnkiMobile / AnkiDroid / AnkiConnect）
/// 共用同一稳定规则，否则文件名对不上→repo 读不到→卡片留下未替换的
/// `hoshi_dict_N.ext` 坏图。
///
/// BUG-897：哈希输入是 `<dict> <path>`（词典名 + NUL 分隔 + 相对路径），只对
/// path 求哈希会让两本词典同一相对路径的外字串味。
void main() {
  group('ankiDictionaryMediaCacheFilename', () {
    test('uses stable sha1(dict+path), not String.hashCode', () {
      const path = 'gaiji/bs一.svg';
      // Hoshi Reader 同类路径用内容/路径稳定哈希做媒体名；这里不能用 Dart
      // String.hashCode（跨运行时/平台不保证持久稳定），否则 iOS AnkiMobile 等
      // backend 会偶发读不到缓存里的 SVG。
      expect(
        ankiDictionaryMediaCacheFilename('明鏡', path),
        'hibiki_dict_74259f28356918b3397453d0a5b467182d1ba404.svg',
      );
      expect(
          ankiDictionaryMediaCacheFilename('明鏡', path), isNot(contains('-')));
    });

    test('falls back to bin when no usable extension', () {
      expect(ankiDictionaryMediaCacheFilename('明鏡', 'gaiji/noext'),
          'hibiki_dict_7467bc1485d9e93b46b4c5885134bd3819e80c1e.bin');
      expect(ankiDictionaryMediaCacheFilename('明鏡', 'trailingdot.'),
          'hibiki_dict_17f7764207115aa3b04a6466c0c0b8d8e6f2d3bf.bin');
    });

    test('same dict+path is stable within a run', () {
      const p = 'gaiji/参照.svg';
      expect(ankiDictionaryMediaCacheFilename('明鏡', p),
          ankiDictionaryMediaCacheFilename('明鏡', p));
    });

    test('BUG-897: different dictionaries never share a cache name', () {
      // 两本词典含同一相对路径的外字（都叫 gaiji/参照.svg）必须落到不同文件，
      // 否则后制卡的词典嵌入前者的图片（跨词典串味）。
      const p = 'gaiji/参照.svg';
      expect(
        ankiDictionaryMediaCacheFilename('明鏡', p),
        isNot(ankiDictionaryMediaCacheFilename('大辞泉', p)),
      );
    });

    test('cache dir path ends with anki-media', () {
      expect(ankiDictionaryMediaCacheDirPath().endsWith('anki-media'), isTrue);
    });
  });
}
