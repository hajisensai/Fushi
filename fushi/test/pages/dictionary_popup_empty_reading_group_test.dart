import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-791 守卫：查词弹窗按「表记 + 读音」分组时，空读音必须按 Yomitan
/// 约定归一为「读音同表记」，否则同一个假名词（一部分词典给显式读音、一部分
/// 留空读音）会被拆成两张 headword 卡。
///
/// 同时守住边界：汉字多读音词的空读音**不能**被硬塞进任一真读音组。
void main() {
  FushiLookupResult makeResult({
    required String expression,
    required String reading,
    required String dictName,
    required String gloss,
  }) {
    return FushiLookupResult(
      matched: expression,
      deinflected: expression,
      trace: const [],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: expression,
        reading: reading,
        rules: '',
        glossaries: [
          FushiGlossaryEntry(
            dictName: dictName,
            glossary: jsonEncode(gloss),
            definitionTags: '',
            termTags: '',
          ),
        ],
        frequencies: const [],
        pitches: const [],
      ),
    );
  }

  List<Map<String, dynamic>> groups(List<FushiLookupResult> results) {
    final json = buildPopupJsonFromLookup(
        results: results,
        maximumTerms: 100,
        hiddenDictionaries: const <String>{});
    return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
  }

  group('buildPopupJsonFromLookup empty-reading grouping (BUG-791)', () {
    test('假名词：显式读音与空读音合成一张卡', () {
      // 「それだけ」：明鏡给 reading=それだけ，小学館日中辞典 reading 留空。
      final result = groups([
        makeResult(
          expression: 'それだけ',
          reading: 'それだけ',
          dictName: '明鏡日汉双解辞典',
          gloss: 'その程度に応じて。',
        ),
        makeResult(
          expression: 'それだけ',
          reading: '',
          dictName: '小学館日中辞典v3',
          gloss: '唯独，唯一。',
        ),
      ]);

      expect(result.length, 1, reason: '空读音应归一到表记，与显式读音合成同一张 headword 卡');
      final gloss = result.single['glossaries'] as List;
      expect(gloss.length, 2, reason: '两本词典的释义都进这张卡');
    });

    test('两条都是空读音的假名词也只有一张卡', () {
      final result = groups([
        makeResult(
          expression: 'それだけ',
          reading: '',
          dictName: 'A辞典',
          gloss: 'a',
        ),
        makeResult(
          expression: 'それだけ',
          reading: '',
          dictName: 'B辞典',
          gloss: 'b',
        ),
      ]);
      expect(result.length, 1);
    });

    test('汉字多读音 + 空读音：空读音不被塞进任一真读音组', () {
      // 辛い＝つらい／からい，外加一条空读音。空读音归一到表记「辛い」，
      // 不等于 つらい 也不等于 からい → 自成第三组，绝不污染真读音。
      final result = groups([
        makeResult(
          expression: '辛い',
          reading: 'つらい',
          dictName: 'A',
          gloss: 'painful',
        ),
        makeResult(
          expression: '辛い',
          reading: 'からい',
          dictName: 'B',
          gloss: 'spicy',
        ),
        makeResult(
          expression: '辛い',
          reading: '',
          dictName: 'C',
          gloss: 'blank-reading entry',
        ),
      ]);

      expect(result.length, 3, reason: '两个真读音各一组，空读音自成一组，互不合并');
      final tsurai = result.firstWhere((g) => g['reading'] == 'つらい');
      final karai = result.firstWhere((g) => g['reading'] == 'からい');
      expect((tsurai['glossaries'] as List).length, 1,
          reason: 'つらい 组不能被空读音条目污染');
      expect((karai['glossaries'] as List).length, 1,
          reason: 'からい 组不能被空读音条目污染');
    });
  });
}
