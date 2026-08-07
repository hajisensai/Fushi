import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

/// BUG-712 P2：数一数整表历史重写的真实次数，让 debounce 用例能断言
/// 「N 次连续变更 → 恰好 1 次 DB 写」，而不是只从时序侧面猜。
class _CountingDb extends HibikiDatabase {
  _CountingDb() : super.forTesting(DatabaseConnection(NativeDatabase.memory()));

  int replaceAllCalls = 0;

  @override
  Future<void> replaceAllDictionaryHistory(
      List<DictionaryHistoryCompanion> items) {
    replaceAllCalls++;
    return super.replaceAllDictionaryHistory(items);
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

Dictionary _dict({
  String name = 'JMdict',
  String formatKey = 'yomichan',
  int order = 0,
  DictionaryType type = DictionaryType.term,
  Map<String, String> metadata = const {},
  List<String> hiddenLanguages = const [],
  List<String> collapsedLanguages = const [],
}) {
  return Dictionary(
    name: name,
    formatKey: formatKey,
    order: order,
    type: type,
    metadata: metadata,
    hiddenLanguages: hiddenLanguages,
    collapsedLanguages: collapsedLanguages,
  );
}

DictionarySearchResult _result({
  String searchTerm = '猫',
  int scrollPosition = 0,
}) {
  return DictionarySearchResult(
    searchTerm: searchTerm,
    entries: [DictionaryEntry(word: searchTerm, meaning: 'cat')],
    bestLength: searchTerm.length,
    scrollPosition: scrollPosition,
  );
}

void main() {
  late HibikiDatabase db;
  late DictionaryRepository repo;
  int rebuildCount = 0;

  setUp(() async {
    db = _testDb();
    rebuildCount = 0;
    repo = DictionaryRepository(db, onCacheRebuild: () => rebuildCount++);
    await repo.loadFromDb();
  });

  tearDown(() async {
    await _settle();
    repo.dispose();
    await db.close();
  });

  // ── loadFromDb ───────────────────────────────────────────────────────

  group('loadFromDb', () {
    test('empty DB yields empty caches', () {
      expect(repo.dictionaries, isEmpty);
      expect(repo.dictionaryHistory, isEmpty);
    });

    test('loads dictionary metadata from DB sorted by order', () async {
      repo.persistDictionary(_dict(name: 'B', order: 2));
      repo.persistDictionary(_dict(name: 'A', order: 1));
      await _settle();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaries.map((d) => d.name), ['A', 'B']);
      repo2.dispose();
    });

    test('loads dictionary history from DB', () async {
      repo.addHistoryResult(_result(searchTerm: '猫'), 10);
      // BUG-712 P2：历史落库是 debounce 写穿，50ms 的 _settle 等不到 300ms
      // 的 trailing timer；显式 flush 使该用例确定性成立。
      await repo.flushDictionaryHistoryNow();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaryHistory.length, 1);
      expect(repo2.dictionaryHistory.first.searchTerm, '猫');
      repo2.dispose();
    });
  });

  // ── dictionary getters ───────────────────────────────────────────────

  group('dictionary getters', () {
    test('termDictionaries filters by term type', () {
      repo.persistDictionary(
          _dict(name: 'term1', type: DictionaryType.term, order: 0));
      repo.persistDictionary(
          _dict(name: 'freq1', type: DictionaryType.frequency, order: 1));
      expect(repo.termDictionaries.length, 1);
      expect(repo.termDictionaries.first.name, 'term1');
    });

    test('freqDictionaries filters by frequency type', () {
      repo.persistDictionary(
          _dict(name: 'freq1', type: DictionaryType.frequency, order: 0));
      repo.persistDictionary(
          _dict(name: 'term1', type: DictionaryType.term, order: 1));
      expect(repo.freqDictionaries.length, 1);
      expect(repo.freqDictionaries.first.name, 'freq1');
    });

    test('pitchDictionaries filters by pitch type', () {
      repo.persistDictionary(
          _dict(name: 'p1', type: DictionaryType.pitch, order: 0));
      expect(repo.pitchDictionaries.length, 1);
    });

    test('kanjiDictionaries filters by kanji type', () {
      repo.persistDictionary(
          _dict(name: 'k1', type: DictionaryType.kanji, order: 0));
      expect(repo.kanjiDictionaries.length, 1);
    });

    test('dictionaries list is unmodifiable', () {
      repo.persistDictionary(_dict());
      expect(() => repo.dictionaries.add(_dict(name: 'x')),
          throwsUnsupportedError);
    });

    test('dictionaryHistory list is unmodifiable', () {
      repo.addHistoryResult(_result(), 10);
      expect(
        () => repo.dictionaryHistory.add(_result(searchTerm: 'x')),
        throwsUnsupportedError,
      );
    });
  });

