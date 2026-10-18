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

  // 弹窗 JSON 的空读音分组（BUG-791 / BUG-2753 的 popup 一侧）由原生 build_popup_json
  // 负责：native/fushidicts/tests/popup_json_reading_merge_test.cpp 与
  // popup_json_options_test.cpp。这里只守 buildResultFromLookup 一侧（制卡 / 音频 /
  // buildLookupEntriesJson 读 entry.reading）。

  // BUG-2753：MDX / StarDict / DSL 导入时读音恒空。同表记只有一个显式读音时，
  // 空读音行并入该读音组；多个读音时不猜（上面辛い那条守住）。
  group(
    'empty-reading simple dict merges into the sole reading (BUG-2753)',
    () {
      List<FushiLookupResult> torimodosu({bool mdxFirst = false}) {
        final yomitan = makeResult(
          expression: '取り戻す',
          reading: 'とりもどす',
          dictName: 'JMdict',
          gloss: 'to take back',
        );
        final mdx = [
          makeResult(
            expression: '取り戻す',
            reading: '',
            dictName: '大辞林MDX',
            gloss: '<b>とりもどす</b>',
          ),
          makeResult(
            expression: '取り戻す',
            reading: '',
            dictName: '新明解MDX',
            gloss: '<b>とりもどす</b>',
          ),
        ];
        return mdxFirst ? [...mdx, yomitan] : [yomitan, ...mdx];
      }

      test('buildResultFromLookup：同一个词头，MDX entry 读音补全', () {
        final r = buildResultFromLookup(
          searchTerm: '取り戻す',
          results: torimodosu(),
          maximumTerms: 1,
        );
        expect(r.headwordCount, 1, reason: '合并后只占一个词头预算');
        expect(r.truncated, isFalse);
        expect(r.entries.length, 3);
        expect(r.entries.map((e) => e.reading).toSet(), {
          'とりもどす',
        }, reason: 'buildLookupEntriesJson / 制卡 / 音频都读 entry.reading');
      });

      test('多读音时 buildResultFromLookup 不给空读音 entry 猜读音', () {
        final r = buildResultFromLookup(
          searchTerm: '辛い',
          results: [
            makeResult(
              expression: '辛い',
              reading: 'つらい',
              dictName: 'A',
              gloss: 'a',
            ),
            makeResult(
              expression: '辛い',
              reading: 'からい',
              dictName: 'B',
              gloss: 'b',
            ),
            makeResult(
              expression: '辛い',
              reading: '',
              dictName: 'C',
              gloss: 'c',
            ),
          ],
          maximumTerms: 100,
        );
        expect(r.headwordCount, 3);
        expect(
          r.entries.singleWhere((e) => e.dictionaryName == 'C').reading,
          '',
        );
      });
    },
  );
}
