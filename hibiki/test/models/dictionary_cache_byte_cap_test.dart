// 查词缓存字节封顶接线守卫。
//
// 背景：`DictionaryRepository` 的两个查词缓存原先只按条数（2000）封顶，
// 单条 DictionarySearchResult 含 popupJson 实测 54-231KB，长会话可涨到
// 几百 MB 常驻，且 lowMemoryMode 不缩它们。现在两缓存带估算字节上限
// （32MB / 低内存 8MB，条数兜底保留），本文件守住三件事：
// 1. 顶层估算函数的口径（popupJson×2 是大头、宁可高估、单调）；
// 2. 仓库两缓存真的按字节淘汰，且 lowMemory 信号运行期翻转即生效；
// 3. app_model.dart 的两个构造点都接了 isLowMemory（源码扫描——AppModel
//    初始化链路挂着真实 FFI/文件系统，widget 测试无法整链构造）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/models/dictionary_repository.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

/// 造一条估算体积由 [popupJsonChars] 主导的搜索结果（估算 ≈ 2×chars）。
DictionarySearchResult _bigSearchResult(String term, int popupJsonChars) {
  final DictionarySearchResult result = DictionarySearchResult(
    searchTerm: term,
    entries: [DictionaryEntry(word: term, meaning: 'meaning')],
    bestLength: term.length,
  );
  result.popupJson = 'j' * popupJsonChars;
  return result;
}

/// 造一条估算体积由 glossary 字符串主导的 FFI 查词结果。
List<FushiLookupResult> _bigFfiResults(String term, int glossaryChars) {
  return [
    FushiLookupResult(
      matched: term,
      deinflected: term,
      trace: const [],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: term,
        reading: term,
        rules: '',
        glossaries: [
          FushiGlossaryEntry(
            dictName: 'test',
            glossary: 'g' * glossaryChars,
            definitionTags: '',
            termTags: '',
          ),
        ],
        frequencies: const [],
        pitches: const [],
      ),
    ),
  ];
}

