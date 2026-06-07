import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// A-字形 守卫：制卡词典媒体（gaiji 外字）缓存命名必须 writer（主 app 的
/// writeDictionaryMediaCache）与 reader（两个 Anki repo）共用同一规则，否则文件名
/// 对不上→repo 读不到→卡片留下未替换的 `hoshi_dict_N.ext` 坏图。
void main() {
  group('ankiDictionaryMediaCacheFilename', () {
    test('uses hibiki_dict_<path.hashCode>.<ext> (matches repo formula)', () {
      const path = 'gaiji/bs一.svg';
      // 这正是两个 repo（_storeDictionaryMedia / _addDictionaryMedia）读缓存与
      // storeMediaFile 用的命名公式；任何一方改动都应让本断言失败。
      expect(
        ankiDictionaryMediaCacheFilename(path),
        'hibiki_dict_${path.hashCode}.svg',
      );
    });

    test('falls back to bin when no usable extension', () {
      expect(ankiDictionaryMediaCacheFilename('gaiji/noext'),
          'hibiki_dict_${'gaiji/noext'.hashCode}.bin');
      expect(ankiDictionaryMediaCacheFilename('trailingdot.'),
          'hibiki_dict_${'trailingdot.'.hashCode}.bin');
    });

    test('same path is stable within a run', () {
      const p = 'gaiji/参照.svg';
      expect(ankiDictionaryMediaCacheFilename(p),
          ankiDictionaryMediaCacheFilename(p));
    });

    test('cache dir path ends with anki-media', () {
      expect(ankiDictionaryMediaCacheDirPath().endsWith('anki-media'), isTrue);
    });
  });
}
