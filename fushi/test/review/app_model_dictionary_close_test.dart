import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

class _MetadataInsertGate extends QueryInterceptor {
  Completer<void>? gate;
  final Completer<void> entered = Completer<void>();

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final Completer<void>? pending = gate;
    if (pending != null && statement.contains('dictionary_metadata')) {
      gate = null;
      entered.complete();
      await pending.future;
    }
    return executor.runInsert(statement, args);
  }
}

class _CloseRecordingDatabase extends FushiDatabase {
  _CloseRecordingDatabase(QueryExecutor executor) : super.forTesting(executor);

  int closeCalls = 0;
  bool failHistoryWrite = false;

  @override
  Future<void> close() {
    closeCalls++;
    return super.close();
  }

  @override
  Future<void> replaceAllDictionaryHistory(
    List<DictionaryHistoryCompanion> items,
  ) {
    if (failHistoryWrite) {
      throw StateError('injected history flush failure');
    }
    return super.replaceAllDictionaryHistory(items);
  }
}

// Only the next platform startup is inert. The three close/retry entry points,
// repository queue and SQLite file persistence below are production code.
class _RestartBoundaryAppModel extends AppModel {
  _RestartBoundaryAppModel() : super(testPlatformServices());

  int initialiseCalls = 0;
  bool? repoReadyAtInitialise;

  @override
  Future<void> initialise() async {
    initialiseCalls++;
    repoReadyAtInitialise = isDictionaryRepoReady;
  }
}

