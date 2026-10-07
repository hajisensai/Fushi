import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

// Fault injection at the real metadata INSERT. No native dictionary engine or
// import-success UI is simulated; this tests the repository's failed-write state.
class _MetadataWriteFault extends QueryInterceptor {
  bool fail = false;
  int failures = 0;
  int metadataInserts = 0;
  int? failAtInsert;
  Completer<void>? blockNextInsert;
  Completer<void>? insertEntered;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.toLowerCase().contains('dictionary_metadata')) {
      metadataInserts++;
      final Completer<void>? gate = blockNextInsert;
      if (gate != null) {
        blockNextInsert = null;
        insertEntered!.complete();
        await gate.future;
      }
      if (fail || metadataInserts == failAtInsert) {
        failures++;
        throw StateError('round8 injected dictionary metadata write failure');
      }
    }
    return executor.runInsert(statement, args);
  }
}

Dictionary _dictionary(String label) => Dictionary(
  name: 'review fixture dictionary',
  formatKey: 'yomichan',
  order: 0,
  type: DictionaryType.term,
  metadata: const <String, String>{},
  displayName: label,
  hiddenLanguages: const <String>[],
  collapsedLanguages: const <String>[],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('HBK-AUDIT-054 committed metadata', () {
    late _MetadataWriteFault fault;
    late FushiDatabase db;
    late DictionaryRepository repo;
    int rebuilds = 0;
    void Function()? onMetadataRebuild;

    setUp(() async {
      fault = _MetadataWriteFault();
      db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(fault),
      );
      rebuilds = 0;
      onMetadataRebuild = null;
      repo = DictionaryRepository(
        db,
        onCacheRebuild: () {
          rebuilds++;
          onMetadataRebuild?.call();
        },
      );
      await repo.loadFromDb();
      await repo.persistDictionary(_dictionary('committed'));
    });
    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test(
      'in-place edits cannot contaminate getters on failure; retry commits',
      () async {
        final Dictionary snapshot = repo.dictionaries.single;
        snapshot.displayName = 'edited';
        snapshot.metadata['revision'] = 'r2';
        snapshot.hiddenLanguages.add('en');
        snapshot.collapsedLanguages.add('ja');
        snapshot.expandedLanguages.add('zh');
        expect(repo.termDictionaries.single.displayName, 'committed');
        expect(repo.displayNameOverrides.values.single, 'committed');
        repo.cacheFfiLookup('fixture', <FushiLookupResult>[]);
        final int before = rebuilds;
        fault.fail = true;
        await expectLater(repo.persistDictionary(snapshot), throwsStateError);
        final Dictionary unchanged = repo.dictionaries.single;
        expect(unchanged.displayName, 'committed');
        expect(unchanged.metadata, isEmpty);
        expect(unchanged.hiddenLanguages, isEmpty);
        expect(unchanged.collapsedLanguages, isEmpty);
        expect(unchanged.expandedLanguages, isEmpty);
        expect(rebuilds, before);
        expect(repo.getCachedFfiLookup('fixture'), isNotNull);
        expect(
          (await db.getAllDictionaryMetadata()).single.displayName,
          'committed',
        );

        fault.fail = false;
        await repo.persistDictionary(snapshot);
        expect(repo.dictionaries.single.displayName, 'edited');
        expect(repo.dictionaries.single.metadata['revision'], 'r2');
        expect(repo.dictionaries.single.hiddenLanguages, <String>['en']);
        expect(repo.dictionaries.single.collapsedLanguages, <String>['ja']);
        expect(repo.dictionaries.single.expandedLanguages, <String>['zh']);
        expect(rebuilds, before + 1);
        expect(repo.getCachedFfiLookup('fixture'), isNull);
        await repo.loadFromDb();
        expect(repo.dictionaries.single.displayName, 'edited');
        expect(repo.dictionaries.single.metadata['revision'], 'r2');
      },
    );

    test(
      'pending writes publish nothing and freeze all caller-owned collections',
      () async {
        final Dictionary snapshot = repo.dictionaries.single;
        snapshot.displayName = 'submitted';
        snapshot.metadata['revision'] = 'r2';
        snapshot.hiddenLanguages.add('ja');
        final Completer<void> gate = Completer<void>();
        fault.blockNextInsert = gate;
        fault.insertEntered = Completer<void>();
        final Future<void> pending = repo.persistDictionary(snapshot);
        await fault.insertEntered!.future;
        snapshot.displayName = 'later local edit';
        snapshot.metadata['revision'] = 'r3';
        snapshot.hiddenLanguages.add('en');
        expect(repo.dictionaries.single.displayName, 'committed');
        expect(rebuilds, 1);
        gate.complete();
        await pending;
        expect(repo.dictionaries.single.displayName, 'submitted');
        expect(repo.dictionaries.single.metadata['revision'], 'r2');
        expect(repo.dictionaries.single.hiddenLanguages, <String>['ja']);
        final DictionaryMetaRow stored =
            (await db.getAllDictionaryMetadata()).single;
        expect(stored.displayName, 'submitted');
        expect(jsonDecode(stored.metadataJson), <String, String>{
          'revision': 'r2',
        });
      },
    );

    test(
      'concurrent field edits and stale reorder retain every committed field',
      () async {
        final Dictionary renameSnapshot = repo.dictionaries.single;
        final Dictionary languageSnapshot = repo.dictionaries.single;
        final Dictionary collapseSnapshot = repo.dictionaries.single;
        final Dictionary orderSnapshot = repo.dictionaries.single..order = 7;
        final Completer<void> gate = Completer<void>();
        fault.blockNextInsert = gate;
        fault.insertEntered = Completer<void>();
        final Future<void> rename = repo.setDictionaryDisplayName(
          renameSnapshot,
          'renamed',
        );
        await fault.insertEntered!.future;
        final Future<void> language = repo.setDictionaryLanguageOverride(
          languageSnapshot,
          'en',
        );
        final Future<void> collapse = repo.cycleDictionaryCollapseState(
          collapseSnapshot,
          'ja',
        );
        final Future<void> reorder = repo.updateDictionaryOrder(<Dictionary>[
          orderSnapshot,
        ]);
        final Future<void> backfill = repo.updateDictionaryMetadata(
          <String, Dictionary? Function(Dictionary)>{
            renameSnapshot.name: (Dictionary current) => current.copyWith(
              metadata: <String, String>{...current.metadata, 'revision': 'r2'},
            ),
          },
        );
        expect(repo.dictionaries.single.displayName, 'committed');
        gate.complete();
        await Future.wait(<Future<void>>[
          rename,
          language,
          collapse,
          reorder,
          backfill,
        ]);
        await repo.loadFromDb();
        final Dictionary committed = repo.dictionaries.single;
        expect(committed.displayName, 'renamed');
        expect(committed.languageOverride, 'en');
        expect(committed.order, 7);
        expect(
          committed.collapseStateForCode('ja'),
          DictionaryCollapseState.expanded,
        );
        expect(committed.metadata['revision'], 'r2');
      },
    );

    test(
      'failed field update does not poison queued edits or their retry',
      () async {
        final Dictionary snapshot = repo.dictionaries.single;
        final Completer<void> gate = Completer<void>();
        fault.blockNextInsert = gate;
        fault.insertEntered = Completer<void>();
        fault.failAtInsert = fault.metadataInserts + 1;
        final Future<void> failed = repo.setDictionaryDisplayName(
          snapshot,
          'renamed',
        );
        final Future<void> failureObserved = expectLater(
          failed,
          throwsStateError,
        );
        await fault.insertEntered!.future;
        final Future<void> language = repo.setDictionaryLanguageOverride(
          snapshot,
          'ja',
        );
        gate.complete();
        await failureObserved;
        await language;
        expect(snapshot.displayName, 'committed');
        expect(repo.dictionaries.single.displayName, 'committed');
        expect(repo.dictionaries.single.languageOverride, 'ja');
        await repo.setDictionaryDisplayName(snapshot, 'renamed');
        await repo.loadFromDb();
        expect(repo.dictionaries.single.displayName, 'renamed');
        expect(repo.dictionaries.single.languageOverride, 'ja');
      },
    );

    test(
      'second-row failure rolls back an entire batch before publication',
      () async {
        await repo.persistDictionary(
          Dictionary(name: 'second', formatKey: 'yomichan', order: 1),
        );
        final List<Dictionary> snapshots = repo.dictionaries;
        for (final Dictionary d in snapshots) {
          d.displayName = 'uncommitted';
        }
        final int before = rebuilds;
        fault.failAtInsert = fault.metadataInserts + 2;
        await expectLater(
          repo.persistDictionaries(snapshots),
          throwsStateError,
        );
        expect(
          repo.dictionaries.map((Dictionary d) => d.displayName),
          <String?>['committed', null],
        );
        expect(rebuilds, before);
        await repo.loadFromDb();
        expect(
          repo.dictionaries.map((Dictionary d) => d.displayName),
          <String?>['committed', null],
        );
        await repo.persistDictionaries(snapshots);
        expect(
          repo.dictionaries.map((Dictionary d) => d.displayName),
          <String?>['uncommitted', 'uncommitted'],
        );
        expect(rebuilds, before + 1);
      },
    );

    test(
      'exit flush drains pending metadata and callback-enqueued writes',
      () async {
        expect(ExitFlushRegistry.instance.callbackCount, 1);
        final Completer<void> gate = Completer<void>();
        fault.blockNextInsert = gate;
        fault.insertEntered = Completer<void>();
        final Dictionary snapshot = repo.dictionaries.single;
        Future<void>? followup;
        final Completer<void> followupGate = Completer<void>();
        final Completer<void> followupEntered = Completer<void>();
        onMetadataRebuild = () {
          followup = repo.setDictionaryHidden(
            repo.dictionaries.single,
            'ja',
            true,
          );
          // The already-queued language write is next. Its rebuild blocks the
          // newly appended follow-up, beyond the tail captured by flushAll.
          onMetadataRebuild = () {
            onMetadataRebuild = null;
            fault.blockNextInsert = followupGate;
            fault.insertEntered = followupEntered;
          };
        };
        final Future<void> rename = repo.setDictionaryDisplayName(
          snapshot,
          'exit label',
        );
        await fault.insertEntered!.future;
        final Future<void> language = repo.setDictionaryLanguageOverride(
          snapshot,
          'ja',
        );
        bool flushed = false;
        final Future<void> flush = ExitFlushRegistry.instance
            .flushAll(clearCallbacks: false)
            .then((_) => flushed = true);
        try {
          // Let the microtask queue settle while the actual SQLite INSERT is
          // still blocked. This is an event-loop boundary, not a timing delay.
          await Future<void>(() {});
          expect(
            flushed,
            isFalse,
            reason: 'exit must not close the DB ahead of queued metadata',
          );
          gate.complete();
          await followupEntered.future.timeout(const Duration(seconds: 5));
          await Future<void>(() {});
          expect(
            flushed,
            isFalse,
            reason: 'exit must include writes enqueued by rebuild callbacks',
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          if (!followupGate.isCompleted) followupGate.complete();
          await rename;
          await language;
          await flush;
          await followup;
        }
        final DictionaryMetaRow stored =
            (await db.getAllDictionaryMetadata()).single;
        expect(stored.displayName, 'exit label');
        expect(stored.languageOverride, 'ja');
        expect(jsonDecode(stored.hiddenLanguagesJson), <String>['ja']);
        expect(ExitFlushRegistry.instance.callbackCount, 1);
      },
    );

    test('queued absolute collapse choices retain the last target', () async {
      final Dictionary earlier = repo.dictionaries.single;
      final Dictionary later = repo.dictionaries.single;
      await Future.wait(<Future<void>>[
        repo.setDictionaryCollapseState(
          earlier,
          'ja',
          DictionaryCollapseState.collapsed,
        ),
        repo.setDictionaryCollapseState(
          later,
          'ja',
          DictionaryCollapseState.expanded,
        ),
      ]);
      expect(
        repo.dictionaries.single.collapseStateForCode('ja'),
        DictionaryCollapseState.expanded,
      );
      await repo.loadFromDb();
      expect(
        repo.dictionaries.single.collapseStateForCode('ja'),
        DictionaryCollapseState.expanded,
      );
    });

    test('duplicate absolute visibility choices stay idempotent', () async {
      final Dictionary earlier = repo.dictionaries.single;
      final Dictionary later = repo.dictionaries.single;
      await Future.wait(<Future<void>>[
        repo.setDictionaryHidden(earlier, 'ja', true),
        repo.setDictionaryHidden(later, 'ja', true),
      ]);
      expect(repo.dictionaries.single.hiddenLanguages, <String>['ja']);
      await repo.loadFromDb();
      expect(repo.dictionaries.single.hiddenLanguages, <String>['ja']);
      await Future.wait(<Future<void>>[
        repo.setDictionaryHidden(earlier, 'ja', false),
        repo.setDictionaryHidden(later, 'ja', true),
      ]);
      expect(repo.dictionaries.single.hiddenLanguages, <String>['ja']);
      await Future.wait(<Future<void>>[
        repo.setDictionaryHidden(earlier, 'ja', true),
        repo.setDictionaryHidden(later, 'ja', false),
      ]);
      expect(repo.dictionaries.single.hiddenLanguages, isEmpty);
    });

    test(
      'two queued collapse cycles use latest state despite stale snapshots',
      () async {
        final Dictionary first = repo.dictionaries.single;
        final Dictionary second = repo.dictionaries.single;
        await Future.wait(<Future<void>>[
          repo.cycleDictionaryCollapseState(first, 'ja'),
          repo.cycleDictionaryCollapseState(second, 'ja'),
        ]);
        expect(
          repo.dictionaries.single.collapseStateForCode('ja'),
          DictionaryCollapseState.collapsed,
        );
        await repo.loadFromDb();
        expect(
          repo.dictionaries.single.collapseStateForCode('ja'),
          DictionaryCollapseState.collapsed,
        );
      },
    );
  });
  for (final bool existing in <bool>[false, true]) {
    test(
      existing
          ? 'failed metadata update retains the last persisted dictionary'
          : 'failed metadata insert never publishes a cache-only dictionary',
      () async {
        final _MetadataWriteFault fault = _MetadataWriteFault();
        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory().interceptWith(fault),
        );
        final List<List<String?>> published = <List<String?>>[];
        late DictionaryRepository repo;
        repo = DictionaryRepository(
          db,
          onCacheRebuild: () => published.add(
            repo.dictionaries.map((Dictionary d) => d.displayName).toList(),
          ),
        );
        addTearDown(() async {
          repo.dispose();
          await db.close();
        });
        await repo.loadFromDb();
        if (existing) await repo.persistDictionary(_dictionary('old label'));
        published.clear();
        fault.fail = true;
        await expectLater(
          repo.persistDictionary(_dictionary('failed label')),
          throwsStateError,
        );
        final List<String?> cache = repo.dictionaries
            .map((Dictionary d) => d.displayName)
            .toList();
        final List<DictionaryMetaRow> stored = await db
            .getAllDictionaryMetadata();
        final List<String?> disk = stored
            .map((DictionaryMetaRow d) => d.displayName)
            .toList();
        // A fresh repository is the next-start view of the committed DB.
        final DictionaryRepository reopened = DictionaryRepository(db);
        await reopened.loadFromDb();
        final List<String?> reloaded = reopened.dictionaries
            .map((Dictionary d) => d.displayName)
            .toList();
        reopened.dispose();
        final List<String?> expected = existing
            ? <String?>['old label']
            : <String?>[];
        // ignore: avoid_print
        print(
          'round8 dictionary existing=$existing injected=${fault.failures} '
          'cache=$cache disk=$disk reload=$reloaded published=$published',
        );
        expect(fault.failures, 1);
        expect(disk, expected);
        expect(reloaded, expected);
        expect(
          cache,
          expected,
          reason: 'failed writes must not remain published',
        );
      },
    );
  }

  test(
    'control: successful metadata persists through file DB close and reopen',
    () async {
      final Directory scratch = Directory.systemTemp.createTempSync(
        'fushi-round8-dict-db-',
      );
      final File databaseFile = File(p.join(scratch.path, 'fixture.sqlite'));
      try {
        final FushiDatabase first = FushiDatabase.forTesting(
          NativeDatabase(databaseFile),
        );
        final DictionaryRepository firstRepo = DictionaryRepository(first);
        await firstRepo.loadFromDb();
        await firstRepo.persistDictionary(_dictionary('persisted label'));
        firstRepo.dispose();
        await first.close();
        final FushiDatabase second = FushiDatabase.forTesting(
          NativeDatabase(databaseFile),
        );
        final DictionaryRepository secondRepo = DictionaryRepository(second);
        try {
          await secondRepo.loadFromDb();
          expect(secondRepo.dictionaries.single.displayName, 'persisted label');
        } finally {
          secondRepo.dispose();
          await second.close();
        }
      } finally {
        scratch.deleteSync(recursive: true);
      }
    },
  );
}
