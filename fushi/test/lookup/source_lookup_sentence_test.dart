import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/source_lookup_sentence.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart'
    show SourceLookupHighlight;

/// BUG-3092：查词页制卡卡片没有句子。查词页的结果卡以前把 JS 给的空 `sentence`
/// 原样交给制卡，源文本条上明明有用户输入的整句，Sentence 却恒空。
void main() {
  group('sourceLookupMiningSentence', () {
    test('用户输入整句、高亮在句中某词：取整句作例句', () {
      expect(
        sourceLookupMiningSentence(
          sourceText: '働き手として専用できるような状態に置く',
          highlight: const SourceLookupHighlight(start: 6, length: 2),
          stripRedundant: false,
        ),
        '働き手として専用できるような状態に置く',
      );
    });

    test('源文本多句：只取高亮所在那一句', () {
      expect(
        sourceLookupMiningSentence(
          sourceText: '今日は晴れ。専用の車で行く。明日は雨。',
          highlight: const SourceLookupHighlight(start: 6, length: 2),
          stripRedundant: false,
        ),
        '専用の車で行く。',
      );
    });

    test('高亮下标按字素簇计（代理对 / 组合字符不错位）', () {
      expect(
        sourceLookupMiningSentence(
          sourceText: '𠮷野家だ。専用の席。',
          highlight: const SourceLookupHighlight(start: 5, length: 2),
          stripRedundant: false,
        ),
        '専用の席。',
      );
    });

    test('只查了一个词（源文本条与词头重复）：不造句', () {
      expect(
        sourceLookupMiningSentence(
          sourceText: '専用',
          highlight: const SourceLookupHighlight(start: 0, length: 2),
          stripRedundant: true,
        ),
        '',
      );
    });

    test('源文本为空：不造句', () {
      expect(
        sourceLookupMiningSentence(
          sourceText: '  ',
          highlight: null,
          stripRedundant: false,
        ),
        '',
      );
    });

    test('没有高亮：整段当一句', () {
      expect(
        sourceLookupMiningSentence(
          sourceText: ' 状態に置く ',
          highlight: null,
          stripRedundant: false,
        ),
        '状態に置く',
      );
    });
  });

  group('withFallbackMiningSentence', () {
    test('JS 没带例句时补上', () {
      final Map<String, String> out = withFallbackMiningSentence(
        <String, String>{'expression': '専用', 'sentence': ''},
        '専用の車。',
      );
      expect(out['sentence'], '専用の車。');
      expect(out['expression'], '専用');
    });

    test('JS 已带例句时不覆盖', () {
      final Map<String, String> fields = <String, String>{'sentence': '原句。'};
      expect(withFallbackMiningSentence(fields, '別の句。'), same(fields));
    });

    test('没有可补的句子时原样返回', () {
      final Map<String, String> fields = <String, String>{'expression': '専用'};
      expect(withFallbackMiningSentence(fields, ''), same(fields));
    });
  });

  test('查词页结果区制卡 / 覆写都经源文本例句补全（接线守卫）', () {
    final String source = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('onMineEntry(_withSourceSentence(fields))'),
      reason: '结果区制卡必须补源文本例句，否则查词页卡片 Sentence 恒空',
    );
    expect(
      source,
      contains('onUpdateEntry(noteId, _withSourceSentence(fields))'),
      reason: '覆写最新卡与新制卡同一口径',
    );
    expect(source, contains('sourceLookupMiningSentence('));
  });
}