  // ── persistDictionary ────────────────────────────────────────────────

  group('persistDictionary', () {
    test('adds new dictionary to cache sorted by order', () {
      repo.persistDictionary(_dict(name: 'B', order: 2));
      repo.persistDictionary(_dict(name: 'A', order: 1));
      expect(repo.dictionaries.map((d) => d.name), ['A', 'B']);
    });

    test('updates existing dictionary in cache by name', () {
      repo.persistDictionary(_dict(name: 'X', order: 0, metadata: {'v': '1'}));
      repo.persistDictionary(_dict(name: 'X', order: 0, metadata: {'v': '2'}));
      expect(repo.dictionaries.length, 1);
      expect(repo.dictionaries.first.metadata['v'], '2');
    });

    test('calls onCacheRebuild callback', () {
      repo.persistDictionary(_dict());
      expect(rebuildCount, 1);
    });

    test('persists to DB', () async {
      repo.persistDictionary(_dict(name: 'Test'));
      await _settle();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaries.length, 1);
      expect(repo2.dictionaries.first.name, 'Test');
      repo2.dispose();
    });
  });

  // ── updateDictionaryOrder ────────────────────────────────────────────

  group('updateDictionaryOrder', () {
    test('reorders dictionaries in cache', () {
      repo.persistDictionary(_dict(name: 'A', order: 0));
      repo.persistDictionary(_dict(name: 'B', order: 1));
      rebuildCount = 0;

      repo.updateDictionaryOrder([
        _dict(name: 'B', order: 0),
        _dict(name: 'A', order: 1),
      ]);

      expect(repo.dictionaries.map((d) => d.name), ['B', 'A']);
      expect(rebuildCount, 1);
    });

    test('persists new order to DB', () async {
      repo.persistDictionary(_dict(name: 'A', order: 0));
      repo.persistDictionary(_dict(name: 'B', order: 1));
      await _settle();

      repo.updateDictionaryOrder([
        _dict(name: 'B', order: 0),
        _dict(name: 'A', order: 1),
      ]);
      await _settle();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaries.map((d) => d.name), ['B', 'A']);
      repo2.dispose();
    });

    test('clears stale search caches so next lookup re-merges (BUG-355)', () {
      // Reordering changes the effective merge order of lookup results, so a
      // result cached under the old order must not survive — otherwise the next
      // (cache-hit) query replays the stale order until the app restarts.
      repo.persistDictionary(_dict(name: 'A', order: 0));
      repo.persistDictionary(_dict(name: 'B', order: 1));
      repo.cacheSearchResult('猫', _result(searchTerm: '猫'));
      repo.cacheFfiLookup('猫', const []);
      expect(repo.getCachedSearch('猫'), isNotNull);
      expect(repo.getCachedFfiLookup('猫'), isNotNull);

      repo.updateDictionaryOrder([
        _dict(name: 'B', order: 0),
        _dict(name: 'A', order: 1),
      ]);

      expect(repo.getCachedSearch('猫'), isNull);
      expect(repo.getCachedFfiLookup('猫'), isNull);
    });
  });

  // ── toggleDictionaryCollapsed / Hidden ───────────────────────────────

  group('toggleDictionaryCollapsed', () {
    test('adds language code when not collapsed', () {
      final d = _dict(name: 'D');
      repo.persistDictionary(d);
      repo.toggleDictionaryCollapsed(d, 'ja');
      expect(
        repo.dictionaries.first.collapsedLanguages,
        contains('ja'),
      );
    });

    test('removes language code when already collapsed', () {
      final d = _dict(name: 'D', collapsedLanguages: ['ja']);
      repo.persistDictionary(d);
      repo.toggleDictionaryCollapsed(d, 'ja');
      expect(
        repo.dictionaries.first.collapsedLanguages,
        isNot(contains('ja')),
      );
    });
  });

  group('toggleDictionaryHidden', () {
    test('adds language code when not hidden', () {
      final d = _dict(name: 'D');
      repo.persistDictionary(d);
      repo.toggleDictionaryHidden(d, 'en');
      expect(
        repo.dictionaries.first.hiddenLanguages,
        contains('en'),
      );
    });

    test('removes language code when already hidden', () {
      final d = _dict(name: 'D', hiddenLanguages: ['en']);
      repo.persistDictionary(d);
      repo.toggleDictionaryHidden(d, 'en');
      expect(
        repo.dictionaries.first.hiddenLanguages,
        isNot(contains('en')),
      );
    });
  });

  // ── hasDictionaryNamed / remove / clear ──────────────────────────────

  group('cache helpers', () {
    test('hasDictionaryNamed returns true when present', () {
      repo.persistDictionary(_dict(name: 'Test'));
      expect(repo.hasDictionaryNamed('Test'), true);
      expect(repo.hasDictionaryNamed('Other'), false);
    });

    test('removeDictionaryFromCache removes by name', () {
      repo.persistDictionary(_dict(name: 'A'));
      repo.persistDictionary(_dict(name: 'B', order: 1));
      repo.removeDictionaryFromCache('A');
      expect(repo.dictionaries.length, 1);
      expect(repo.dictionaries.first.name, 'B');
    });

    test('clearDictionariesCache empties the cache', () {
      repo.persistDictionary(_dict(name: 'A'));
      repo.persistDictionary(_dict(name: 'B', order: 1));
      repo.clearDictionariesCache();
      expect(repo.dictionaries, isEmpty);
    });
  });

  // ── search cache ─────────────────────────────────────────────────────

  group('search cache', () {
    test('getCachedSearch returns null for missing key', () {
      expect(repo.getCachedSearch('missing'), isNull);
    });

    test('cacheSearchResult stores and retrieves result', () {
      final result = _result(searchTerm: '犬');
      repo.cacheSearchResult('犬/10/100', result);
      expect(repo.getCachedSearch('犬/10/100')?.searchTerm, '犬');
    });

    test('getCachedFfiLookup returns null for missing key', () {
      expect(repo.getCachedFfiLookup('missing'), isNull);
    });

    test('cacheFfiLookup stores and retrieves results', () {
      repo.cacheFfiLookup('猫', []);
      expect(repo.getCachedFfiLookup('猫'), isNotNull);
      expect(repo.getCachedFfiLookup('猫'), isEmpty);
    });

    test('clearDictionaryResultsCache clears both caches', () {
      repo.cacheSearchResult('key', _result());
      repo.cacheFfiLookup('term', []);
      repo.clearDictionaryResultsCache();
      expect(repo.getCachedSearch('key'), isNull);
      expect(repo.getCachedFfiLookup('term'), isNull);
    });
  });

  // ── dictionary history ───────────────────────────────────────────────

  group('dictionary history', () {
    test('addHistoryResult adds to end of history', () {
      repo.addHistoryResult(_result(searchTerm: 'a'), 10);
      repo.addHistoryResult(_result(searchTerm: 'b'), 10);
      expect(
        repo.dictionaryHistory.map((r) => r.searchTerm),
        ['a', 'b'],
      );
    });

    test('addHistoryResult deduplicates by searchTerm', () {
      repo.addHistoryResult(_result(searchTerm: 'a'), 10);
      repo.addHistoryResult(_result(searchTerm: 'b'), 10);
      repo.addHistoryResult(_result(searchTerm: 'a'), 10);
      expect(
        repo.dictionaryHistory.map((r) => r.searchTerm),
        ['b', 'a'],
      );
    });

    test('addHistoryResult trims oldest when exceeding max', () {
      repo.addHistoryResult(_result(searchTerm: 'a'), 2);
      repo.addHistoryResult(_result(searchTerm: 'b'), 2);
      repo.addHistoryResult(_result(searchTerm: 'c'), 2);
      expect(
        repo.dictionaryHistory.map((r) => r.searchTerm),
        ['b', 'c'],
      );
    });

    test('addHistoryResult skips empty entries', () {
      final empty = DictionarySearchResult(searchTerm: '猫');
      repo.addHistoryResult(empty, 10);
      expect(repo.dictionaryHistory, isEmpty);
    });

    test('addHistoryResult skips empty searchTerm', () {
      final empty = DictionarySearchResult(
        searchTerm: '',
        entries: [DictionaryEntry(word: 'x')],
      );
      repo.addHistoryResult(empty, 10);
      expect(repo.dictionaryHistory, isEmpty);
    });

    test('addHistoryResult persists to DB', () async {
      repo.addHistoryResult(_result(searchTerm: '犬'), 10);
      // BUG-712 P2：add 只改内存，落库走 debounce；显式 flush 后再验证。
      await repo.flushDictionaryHistoryNow();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaryHistory.length, 1);
      expect(repo2.dictionaryHistory.first.searchTerm, '犬');
      repo2.dispose();
    });

    test('updateDictionaryResultScrollIndex updates in place', () {
      repo.addHistoryResult(_result(searchTerm: '猫', scrollPosition: 0), 10);
      final result = repo.dictionaryHistory.first;
      repo.updateDictionaryResultScrollIndex(result: result, newIndex: 5);
      expect(repo.dictionaryHistory.first.scrollPosition, 5);
    });

    test('clearDictionaryHistory empties history and DB', () async {
      repo.addHistoryResult(_result(searchTerm: '猫'), 10);
      // BUG-712 P2：先真实落库再 clear，保住「DB 里有过这行、clear 删掉它」
      // 的原始意图（debounce 下 _settle 50ms 后 DB 本来就还是空的）。
      await repo.flushDictionaryHistoryNow();
      await repo.clearDictionaryHistory();

      expect(repo.dictionaryHistory, isEmpty);

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaryHistory, isEmpty);
      repo2.dispose();
    });
  });

  // ── history persistence debounce (BUG-712 P2) ────────────────────────

  group('history persistence debounce (BUG-712 P2)', () {
    test('addHistoryResult defers the DB write until flushDictionaryHistoryNow',
        () async {
      // 守回归：查词热路径不得回到「每次 add 同步整表序列化+重写」——add 只改
      // 内存，落库延后；flushDictionaryHistoryNow 把 pending 变更确定性写穿。
      repo.addHistoryResult(_result(searchTerm: '猫'), 10);
      expect(await db.getAllDictionaryHistory(), isEmpty,
          reason: 'add 后立即查 DB 必须为空（未同步落库）');

      await repo.flushDictionaryHistoryNow();
      final rows = await db.getAllDictionaryHistory();
      expect(rows.length, 1);
      expect(
        DictionarySearchResult.fromJson(rows.single.resultJson).searchTerm,
        '猫',
      );
    });

    test('flushDictionaryHistoryNow without pending changes is a no-op',
        () async {
      // 守回归：无 pending 时不得触发整表重写（退出路径/loadFromDb 前置 flush
      // 高频调用，no-op 语义是公开契约）。
      final countingDb = _CountingDb();
      final repo2 = DictionaryRepository(countingDb);
      await repo2.loadFromDb();
      await repo2.flushDictionaryHistoryNow();
      expect(countingDb.replaceAllCalls, 0);
      repo2.dispose();
      await countingDb.close();
    });

    test('burst of adds inside the debounce window lands in a single DB write',
        () async {
      // 守回归：300ms trailing debounce——连续 add 多条只允许一次整表写，
      // 且最终 DB 内容为全量三条（顺序按 position）。
      final countingDb = _CountingDb();
      final repo2 = DictionaryRepository(countingDb);
      await repo2.loadFromDb();

      repo2.addHistoryResult(_result(searchTerm: 'a'), 10);
      repo2.addHistoryResult(_result(searchTerm: 'b'), 10);
      repo2.addHistoryResult(_result(searchTerm: 'c'), 10);
      expect(countingDb.replaceAllCalls, 0, reason: 'debounce 窗口内不得有任何同步落库');

      // 等真实时间越过 300ms 窗口（留余量），trailing timer 恰好触发一次。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(countingDb.replaceAllCalls, 1, reason: '3 次连续变更必须合并为恰好 1 次整表写');
      final rows = await countingDb.getAllDictionaryHistory();
      expect(
        rows.map(
            (r) => DictionarySearchResult.fromJson(r.resultJson).searchTerm),
        ['a', 'b', 'c'],
      );

      repo2.dispose();
      await countingDb.close();
    });

    test('clearDictionaryHistory cancels the pending flush (no resurrection)',
        () async {
      // 守回归：clear 前有 pending add，clear 必须先取消 pending 再删表；
      // 否则旧快照在 debounce 到期后写回，已清历史「复活」。
      repo.addHistoryResult(_result(searchTerm: '猫'), 10);
      await repo.clearDictionaryHistory();
      expect(repo.dictionaryHistory, isEmpty);

      // 越过 debounce 窗口后 DB 仍须为空。
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(await db.getAllDictionaryHistory(), isEmpty,
          reason: 'clear 之后 pending 旧快照不得复活');
    });

    test(
        'scroll index update lands in persisted resultJson (memo invalidation)',
        () async {
      // 守回归：逐条序列化 memo（Expando）在就地改 scrollPosition 后必须失效；
      // 否则第二次 flush 复用 stale JSON，滚动位置永远停在旧值。
      repo.addHistoryResult(_result(searchTerm: '猫', scrollPosition: 0), 10);
      await repo.flushDictionaryHistoryNow(); // 第一次 flush 填充该条 memo
      final rows0 = await db.getAllDictionaryHistory();
      expect(
        DictionarySearchResult.fromJson(rows0.single.resultJson).scrollPosition,
        0,
      );

      final result = repo.dictionaryHistory.first;
      repo.updateDictionaryResultScrollIndex(result: result, newIndex: 5);
      await repo.flushDictionaryHistoryNow();

      final rows = await db.getAllDictionaryHistory();
      expect(
        DictionarySearchResult.fromJson(rows.single.resultJson).scrollPosition,
        5,
        reason: 'memo 未失效会把 stale 的 scrollPosition=0 写回 DB',
      );
    });

    test(
        'ExitFlushRegistry.flushAll writes pending history through (exit path)',
        () async {
      // 守回归：构造函数必须向 ExitFlushRegistry 注册 flush——桌面点 X 快杀
      // （exit(0)）前靠 flushAll 把 debounce 中的历史写穿，删注册=退出丢历史。
      // 隔离进程级单例：先清空既有注册，测试后恢复 setUp repo 的注册
      // （同对象实例方法 tear-off 相等，re-register 与原注册等价，tearDown 里
      // dispose 的 unregister 仍能命中）。
      ExitFlushRegistry.instance.clear();
      addTearDown(() {
        ExitFlushRegistry.instance.register(repo.flushDictionaryHistoryNow);
      });

      final db2 = _testDb();
      final repo2 = DictionaryRepository(db2);
      expect(ExitFlushRegistry.instance.callbackCount, 1,
          reason: '构造函数必须注册退出 flush 回调');

      repo2.addHistoryResult(_result(searchTerm: '退'), 10);
      expect(await db2.getAllDictionaryHistory(), isEmpty);

      await ExitFlushRegistry.instance.flushAll();

      final rows = await db2.getAllDictionaryHistory();
      expect(rows.length, 1);
      expect(
        DictionarySearchResult.fromJson(rows.single.resultJson).searchTerm,
        '退',
      );
      repo2.dispose();
      await db2.close();
    });
  });

  // ── baseName / findUpdatable / deleteDictionaryMeta ──────────────────

  group('baseName', () {
    test('strips date suffix', () {
      expect(DictionaryRepository.baseName('JMdict [2026-05-17]'), 'JMdict');
    });

    test('strips date with leading space', () {
      expect(
        DictionaryRepository.baseName('KANJIDIC (English) [2026-01-01]'),
        'KANJIDIC (English)',
      );
    });

    test('returns name unchanged if no date suffix', () {
      expect(DictionaryRepository.baseName('JMdict'), 'JMdict');
      expect(DictionaryRepository.baseName('Pixiv'), 'Pixiv');
    });

    test('does not strip non-date brackets', () {
      expect(
        DictionaryRepository.baseName('dict [abc]'),
        'dict [abc]',
      );
    });
  });

  group('findUpdatable', () {
    test('finds older version with different date', () {
      repo.persistDictionary(_dict(name: 'JMdict [2026-05-17]', order: 0));
      final result = repo.findUpdatable('JMdict [2026-05-19]');
      expect(result, isNotNull);
      expect(result!.name, 'JMdict [2026-05-17]');
    });

    test('returns null for exact same name', () {
      repo.persistDictionary(_dict(name: 'JMdict [2026-05-17]', order: 0));
      expect(repo.findUpdatable('JMdict [2026-05-17]'), isNull);
    });

    test('returns null for two identical undated names', () {
      repo.persistDictionary(_dict(name: 'Pixiv', order: 0));
      expect(repo.findUpdatable('Pixiv'), isNull);
    });

    test('finds dated version when importing undated name', () {
      repo.persistDictionary(_dict(name: 'JMdict [2026-05-17]', order: 0));
      final result = repo.findUpdatable('JMdict');
      expect(result, isNotNull);
      expect(result!.name, 'JMdict [2026-05-17]');
    });

    test('finds undated version when importing dated name', () {
      repo.persistDictionary(_dict(name: 'JMdict', order: 0));
      final result = repo.findUpdatable('JMdict [2026-05-19]');
      expect(result, isNotNull);
      expect(result!.name, 'JMdict');
    });

    test('returns null when no match exists', () {
      repo.persistDictionary(_dict(name: 'JMdict [2026-05-17]', order: 0));
      expect(repo.findUpdatable('KANJIDIC [2026-05-19]'), isNull);
    });

    test('does not match different base names', () {
      repo.persistDictionary(
          _dict(name: 'JMdict (Dutch) [2026-05-17]', order: 0));
      expect(repo.findUpdatable('JMdict [2026-05-19]'), isNull);
    });
  });

  group('deleteDictionaryMeta', () {
    test('removes from cache and DB', () async {
      repo.persistDictionary(_dict(name: 'ToDelete', order: 0));
      await _settle();
      expect(repo.hasDictionaryNamed('ToDelete'), true);

      await repo.deleteDictionaryMeta('ToDelete');
      expect(repo.hasDictionaryNamed('ToDelete'), false);

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.hasDictionaryNamed('ToDelete'), false);
      repo2.dispose();
    });
  });

  // ── row conversion round-trip ────────────────────────────────────────

  group('row conversion round-trip', () {
    test('Dictionary metadata survives persist → loadFromDb', () async {
      final d = Dictionary(
        name: '明鏡国語辞典',
        formatKey: 'yomichan',
        order: 3,
        type: DictionaryType.frequency,
        metadata: {'version': '2.0', 'author': 'test'},
        hiddenLanguages: ['en', 'zh'],
        collapsedLanguages: ['ja'],
      );
      repo.persistDictionary(d);
      await _settle();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      final loaded = repo2.dictionaries.first;
      expect(loaded.name, '明鏡国語辞典');
      expect(loaded.formatKey, 'yomichan');
      expect(loaded.order, 3);
      expect(loaded.type, DictionaryType.frequency);
      expect(loaded.metadata, {'version': '2.0', 'author': 'test'});
      expect(loaded.hiddenLanguages, ['en', 'zh']);
      expect(loaded.collapsedLanguages, ['ja']);
      repo2.dispose();
    });

    test('all DictionaryType values survive round-trip', () async {
      for (final type in DictionaryType.values) {
        repo.persistDictionary(
            _dict(name: type.name, type: type, order: type.index));
      }
      await _settle();

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      for (final type in DictionaryType.values) {
        final d = repo2.dictionaries.firstWhere((d) => d.name == type.name);
        expect(d.type, type);
      }
      repo2.dispose();
    });
  });
}
