import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-1472 守卫：`maximumTerms` 的单位是**词头**（表记 + 读音），不是 glossary 注释行。
///
/// 引擎侧一直把这个数字当词头数上限用（lookup.cpp 的 max_results），Dart 侧两个结果
/// 构造函数却拿同一个数字去数注释行。而 query.cpp 会把**不同词典**的同一个
/// (expression, reading) 合并成一个 TermResult + N 条 glossary，于是一个高频词头
/// （装了几本词典就有几条注释）一个人就能吃满整个上限——排在它后面的其它读音连
/// 循环体都进不去。
///
/// 用户现场：查「永遠」永远只出 えいえん，никогда 不出 とわ / とこしえ。
/// 频率排序（lookup.cpp 的比较器）保证 えいえん 一定排在最前，所以这不是偶发。
void main() {
  FushiLookupResult makeResult({
    required String expression,
    required String reading,
    required List<String> dictNames,
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
        glossaries: <FushiGlossaryEntry>[
          for (final String dict in dictNames)
            FushiGlossaryEntry(
              dictName: dict,
              glossary: jsonEncode('$dict の $expression【$reading】'),
              definitionTags: '',
              termTags: '',
            ),
        ],
        frequencies: const [],
        pitches: const [],
      ),
    );
  }

  /// 「永遠」的真实形状：えいえん 是高频读音、被一堆词典收录；とわ / とこしえ 是
  /// 同表记的另外两个读音，各只有一本词典收。
  List<FushiLookupResult> eienFixture() => <FushiLookupResult>[
        makeResult(
          expression: '永遠',
          reading: 'えいえん',
          dictNames: const <String>[
            '明鏡国語辞典',
            '大辞林',
            '広辞苑',
            '新明解国語辞典',
            'デジタル大辞泉',
            '日中辞典',
            'JMdict',
            '研究社新和英',
            '三省堂国語辞典',
            '岩波国語辞典',
            '旺文社国語辞典',
            '学研国語大辞典',
          ],
        ),
        makeResult(
          expression: '永遠',
          reading: 'とわ',
          dictNames: const <String>['大辞林'],
        ),
        makeResult(
          expression: '永遠',
          reading: 'とこしえ',
          dictNames: const <String>['大辞林'],
        ),
      ];

  Set<String> readingsOf(List<DictionaryEntry> entries) =>
      entries.map((DictionaryEntry e) => e.reading).toSet();

  group('buildResultFromLookup：预算按词头计，不按 glossary 行计（BUG-1472）', () {
    test('高频读音的十几条注释不得吃掉其它读音的名额', () {
      // 默认上限就是 10（preferences_repository.dart），而 えいえん 一个词头带 12 条
      // 注释——按行计预算时第 10 行就 break outer，とわ / とこしえ 一次都轮不到。
      final DictionarySearchResult result = buildResultFromLookup(
        searchTerm: '永遠',
        results: eienFixture(),
        maximumTerms: 10,
      );
      final Set<String> readings = readingsOf(result.entries);
      expect(readings, contains('えいえん'));
      expect(
        readings,
        contains('とわ'),
        reason: '按 glossary 行计预算时，えいえん 的 12 条注释吃满 10 的上限，'
            'とわ 的循环体一次都没进过——这就是「查永遠只出えいえん」的根因',
      );
      expect(readings, contains('とこしえ'));
    });

    test('上限确实还在生效：词头数超上限时截断并显式标记 truncated', () {
      final DictionarySearchResult result = buildResultFromLookup(
        searchTerm: '永遠',
        results: eienFixture(),
        maximumTerms: 2,
      );
      expect(readingsOf(result.entries).length, 2);
      expect(
        result.truncated,
        isTrue,
        reason: '截断是构造结果的人才知道的事实，必须显式带出来；'
            '消费方以前靠 entries.length < maximumTerms 反推，'
            '预算单位一改那个反推就彻底错位',
      );
    });

    test('没被截断时 truncated 为 false', () {
      final DictionarySearchResult result = buildResultFromLookup(
        searchTerm: '永遠',
        results: eienFixture(),
        maximumTerms: 10,
      );
      expect(result.truncated, isFalse);
    });

    test('同一个词头的全部注释都保留，不因预算被腰斩', () {
      final DictionarySearchResult result = buildResultFromLookup(
        searchTerm: '永遠',
        results: eienFixture(),
        maximumTerms: 10,
      );
      final int eienGlossaries = result.entries
          .where((DictionaryEntry e) => e.reading == 'えいえん')
          .length;
      expect(eienGlossaries, 12);
    });
  });

  group('buildPopupJsonFromLookup：同一处预算语义（BUG-1472）', () {
    List<Map<String, dynamic>> groups(
      List<FushiLookupResult> results,
      int maximumTerms,
    ) {
      final String json = buildPopupJsonFromLookup(
          results: results,
          maximumTerms: maximumTerms,
          hiddenDictionaries: const <String>{});
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    }

    test('弹窗侧同样必须出全三个读音', () {
      final List<Map<String, dynamic>> cards = groups(eienFixture(), 10);
      final Set<String> readings =
          cards.map((Map<String, dynamic> c) => c['reading'] as String).toSet();
      expect(readings, containsAll(<String>['えいえん', 'とわ', 'とこしえ']));
    });

    test('上限仍然截断词头数', () {
      expect(groups(eienFixture(), 2).length, 2);
    });
  });
}
