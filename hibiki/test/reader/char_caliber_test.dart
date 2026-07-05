import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart' show kChapterCharCountCaliber;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show chaptersJsonCharCaliberIsCurrent, sessionWatermarkAfterRestore;

/// TODO-1192：锁定「计数口径版本判定」+「跨章回读水位只升不降」两条纯逻辑。
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
}
