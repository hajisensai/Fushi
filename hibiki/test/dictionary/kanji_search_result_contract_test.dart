// TODO-094 S4 kanji data-contract + single-kanji logic tests.
//
// These exercise REAL Dart logic (no native FFI, no mocking of a kanji query):
//   - `HoshiKanjiResult.toMap` / `fromMap` round-trip every field, including the
//     surrogate-pair / empty-field degradation a serialized popup payload may
//     carry across the process boundary.
//   - `DictionarySearchResult` carries `kanjiResults` through `toJson` /
//     `fromJson` so the popup data layer receives the kanji card alongside the
//     term entries (S5 only renders; S4 puts the data here).
//   - `withKanjiResults` attaches kanji to a built term result while preserving
//     the term `entries`, `popupJson`, `bestLength` and `scrollPosition`.
//   - `AppModel.isSingleKanji` gates the engine query to a single CJK ideograph
//     (counting by runes so astral-plane kanji are one character), so multi-char
//     terms and kana/latin singletons never trigger a kanji lookup.
//
// The actual `query_kanji` round-trip needs the FFI library recompiled with the
// S3 kanji exports (the current dev .dll/.so predate them) and is left to a
// real-device pass — these tests intentionally do NOT fake a real kanji query.
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  group('HoshiKanjiResult serialization', () {
    test('toMap / fromMap round-trips every field', () {
      const HoshiKanjiResult original = HoshiKanjiResult(
        character: '日',
        onyomi: 'ニチ ジツ',
        kunyomi: 'ひ -び -か',
        radical: '日',
        strokes: 4,
        meanings: <String>['day', 'sun', 'Japan'],
        dictName: 'KANJIDIC',
      );
      final HoshiKanjiResult restored =
          HoshiKanjiResult.fromMap(original.toMap());
      expect(restored.character, original.character);
      expect(restored.onyomi, original.onyomi);
      expect(restored.kunyomi, original.kunyomi);
      expect(restored.radical, original.radical);
      expect(restored.strokes, original.strokes);
      expect(restored.meanings, original.meanings);
      expect(restored.dictName, original.dictName);
    });

    test('fromMap degrades missing / null fields without throwing', () {
      final HoshiKanjiResult r =
          HoshiKanjiResult.fromMap(<String, dynamic>{'character': '水'});
      expect(r.character, '水');
      expect(r.onyomi, '');
      expect(r.kunyomi, '');
      expect(r.radical, '');
      expect(r.strokes, 0);
      expect(r.meanings, isEmpty);
      expect(r.dictName, '');
    });
  });

  group('DictionarySearchResult carries kanjiResults', () {
    test('toJson / fromJson round-trips kanji results alongside entries', () {
      final DictionarySearchResult result = DictionarySearchResult(
        searchTerm: '日',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'Daijirin',
            word: '日',
            reading: 'ひ',
            meaning: 'sun',
          ),
        ],
        kanjiResults: const <HoshiKanjiResult>[
          HoshiKanjiResult(
            character: '日',
            onyomi: 'ニチ',
            kunyomi: 'ひ',
            radical: '日',
            strokes: 4,
            meanings: <String>['day', 'sun'],
            dictName: 'KANJIDIC',
          ),
        ],
      );
      final DictionarySearchResult restored =
          DictionarySearchResult.fromJson(result.toJson());
      expect(restored.searchTerm, '日');
      expect(restored.entries.length, 1);
      expect(restored.entries.single.word, '日');
      expect(restored.kanjiResults.length, 1);
      final HoshiKanjiResult k = restored.kanjiResults.single;
      expect(k.character, '日');
      expect(k.onyomi, 'ニチ');
      expect(k.strokes, 4);
      expect(k.meanings, <String>['day', 'sun']);
      expect(k.dictName, 'KANJIDIC');
    });

    test('fromJson defaults kanjiResults to empty for a legacy payload', () {
      // A payload produced before S4 has no "kanjiResults" key.
      const String legacyJson =
          '{"searchTerm":"語","bestLength":1,"scrollPosition":0,"entries":[]}';
      final DictionarySearchResult restored =
          DictionarySearchResult.fromJson(legacyJson);
      expect(restored.kanjiResults, isEmpty);
      expect(restored.searchTerm, '語');
    });

    test('default constructor leaves kanjiResults empty (term-only path)', () {
      final DictionarySearchResult r = DictionarySearchResult(searchTerm: '読む');
      expect(r.kanjiResults, isEmpty);
    });

    test('withKanjiResults attaches kanji while preserving term fields', () {
      final DictionarySearchResult termOnly = DictionarySearchResult(
        searchTerm: '日',
        entries: <DictionaryEntry>[
          DictionaryEntry(word: '日', reading: 'ひ', meaning: 'sun'),
        ],
        bestLength: 1,
        scrollPosition: 7,
      );
      termOnly.popupJson = '[{"term":"日"}]';

      final DictionarySearchResult withKanji =
          termOnly.withKanjiResults(const <HoshiKanjiResult>[
        HoshiKanjiResult(
          character: '日',
          onyomi: 'ニチ',
          kunyomi: 'ひ',
          radical: '日',
          strokes: 4,
          meanings: <String>['day'],
          dictName: 'KANJIDIC',
        ),
      ]);

      expect(withKanji.kanjiResults.length, 1);
      // Term fields preserved.
      expect(withKanji.entries.length, 1);
      expect(withKanji.entries.single.word, '日');
      expect(withKanji.bestLength, 1);
      expect(withKanji.scrollPosition, 7);
      expect(withKanji.popupJson, termOnly.popupJson);
      // Original unchanged (no kanji leaked onto it).
      expect(termOnly.kanjiResults, isEmpty);
    });
  });

  group('AppModel.isSingleKanji gating', () {
    test('a single CJK ideograph is a single kanji', () {
      expect(AppModel.isSingleKanji('日'), isTrue); // 日
      expect(AppModel.isSingleKanji('語'), isTrue); // 語
      expect(AppModel.isSingleKanji('一'), isTrue); // 一
    });

    test('an astral-plane (Extension B) kanji counts as one character', () {
      // U+20BB7 (𠮷) is encoded as a surrogate pair in a Dart String; counting
      // by .length would see 2 and wrongly reject it, runes see 1.
      const String extB = '\u{20BB7}';
      expect(extB.length, 2); // surrogate pair sanity check
      expect(AppModel.isSingleKanji(extB), isTrue);
    });

    test('kana / latin singletons are not kanji', () {
      expect(AppModel.isSingleKanji('あ'), isFalse);
      expect(AppModel.isSingleKanji('ア'), isFalse);
      expect(AppModel.isSingleKanji('a'), isFalse);
      expect(AppModel.isSingleKanji('1'), isFalse);
    });

    test('multi-character terms are never a single kanji', () {
      expect(AppModel.isSingleKanji('言語'), isFalse); // 言語
      expect(AppModel.isSingleKanji('日本'), isFalse); // 日本
      expect(AppModel.isSingleKanji(''), isFalse);
    });
  });
}
