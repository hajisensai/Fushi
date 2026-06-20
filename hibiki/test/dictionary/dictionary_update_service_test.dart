import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// TODO-609：DictionaryUpdateService 比对逻辑——纯函数守卫。
///
/// needsUpdate(local, remote)：远端 revision 非空且与本地不同 → 需更新。
/// remote 为 null/空（拉取失败或远端无 revision）→ 保守判 false（不误报有更新）。
/// parseRevisionFromIndexJson：从远端 index.json 文本取 revision，坏 JSON → null。
void main() {
  group('DictionaryUpdateService.needsUpdate', () {
    test('本地与远端 revision 相同 → false', () {
      expect(
        DictionaryUpdateService.needsUpdate('2026-06-20', '2026-06-20'),
        isFalse,
      );
    });

    test('本地与远端不同 → true', () {
      expect(
        DictionaryUpdateService.needsUpdate('2026-06-19', '2026-06-20'),
        isTrue,
      );
    });

    test('远端 null（拉取失败）→ false（不误报）', () {
      expect(DictionaryUpdateService.needsUpdate('2026-06-19', null), isFalse);
    });

    test('远端空串 → false', () {
      expect(DictionaryUpdateService.needsUpdate('2026-06-19', ''), isFalse);
    });

    test('本地空 + 远端非空 → true', () {
      expect(DictionaryUpdateService.needsUpdate('', '2026-06-20'), isTrue);
    });
  });

  group('DictionaryUpdateService.parseRevisionFromIndexJson', () {
    test('合法 index.json → revision', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson(
          '{"title":"JMdict","revision":"2026-06-20"}',
        ),
        '2026-06-20',
      );
    });

    test('无 revision 字段 → null', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('{"title":"X"}'),
        isNull,
      );
    });

    test('revision 空串 → null', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('{"revision":""}'),
        isNull,
      );
    });

    test('坏 JSON → null（不崩）', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('not json'),
        isNull,
      );
    });

    test('顶层非对象 → null', () {
      expect(
        DictionaryUpdateService.parseRevisionFromIndexJson('[1,2]'),
        isNull,
      );
    });
  });
}
