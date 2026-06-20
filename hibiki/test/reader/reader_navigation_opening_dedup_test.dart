import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// 源码守卫：阅读器三个导航入口的「代际 token + restore completer + 初始锚点字段 +
/// fragment + restoreInFlight + setState 清 ready + 启动超时」开场白，以及失败收尾，
/// 只各有一份（[_beginNavigation] / [_failNavigation]），三方法都转调，不再逐字复制
/// 14 行开场白（任一改动要三处同步，否则导航/恢复代际状态机漂移）。
void main() {
  final String src = readReaderPageSource();

  group('阅读器导航开场白/失败收尾单一真相', () {
    test('_beginNavigation / _failNavigation helper 定义存在', () {
      expect(src, contains('void _beginNavigation('),
          reason: '导航开场白应收口成 _beginNavigation');
      expect(src, contains('void _failNavigation('),
          reason: '导航失败收尾应收口成 _failNavigation');
      // 代际 token 递增只在 helper 里（+ 一处无关的非章节导航路径）；不再被三个章节/
      // spread 导航各复制一遍。
      final int genBumps = '++_navigateGeneration'.allMatches(src).length;
      expect(genBumps, lessThanOrEqualTo(2),
          reason: '++_navigateGeneration 不应再在三个导航方法里各出现一次');
    });

    test('三个导航入口都转调 _beginNavigation + _failNavigation', () {
      final int beginCalls =
          RegExp(r'_beginNavigation\(\n').allMatches(src).length;
      expect(beginCalls, greaterThanOrEqualTo(3),
          reason: 'chapter/spread/withFragment 三入口都应调 _beginNavigation');
      final int failCalls = '_failNavigation();'.allMatches(src).length;
      expect(failCalls, greaterThanOrEqualTo(3),
          reason: '三入口的 catch 都应调 _failNavigation');
    });

    test(
        'chapter 仍单独镜像 charOffset 进 _lastProgressCharOffset（spread/fragment 不设）',
        () {
      // _navigateToChapter 的专属行为：把锚点 charOffset 记进待落库进度，不能被并进
      // helper（否则 spread/fragment 会误写该字段）。
      expect(src, contains('_lastProgressCharOffset = _initialCharOffset;'),
          reason: 'chapter 导航必须保留 charOffset→lastProgressCharOffset 镜像');
    });
  });
}
