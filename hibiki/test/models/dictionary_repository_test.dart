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
      await _settle();

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
      await _settle();

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
      await _settle();
      await repo.clearDictionaryHistory();

      expect(repo.dictionaryHistory, isEmpty);

      final repo2 = DictionaryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.dictionaryHistory, isEmpty);
      repo2.dispose();
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
