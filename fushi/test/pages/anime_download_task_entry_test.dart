import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/models/app_model.dart';

import '../helpers/test_platform_services.dart';

class _AppModel extends AppModel {
  _AppModel(this.store) : super(testPlatformServices());
  final AnimeDownloadPlanStore store;
  @override
  String get jimakuApiKey => 'key';
  @override
  AnimeDownloadPlanStore get animeDownloadPlanStore => store;
}

class _ControlledStore extends AnimeDownloadPlanStore {
  _ControlledStore() : super(baseDir: Directory('unused'));
  final ValueNotifier<int> changes = ValueNotifier<int>(0);
  final List<Completer<List<AnimeDownloadPlan>>> loads = [];
  @override
  ValueListenable<int> get revision => changes;
  @override
  Future<List<AnimeDownloadPlan>> loadAll() {
    final Completer<List<AnimeDownloadPlan>> result = Completer();
    loads.add(result);
    return result.future;
  }
}

void main() {
  const AnimeDownloadPlan game = AnimeDownloadPlan(
    id: 'ABCDEF',
    createdAtMs: 1234,
    seriesTitle: 'Key_CLANNAD',
    torrentTitle: 'Key_CLANNAD',
    magnet: 'magnet:?xt=urn:btih:abcdef',
    qbCategory: 'downloads',
    contentKind: AnimeDownloadPlan.kindGame,
  );

  Future<void> pumpAdapter(
    WidgetTester tester,
    AnimeDownloadPlanStore store,
    ValueChanged<List<DownloadTaskEntry>> onTasks,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((ref) => _AppModel(store))],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: AnimeDownloadDialog(
                embedded: true,
                tasksOnly: true,
                tasksBuilder: (_, tasks) {
                  onTasks(tasks);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'external durable saves refresh task presence/status/collection',
    (WidgetTester tester) async {
      final Directory dir = Directory.systemTemp.createTempSync('plan-events-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final AnimeDownloadPlanStore store = AnimeDownloadPlanStore(baseDir: dir);
      List<DownloadTaskEntry> tasks = [];
      await pumpAdapter(tester, store, (value) => tasks = value);

      Future<void> awaitTasks(bool Function() ready) async {
        for (int i = 0; i < 50 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      await tester.runAsync(() => store.save(game));
      await awaitTasks(() => tasks.length == 1);
      expect(tasks.single.kind, DownloadTaskKind.game);
      await tester.runAsync(
        () => store.save(
          game.copyWith(
            status: AnimeDownloadPlan.statusImported,
            collectionId: 42,
          ),
        ),
      );
      await awaitTasks(
        () => tasks.single.status == DownloadTaskStatus.completed,
      );
      expect(tasks.single.collectionKey, 'collection:42');
      await tester.runAsync(() => store.delete(game.id));
      await awaitTasks(() => tasks.isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('out of order reload cannot replace a newer plan snapshot', (
    WidgetTester tester,
  ) async {
    final _ControlledStore store = _ControlledStore();
    List<DownloadTaskEntry> tasks = [];
    await pumpAdapter(tester, store, (value) => tasks = value);
    expect(store.loads, hasLength(1));
    store.changes.value++;
    expect(store.loads, hasLength(2));
    store.loads.last.complete([
      game.copyWith(status: AnimeDownloadPlan.statusImported, collectionId: 42),
    ]);
    await tester.pump();
    expect(tasks.single.status, DownloadTaskStatus.completed);
    store.loads.first.complete([game]);
    await tester.pump();
    expect(tasks.single.status, DownloadTaskStatus.completed);
    await tester.pumpWidget(const SizedBox.shrink());
    store.changes.value++;
    expect(store.loads, hasLength(2));
    store.changes.dispose();
  });

  DownloadTaskEntry entry(
    AnimeDownloadPlan plan, {
    double? progress,
    DownloadTaskStats? stats,
  }) => animeDownloadTaskEntry(
    plan: plan,
    progress: progress,
    stats: stats,
    builder: (_) => const SizedBox.shrink(),
  );

  test(
    'generic game keeps kind/time and does not invent collection from name',
    () {
      final DownloadTaskEntry task = entry(game, progress: 0.25);
      expect(task.id, 'legacy-plan:abcdef');
      expect(task.kind, DownloadTaskKind.game);
      expect(task.createdAt, 1234);
      expect(task.progress, 0.25);
      expect(task.collectionKey, isNull);
      expect(task.collectionTitle, isNull);
    },
  );

  test('explicit collection identity takes priority over series identity', () {
    expect(
      entry(game.copyWith(collectionId: 7, anilistId: 9)).collectionKey,
      'collection:7',
    );
    expect(
      entry(game.copyWith(anilistId: 9)).collectionKey,
      'series:anilist:9',
    );
  });

  test('early import does not mark a still downloading task completed', () {
    final DownloadTaskEntry task = entry(
      game.copyWith(importedEarly: true),
      progress: 0.4,
    );
    expect(task.status, DownloadTaskStatus.active);
    expect(task.progress, 0.4);
    expect(entry(game).progress, isNull);
    final DownloadTaskEntry completed = entry(
      game.copyWith(status: AnimeDownloadPlan.statusImported),
    );
    expect(completed.status, DownloadTaskStatus.completed);
    expect(completed.progress, 1);
  });

  test('observed pause remains pause; failed import retains attention', () {
    const DownloadTaskStats paused = DownloadTaskStats(
      progress: 0.5,
      downRateBps: 0,
      upRateBps: 0,
      downloadedBytes: 12,
      uploadedBytes: 0,
      numPeers: 0,
      state: 'pausedDL',
      amountLeft: 12,
    );
    expect(entry(game, stats: paused).status, DownloadTaskStatus.paused);
    expect(
      entry(
        game.copyWith(status: AnimeDownloadPlan.statusFailed),
        stats: paused,
      ).status,
      DownloadTaskStatus.attention,
    );
  });
}
