import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  for (final MihonMediaKind kind in MihonMediaKind.values) {
    test(
      '${kind.name}: latest reorder wins while previous write is pending',
      () async {
        final _GatedDatabase database = _GatedDatabase();
        final MihonManager manager = MihonManager(
          database: database,
          rootDirectory: Directory.systemTemp,
          runtime: _UnusedRuntime(),
          kind: kind,
          ownsRuntime: false,
        );
        addTearDown(() async {
          database.releaseFirstWrite();
          manager.dispose();
          await database.close();
        });
        await database.replaceMangaOnlineSources(
          'org.example.reorder',
          <MangaOnlineSourcesCompanion>[
            for (int index = 0; index < 2; index++)
              MangaOnlineSourcesCompanion.insert(
                extensionPackage: 'org.example.reorder',
                sourceId: index == 0 ? 'A' : 'B',
                name: index == 0 ? 'A' : 'B',
                language: 'ja',
                sortOrder: Value<int>(index),
                mediaKind: Value<String>(kind.dbValue),
              ),
          ],
        );
        await manager.reload();
        final List<MangaOnlineSourceRow> original =
            List<MangaOnlineSourceRow>.of(manager.sources);

        // The UI keeps these row snapshots during optimistic dragging: the
        // first BA operation is still saving when the user drags back to AB.
        final Future<void> first = manager.reorderSources(
          original.reversed.toList(),
        );
        await database.firstWriteEntered.future;
        final Future<void> latest = manager.reorderSources(original);
        database.releaseFirstWrite();
        await Future.wait<void>(<Future<void>>[first, latest]);

        expect(
          manager.sources.map((MangaOnlineSourceRow row) => row.sourceId),
          <String>['A', 'B'],
        );
        final List<MangaOnlineSourceRow> persisted = await database
            .getMangaOnlineSources(mediaKind: kind.dbValue);
        expect(
          persisted.map((MangaOnlineSourceRow row) => row.sourceId),
          <String>['A', 'B'],
        );
        expect(
          persisted.map((MangaOnlineSourceRow row) => row.sortOrder),
          <int>[0, 1],
        );
      },
    );
  }
}

class _UnusedRuntime extends Fake implements MihonRuntime {}

class _GatedDatabase extends FushiDatabase {
  _GatedDatabase() : super.forTesting(NativeDatabase.memory());

  final Completer<void> firstWriteEntered = Completer<void>();
  final Completer<void> _firstWriteReleased = Completer<void>();
  bool _firstWrite = true;

  void releaseFirstWrite() {
    if (!_firstWriteReleased.isCompleted) _firstWriteReleased.complete();
  }

  @override
  Future<void> updateMangaOnlineSourceSettings({
    required String extensionPackage,
    required String sourceId,
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) async {
    if (_firstWrite) {
      _firstWrite = false;
      firstWriteEntered.complete();
      await _firstWriteReleased.future;
    }
    await super.updateMangaOnlineSourceSettings(
      extensionPackage: extensionPackage,
      sourceId: sourceId,
      enabled: enabled,
      pinned: pinned,
      sortOrder: sortOrder,
    );
  }
}
