import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

class _HistoryGate {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

// The gate is inside replaceAllDictionaryHistory's real SQLite transaction,
// at its DELETE. Clear therefore retains Drift's actual connection ordering;
// no repository method or pre-transaction scheduling is replaced.
class _HistorySqlBoundary extends QueryInterceptor {
  _HistoryGate? _nextGate;
  final List<_HistoryGate> _gates = <_HistoryGate>[];
  bool failNextDelete = false;
  int historyDeletes = 0;

  _HistoryGate blockNextDelete() {
    final _HistoryGate gate = _HistoryGate();
    _gates.add(gate);
    _nextGate = gate;
    return gate;
  }

  void releaseAll() {
    for (final _HistoryGate gate in _gates) {
      gate.open();
    }
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.toLowerCase().contains('dictionary_history')) {
      historyDeletes++;
      final _HistoryGate? gate = _nextGate;
      _nextGate = null;
      final bool fail = failNextDelete;
      failNextDelete = false;
      if (gate != null) {
        gate.entered.complete();
        await gate.release.future;
      }
      if (fail) throw StateError('injected dictionary history SQL failure');
    }
    return executor.runDelete(statement, args);
  }
}

DictionarySearchResult _result(String word) => DictionarySearchResult(
  searchTerm: word,
  entries: <DictionaryEntry>[DictionaryEntry(word: word)],
);

Future<List<String>> _storedTerms(FushiDatabase db) async =>
    (await db.getAllDictionaryHistory())
        .map(
          (DictionaryHistoryRow row) =>
              DictionarySearchResult.fromJson(row.resultJson).searchTerm,
        )
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HistorySqlBoundary boundary;
  late FushiDatabase db;
  late DictionaryRepository repo;
  final List<Future<void>> pending = <Future<void>>[];

  Future<void> track(Future<void> write) {
    pending.add(write);
    // Attach an error listener immediately. Tests still await the original
    // future to assert failures; cleanup can always release gates and drain it.
    unawaited(write.catchError((Object _) {}));
    return write;
  }

  setUp(() async {
    pending.clear();
    boundary = _HistorySqlBoundary();
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(boundary),
    );
    repo = DictionaryRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    boundary.releaseAll();
    for (final Future<void> write in pending) {
      try {
        await write;
      } catch (_) {
        // Each test asserts its own result. Never close SQLite under a gate.
      }
    }
    repo.dispose();
    await db.close();
  });

  test('close flush waits for history that already entered SQLite', () async {
    repo.addHistoryResult(_result('first'), 10);
    final _HistoryGate gate = boundary.blockNextDelete();
    final Future<void> first = track(repo.flushDictionaryHistoryNow());
    await gate.entered.future;

    bool drained = false;
    final Future<void> closing = track(
      repo.flushPendingWritesNow().then<void>((_) {
        drained = true;
      }),
    );
    await Future<void>(() {});
    expect(
      drained,
      isFalse,
      reason: 'an already-started history transaction is still pending',
    );

    gate.open();
    await first;
    await closing;
    expect(await _storedTerms(db), <String>['first']);
  });

  test('failed history SQL remains retryable without another lookup', () async {
    repo.addHistoryResult(_result('retry'), 10);
    boundary.failNextDelete = true;
    await expectLater(
      track(repo.flushDictionaryHistoryNow()),
      throwsStateError,
    );
    expect(await _storedTerms(db), isEmpty);
    expect(repo.dictionaryHistory.single.searchTerm, 'retry');

    await track(repo.flushPendingWritesNow());
    expect(await _storedTerms(db), <String>['retry']);
    expect(boundary.historyDeletes, 2);
  });

  test('older history completion cannot discard a newer lookup', () async {
    repo.addHistoryResult(_result('first'), 10);
    final _HistoryGate gate = boundary.blockNextDelete();
    final Future<void> first = track(repo.flushDictionaryHistoryNow());
    await gate.entered.future;
    repo.addHistoryResult(_result('second'), 10);
    final Future<void> closing = track(repo.flushPendingWritesNow());

    gate.open();
    await first;
    await closing;
    expect(await _storedTerms(db), <String>['first', 'second']);
    final int writesAfterDrain = boundary.historyDeletes;
    await track(repo.flushPendingWritesNow());
    expect(
      boundary.historyDeletes,
      writesAfterDrain,
      reason: 'fully committed history must not be written again',
    );
  });

  test(
    'clear after an in-flight write leaves no resurrected history',
    () async {
      repo.addHistoryResult(_result('old'), 10);
      final _HistoryGate gate = boundary.blockNextDelete();
      final Future<void> writing = track(repo.flushDictionaryHistoryNow());
      await gate.entered.future;
      final Future<void> clearing = track(repo.clearDictionaryHistory());

      gate.open();
      await writing;
      await clearing;
      expect(repo.dictionaryHistory, isEmpty);
      expect(await _storedTerms(db), isEmpty);
      final int writesAfterClear = boundary.historyDeletes;
      await track(repo.flushPendingWritesNow());
      expect(boundary.historyDeletes, writesAfterClear);
      expect(await _storedTerms(db), isEmpty);
    },
  );

  test(
    'dispose cancels newer dirty history without restarting old writes',
    () async {
      repo.addHistoryResult(_result('already-started'), 10);
      final _HistoryGate gate = boundary.blockNextDelete();
      final Future<void> writing = track(repo.flushDictionaryHistoryNow());
      await gate.entered.future;
      repo.addHistoryResult(_result('cancelled-on-dispose'), 10);
      repo.dispose();

      gate.open();
      await writing;
      await track(repo.flushPendingWritesNow());
      expect(repo.dictionaryHistory, isEmpty);
      expect(await _storedTerms(db), <String>['already-started']);
      expect(boundary.historyDeletes, 1);
    },
  );
}