void main() {
  group('size estimators', () {
    test(
        'estimateDictionarySearchResultBytes counts popupJson at 2 bytes '
        'per UTF-16 code unit', () {
      final DictionarySearchResult without = _bigSearchResult('猫', 0)
        ..popupJson = null;
      final DictionarySearchResult with100k = _bigSearchResult('猫', 100000);
      final int delta = estimateDictionarySearchResultBytes(with100k) -
          estimateDictionarySearchResultBytes(without);
      expect(delta, 200000, reason: 'popupJson 是缓存大头，必须按 UTF-16 每字符 2 字节精确计入');
      expect(estimateDictionarySearchResultBytes(with100k),
          greaterThanOrEqualTo(200000));
    });

    test(
        'estimateDictionarySearchResultBytes counts entries and kanji '
        'results and never returns a trivial size', () {
      final DictionarySearchResult result = DictionarySearchResult(
        searchTerm: '猫',
        entries: [
          DictionaryEntry(word: '猫', reading: 'ねこ', meaning: 'x' * 500),
        ],
        kanjiResults: const [
          FushiKanjiResult(
            character: '猫',
            onyomi: 'ビョウ',
            kunyomi: 'ねこ',
            radical: '犭',
            strokes: 11,
            meanings: ['cat'],
            dictName: 'kanjidic',
          ),
        ],
      );
      // meaning 500 字符 ×2 = 1000 字节起步，加对象开销必须只多不少。
      expect(estimateDictionarySearchResultBytes(result),
          greaterThanOrEqualTo(1000));
    });

    test(
        'estimateFushiLookupResultsBytes counts glossary strings at 2 bytes '
        'per code unit', () {
      final int small = estimateFushiLookupResultsBytes(_bigFfiResults('a', 0));
      final int big =
          estimateFushiLookupResultsBytes(_bigFfiResults('a', 100000));
      expect(big - small, 200000);
      expect(estimateFushiLookupResultsBytes(const []), greaterThan(0),
          reason: '空列表也有列表本身的开销，估算恒为正');
    });
  });

  group('DictionaryRepository byte-capped caches', () {
    late HibikiDatabase db;

    setUp(() {
      db = _testDb();
    });

    tearDown(() async {
      await db.close();
    });

    // 低内存上限 8MB；每条 popupJson 3M 字符 → 估算 ≈ 6MB：单条可驻留，
    // 两条 12MB 必超限 → 最旧的被淘汰。
    const int bigChars = 3 * 1000 * 1000;

    test('low-memory mode caps the search cache at 8MB (oldest evicted)', () {
      final DictionaryRepository repo =
          DictionaryRepository(db, isLowMemory: () => true);
      repo.cacheSearchResult('a', _bigSearchResult('a', bigChars));
      expect(repo.getCachedSearch('a'), isNotNull);
      repo.cacheSearchResult('b', _bigSearchResult('b', bigChars));
      expect(repo.getCachedSearch('a'), isNull,
          reason: '低内存 8MB 上限下两条 6MB 结果放不下，最旧的必须被淘汰');
      expect(repo.getCachedSearch('b'), isNotNull);
      repo.dispose();
    });

    test('normal mode keeps the same two results (32MB cap)', () {
      final DictionaryRepository repo =
          DictionaryRepository(db, isLowMemory: () => false);
      repo.cacheSearchResult('a', _bigSearchResult('a', bigChars));
      repo.cacheSearchResult('b', _bigSearchResult('b', bigChars));
      expect(repo.getCachedSearch('a'), isNotNull);
      expect(repo.getCachedSearch('b'), isNotNull);
      repo.dispose();
    });

    test('low-memory mode caps the ffi lookup cache at 8MB', () {
      final DictionaryRepository repo =
          DictionaryRepository(db, isLowMemory: () => true);
      repo.cacheFfiLookup('a', _bigFfiResults('a', bigChars));
      expect(repo.getCachedFfiLookup('a'), isNotNull);
      repo.cacheFfiLookup('b', _bigFfiResults('b', bigChars));
      expect(repo.getCachedFfiLookup('a'), isNull);
      expect(repo.getCachedFfiLookup('b'), isNotNull);
      repo.dispose();
    });

    test('normal mode keeps both ffi lookup results', () {
      final DictionaryRepository repo =
          DictionaryRepository(db, isLowMemory: () => false);
      repo.cacheFfiLookup('a', _bigFfiResults('a', bigChars));
      repo.cacheFfiLookup('b', _bigFfiResults('b', bigChars));
      expect(repo.getCachedFfiLookup('a'), isNotNull);
      expect(repo.getCachedFfiLookup('b'), isNotNull);
      repo.dispose();
    });

    test('flipping low-memory at runtime shrinks on the next cache write', () {
      bool lowMemory = false;
      final DictionaryRepository repo =
          DictionaryRepository(db, isLowMemory: () => lowMemory);
      repo.cacheSearchResult('a', _bigSearchResult('a', bigChars));
      repo.cacheSearchResult('b', _bigSearchResult('b', bigChars));
      // 32MB 下两条都在。注意 get 会刷新 recency，按 a→b 顺序各读一次，
      // 读完 LRU 顺序仍是 a（最旧）→ b。
      expect(repo.getCachedSearch('a'), isNotNull);
      expect(repo.getCachedSearch('b'), isNotNull);
      lowMemory = true;
      repo.cacheSearchResult('c', _bigSearchResult('c', 100));
      // 下一次写入即应用 8MB：a 被淘汰；b（6MB）+ c（小）still ≤ 8MB。
      expect(repo.getCachedSearch('a'), isNull,
          reason: '低内存开关翻转后，下一次缓存写入必须立即按 8MB 收缩');
      expect(repo.getCachedSearch('b'), isNotNull);
      expect(repo.getCachedSearch('c'), isNotNull);
      repo.dispose();
    });

    test(
        'clearDictionaryResultsCache still empties both caches '
        '(BUG-171/BUG-177 clear semantics unchanged)', () {
      final DictionaryRepository repo =
          DictionaryRepository(db, isLowMemory: () => false);
      repo.cacheSearchResult('a', _bigSearchResult('a', 100));
      repo.cacheFfiLookup('a', _bigFfiResults('a', 100));
      repo.clearDictionaryResultsCache();
      expect(repo.getCachedSearch('a'), isNull);
      expect(repo.getCachedFfiLookup('a'), isNull);
      // clear 后记账归零：再次写入仍能正常驻留。
      repo.cacheSearchResult('b', _bigSearchResult('b', 100));
      expect(repo.getCachedSearch('b'), isNotNull);
      repo.dispose();
    });
  });

  group('app_model wiring guard (source scan)', () {
    // AppModel 的初始化链路挂着真实 FFI 引擎 + 文件系统，flutter_test 无法
    // 整链构造；最强可落地守卫是源码扫描：两个 DictionaryRepository 构造点
    // （主进程 initialise + :popup 进程 initialiseForDictionaryPopup）都必须
    // 接 isLowMemory，否则低内存模式永远拿不到 8MB 上限。
    test('both DictionaryRepository construction sites pass isLowMemory', () {
      final File f = File('lib/src/models/app_model.dart');
      expect(f.existsSync(), isTrue,
          reason: 'app_model.dart not found at ${f.absolute.path}');
      final String src = f.readAsStringSync();

      const String marker = 'DictionaryRepository(';
      int found = 0;
      int from = 0;
      while (true) {
        final int at = src.indexOf(marker, from);
        if (at < 0) break;
        // 跳过 import/注释里的出现：只统计 `DictionaryRepository(` 后真正的
        // 构造实参段（到配对右括号为止的窗口，用 300 字符窗口近似即可）。
        final String window =
            src.substring(at, (at + 300).clamp(0, src.length));
        if (window.contains('_database')) {
          found++;
          expect(window.contains('isLowMemory'), isTrue,
              reason: '第 $found 个 DictionaryRepository 构造点未接 isLowMemory，'
                  '低内存模式将无法收缩查词缓存（32MB→8MB）');
        }
        from = at + marker.length;
      }
      expect(found, 2,
          reason: 'app_model.dart 应有主进程 + popup 进程两个构造点；数量变化'
              '时请同步更新本守卫');
    });
  });
}