Future<void> _close(_RestartBoundaryAppModel model, String boundary) =>
    switch (boundary) {
      'closeDatabase' => model.closeDatabase(),
      'closeForPopup' => model.closeForPopup(),
      'retryInitialise' => model.retryInitialise(),
      _ => throw ArgumentError.value(boundary),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final String boundary in <String>[
    'closeDatabase',
    'closeForPopup',
    'retryInitialise',
  ]) {
    test(
      '$boundary drains queued metadata before closing the file DB',
      () async {
        final Directory scratch = Directory.systemTemp.createTempSync(
          'fushi-dictionary-close-',
        );
        final File databaseFile = File(p.join(scratch.path, 'fixture.sqlite'));
        final _MetadataInsertGate fault = _MetadataInsertGate();
        final _CloseRecordingDatabase db = _CloseRecordingDatabase(
          NativeDatabase(databaseFile).interceptWith(fault),
        );
        final DictionaryRepository repo = DictionaryRepository(db);
        final _RestartBoundaryAppModel model = _RestartBoundaryAppModel()
          ..wireDatabaseForTesting(db, dictionaryRepository: repo);
        try {
          await repo.loadFromDb();
          await repo.persistDictionary(
            Dictionary(
              name: 'close fixture',
              formatKey: 'yomichan',
              order: 0,
              displayName: 'before',
            ),
          );
          expect(ExitFlushRegistry.instance.callbackCount, 1);
          final Dictionary snapshot = repo.dictionaries.single;
          final Completer<void> gate = Completer<void>();
          fault.gate = gate;
          final Future<void> rename = repo.setDictionaryDisplayName(
            snapshot,
            'after',
          );
          await fault.entered.future;
          final Future<void> language = repo.setDictionaryLanguageOverride(
            snapshot,
            'ja',
          );
          bool finished = false;
          final Future<void> closing = _close(model, boundary).then((_) {
            finished = true;
          });
          try {
            // Empty event turn settles async quiesce while SQL remains blocked.
            await Future<void>(() {});
            expect(
              db.closeCalls,
              0,
              reason: 'a Dart-queued write must enter Drift before close',
            );
            expect(finished, isFalse);
          } finally {
            gate.complete();
            await rename;
            await language;
            await closing;
          }
          expect(db.closeCalls, 1);
          if (boundary == 'retryInitialise') {
            expect(model.initialiseCalls, 1);
            expect(model.repoReadyAtInitialise, isFalse);
            expect(model.isDictionaryRepoReady, isFalse);
            expect(
              ExitFlushRegistry.instance.callbackCount,
              0,
              reason: 'retry must unregister the old repository callback',
            );
          }
          final FushiDatabase reopened = FushiDatabase.forTesting(
            NativeDatabase(databaseFile),
          );
          try {
            final DictionaryMetaRow stored =
                (await reopened.getAllDictionaryMetadata()).single;
            expect(stored.displayName, 'after');
            expect(stored.languageOverride, 'ja');
          } finally {
            await reopened.close();
          }
        } finally {
          repo.dispose();
          if (db.closeCalls == 0) await db.close();
          scratch.deleteSync(recursive: true);
        }
      },
    );

    test(
      '$boundary accepts partial init before the dictionary repo exists',
      () async {
        final _CloseRecordingDatabase db = _CloseRecordingDatabase(
          NativeDatabase.memory(),
        );
        final _RestartBoundaryAppModel model = _RestartBoundaryAppModel()
          ..wireDatabaseForTesting(db);
        try {
          await db.getAllDictionaryMetadata();
          expect(model.isDictionaryRepoReady, isFalse);
          await _close(model, boundary);
          expect(db.closeCalls, 1);
          if (boundary == 'retryInitialise') {
            expect(model.initialiseCalls, 1);
            expect(model.repoReadyAtInitialise, isFalse);
          }
        } finally {
          if (db.closeCalls == 0) await db.close();
        }
      },
    );
  }

  for (final String boundary in <String>['closeDatabase', 'closeForPopup']) {
    test('$boundary still closes when the history flush fails', () async {
      final _CloseRecordingDatabase db = _CloseRecordingDatabase(
        NativeDatabase.memory(),
      );
      final DictionaryRepository repo = DictionaryRepository(db);
      final _RestartBoundaryAppModel model = _RestartBoundaryAppModel()
        ..wireDatabaseForTesting(db, dictionaryRepository: repo);
      try {
        await repo.loadFromDb();
        repo.addHistoryResult(
          DictionarySearchResult(
            searchTerm: 'fixture',
            entries: <DictionaryEntry>[DictionaryEntry(word: 'fixture')],
          ),
          10,
        );
        db.failHistoryWrite = true;
        // 查词历史是可丢的 debounce 数据：它写失败不能让关库停在半路
        // （已标记未初始化、连接却还开着）。
        await _close(model, boundary);
        expect(db.closeCalls, 1);
      } finally {
        repo.dispose();
        if (db.closeCalls == 0) await db.close();
      }
    });
  }

  test('retry keeps the old connection and repo if flushing fails', () async {
    final Directory scratch = Directory.systemTemp.createTempSync(
      'fushi-dictionary-close-retry-',
    );
    final File databaseFile = File(p.join(scratch.path, 'fixture.sqlite'));
    final _CloseRecordingDatabase db = _CloseRecordingDatabase(
      NativeDatabase(databaseFile),
    );
    final DictionaryRepository repo = DictionaryRepository(db);
    final _RestartBoundaryAppModel model = _RestartBoundaryAppModel()
      ..wireDatabaseForTesting(db, dictionaryRepository: repo);
    try {
      await repo.loadFromDb();
      repo.addHistoryResult(
        DictionarySearchResult(
          searchTerm: 'fixture',
          entries: <DictionaryEntry>[DictionaryEntry(word: 'fixture')],
        ),
        10,
      );
      db.failHistoryWrite = true;
      await model.retryInitialise();
      expect(db.closeCalls, 0);
      expect(model.initialiseCalls, 0);
      expect(model.isDictionaryRepoReady, isTrue);
      expect(ExitFlushRegistry.instance.callbackCount, 1);
      expect(model.initError, contains('injected history flush failure'));
      expect(
        await db.getAllDictionaryMetadata(),
        isEmpty,
        reason: 'the retained connection is still usable',
      );
      db.failHistoryWrite = false;
      await model.retryInitialise();
      expect(db.closeCalls, 1);
      expect(model.initialiseCalls, 1);
      expect(model.isDictionaryRepoReady, isFalse);
      final FushiDatabase reopened = FushiDatabase.forTesting(
        NativeDatabase(databaseFile),
      );
      try {
        final rows = await reopened.getAllDictionaryHistory();
        expect(
          rows,
          hasLength(1),
          reason: 'retry without another lookup must retain failed history',
        );
        expect(
          DictionarySearchResult.fromJson(rows.single.resultJson).searchTerm,
          'fixture',
        );
      } finally {
        await reopened.close();
      }
    } finally {
      repo.dispose();
      if (db.closeCalls == 0) await db.close();
      scratch.deleteSync(recursive: true);
    }
  });
}
