import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

/// BUG-1478 守卫：捕获工作台的查词命中粒度是**字**，不是分词器切出来的词。
///
/// 用户原话：「提前被分好词了。没办法点击单个文字，只能点击单词。」
/// 分词只该决定看起来怎么断，不该决定点得到什么粒度——「永遠」整体一个 InkWell 时，
/// 想单独查「遠」无从下手。
///
/// 为什么是源码扫描而不是 widget 行为测试：正文的命中要靠真实 hit-test + WebView
/// 查词浮层，宿主里 `DictionaryPopupWebView` 渲染空盒、不进手势竞技场
/// （`texthooker_page_test.dart` 里所有 tap 都打在工具栏图标上，正是这个原因）。
/// 这里钉的是**接线**：命中按字素簇建、查询串从该字起算、词首偏移不靠搜索。
void main() {
  late String page;

  setUpAll(() {
    page = File('lib/src/pages/implementations/texthooker_page.dart')
        .readAsStringSync();
  });

  test('命中区按字素簇逐个建，不是整词一个', () {
    final String masked = maskComments(page);
    expect(masked.contains('for (final String grapheme in word.characters)'),
        isTrue,
        reason: '必须按字素簇切——用 UTF-16 code unit 会劈开代理对/浊点/组合字');
    expect(masked.contains('class _CharSpan'), isTrue,
        reason: '单字命中区必须是独立 widget，整词一个 InkWell 就退回原状了');
  });

  test('查询串从命中的那个字起算，交给引擎最长匹配', () {
    final String body = methodBody(
      page,
      'void _onCharTap(\n    TexthookerLineEntry line,\n    int charIndex,\n    Rect rect,\n  )',
    );
    expect(body.contains('text.substring(charIndex, end)'), isTrue,
        reason: '查询串必须从命中字起算；传分词器切的那个词就等于没修');
    expect(body.contains('_kLookupQueryMaxChars'), isTrue,
        reason: '必须截断，别把整行喂给引擎');
  });

  test('词首偏移按前缀长度累加，不在原文里搜索', () {
    final String masked = maskComments(page);
    expect(masked.contains('offset += word.length'), isTrue);
    expect(
      masked.contains('text.indexOf(word)'),
      isFalse,
      reason: '搜索会在重复词上给出错误位置——同一句里出现两次的词必然定位到第一处',
    );
  });

  test('顶层查词仍复用热槽（BUG-1028 不得被本次改动带坏）', () {
    expect(maskComments(page).contains('reuseWarmSlot: true'), isTrue);
  });
}
