import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// A-字形 守卫：制卡词典媒体（gaiji 外字）缓存命名必须 writer（主 app 的
/// writeDictionaryMediaCache）与 reader（AnkiMobile / AnkiDroid / AnkiConnect）
/// 共用同一稳定规则，否则文件名对不上→repo 读不到→卡片留下未替换的
/// `hoshi_dict_N.ext` 坏图。
void main() {
  group('ankiDictionaryMediaCacheFilename', () {
    test('uses stable sha1(path), not String.hashCode', () {
      const path = 'gaiji/bs一.svg';
      // Hoshi Reader 同类路径用内容/路径稳定哈希做媒体名；这里不能用 Dart
      // String.hashCode（跨运行时/平台不保证持久稳定），否则 iOS AnkiMobile 等
      // backend 会偶发读不到缓存里的 SVG。
      expect(
        ankiDictionaryMediaCacheFilename(path),
        'hibiki_dict_7de320e8f49c1e60a3ee86953fbafd6cadf701a7.svg',
      );
      expect(ankiDictionaryMediaCacheFilename(path), isNot(contains('-')));
    });

    test('falls back to bin when no usable extension', () {
      expect(ankiDictionaryMediaCacheFilename('gaiji/noext'),
          'hibiki_dict_9b891374d454bc61cb63a8b3ac0e229da34e0107.bin');
      expect(ankiDictionaryMediaCacheFilename('trailingdot.'),
          'hibiki_dict_f92d5205fb7693a5c12bf6ff5e0a53814b62a50e.bin');
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
