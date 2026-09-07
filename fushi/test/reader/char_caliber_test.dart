import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart' show kChapterCharCountCaliber;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show chaptersJsonCharCaliberIsCurrent;

/// TODO-1192：锁定「计数口径版本判定」纯逻辑。（原本还钉着标量水位
/// `sessionWatermarkAfterRestore` / `computeCharWatermark`，2026-09-06 字数统计改走
/// `ReadUnitLedger` 翻走即计后两者已删，坐标换算见
/// `reader_read_ledger_boundaries_test.dart` 的 `absoluteCharOffsetOf`。）
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
}
