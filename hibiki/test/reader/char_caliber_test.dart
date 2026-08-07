import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart' show kChapterCharCountCaliber;
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart'
    show
        chaptersJsonCharCaliberIsCurrent,
        computeCharWatermark,
        sessionWatermarkAfterRestore;

/// TODO-1192：锁定「计数口径版本判定」+「跨章回读水位只升不降」两条纯逻辑。
/// BUG-1107：追加锁定「水位与真实恢复锚同源」（[computeCharWatermark]）。
void main() {
  String jsonFor(List<Map<String, Object?>> entries) => jsonEncode(entries);

  Map<String, Object?> chapter({int? caliber, int characters = 100}) =>
      <String, Object?>{
        'id': 'ch',
        'href': 'ch.xhtml',
        'mediaType': 'application/xhtml+xml',
        'characters': characters,
        if (caliber != null) 'charCaliber': caliber,
      };

  group('chaptersJsonCharCaliberIsCurrent', () {
    test('每章都带当前口径版本 → true', () {
      final String s = jsonFor(<Map<String, Object?>>[
        chapter(caliber: kChapterCharCountCaliber),
        chapter(caliber: kChapterCharCountCaliber),
      ]);
      expect(chaptersJsonCharCaliberIsCurrent(s, 2), isTrue);
    });

    test('旧书无 charCaliber 标记 → false（触发后台重算并回写）', () {
      final String s = jsonFor(<Map<String, Object?>>[
        chapter(),
        chapter(),
      ]);
      expect(chaptersJsonCharCaliberIsCurrent(s, 2), isFalse);
    });

    test('任一章口径版本不符（旧 v1）→ false', () {
      final String s = jsonFor(<Map<String, Object?>>[
        chapter(caliber: kChapterCharCountCaliber),
        chapter(caliber: 1),
      ]);
      expect(chaptersJsonCharCaliberIsCurrent(s, 2), isFalse);
    });

    test('章节数不符 → false', () {
      final String s = jsonFor(<Map<String, Object?>>[
        chapter(caliber: kChapterCharCountCaliber),
      ]);
      expect(chaptersJsonCharCaliberIsCurrent(s, 2), isFalse);
    });

    test('非法 JSON / 空 → false', () {
      expect(chaptersJsonCharCaliberIsCurrent('not json', 2), isFalse);
      expect(chaptersJsonCharCaliberIsCurrent('[]', 0), isFalse);
    });
  });

  group('sessionWatermarkAfterRestore (水位只升不降)', () {
    test('首次进入：从 0 抬到恢复位置', () {
      expect(sessionWatermarkAfterRestore(0, 1500), 1500);
    });

    test('前进到更靠后的章：水位上抬到新章起点', () {
      expect(sessionWatermarkAfterRestore(1000, 3000), 3000);
    });

    test('跨章回读（恢复到更靠前的位置）：水位不下调', () {
      // 已读到 5000，往回翻章恢复到 2000 → 水位保持 5000，重读不重复计。
      expect(sessionWatermarkAfterRestore(5000, 2000), 5000);
    });

    test('恢复到同一位置：保持不变', () {
      expect(sessionWatermarkAfterRestore(3000, 3000), 3000);
    });
  });

  group('computeCharWatermark (BUG-1107 水位与恢复锚同源)', () {
    // 三章书：字数 [1000, 2000, 3000]，章首累计 [0, 1000, 3000]。
    const List<int> cumulative = <int>[0, 1000, 3000];
    const List<int> counts = <int>[1000, 2000, 3000];

    test('正常分数恢复（无精确锚）：章首累计 + progress×章字数', () {
      expect(
        computeCharWatermark(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: counts,
          chapter: 1,
          progress: 0.5,
          charOffset: -1,
        ),
        1000 + 1000,
      );
    });

    test('charAnchor 恢复：progress 被强制 0.0 时锚仍然生效（爆表根因）', () {
      // BUG-1107 断点 B：收藏句跳转把 _initialProgress 强制 0.0、锚存在
      // _initialCharOffset。旧实现只看 progress → 水位落章首 (1000)，首个进度
      // 回调把章内前 1500 字整段误计成新读字数。新实现用锚推导。
      expect(
        computeCharWatermark(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: counts,
          chapter: 1,
          progress: 0.0,
          charOffset: 1500,
        ),
        1000 + 1500,
      );
    });

    test('锚超出本章字数：clamp 到章尾（零计数占位期安全）', () {
      expect(
        computeCharWatermark(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: counts,
          chapter: 0,
          progress: 0.0,
          charOffset: 99999,
        ),
        1000,
      );
      // 零计数占位（DB 计数未就绪）：锚被 clamp 到 0，不产生虚位。
      expect(
        computeCharWatermark(
          chapterCumulativeChars: const <int>[0, 0],
          chapterCharCounts: const <int>[0, 0],
          chapter: 1,
          progress: 0.0,
          charOffset: 500,
        ),
        0,
      );
    });

    test('cue 兜底（progress 0 + 无锚）：水位落章首（不虚增也不负增）', () {
      expect(
        computeCharWatermark(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: counts,
          chapter: 2,
          progress: 0.0,
          charOffset: -1,
        ),
        3000,
      );
    });

    test('章越界 / 计数未就绪：返回 0（水位取 max 时恒为 no-op）', () {
      expect(
        computeCharWatermark(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: counts,
          chapter: 3,
          progress: 0.5,
          charOffset: -1,
        ),
        0,
      );
      expect(
        computeCharWatermark(
          chapterCumulativeChars: const <int>[],
          chapterCharCounts: const <int>[],
          chapter: 0,
          progress: 0.5,
          charOffset: 100,
        ),
        0,
      );
      expect(
        computeCharWatermark(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: counts,
          chapter: -1,
          progress: 0.5,
          charOffset: 100,
        ),
        0,
      );
    });
  });
}
