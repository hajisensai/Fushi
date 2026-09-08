import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_tasks_section.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi_core/fushi_core.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

void main() {
  test(
    'manga selective cleanup preserves active and other finished tasks',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final StreamController<MokuroMoeVolumeDownloadEvent> stream =
          StreamController<MokuroMoeVolumeDownloadEvent>();
      final MokuroMoeDownloadQueue queue = MokuroMoeDownloadQueue(
        db: db,
        clientFactory: () => MokuroMoeClient(),
        runnerOverride:
            ({required String seriesName, required String volumeName}) =>
                stream.stream,
      );
      addTearDown(() async {
        queue.dispose();
        await stream.close();
        await db.close();
      });
      queue.enqueue(
        seriesName: 'Series',
        volumeNames: <String>['01', '02', '03'],
      );
      final MokuroMoeDownloadTask running = queue.tasks[0];
      final MokuroMoeDownloadTask removed = queue.tasks[1];
      final MokuroMoeDownloadTask retained = queue.tasks[2];
      removed.status = MokuroMoeTaskStatus.done;
      retained.status = MokuroMoeTaskStatus.failed;
      int notifications = 0;
      queue.addListener(() => notifications++);
      queue.removeFinished(running);
      expect(queue.tasks, hasLength(3));
      expect(notifications, 0);
      queue.removeFinished(removed);
      expect(queue.tasks, <MokuroMoeDownloadTask>[running, retained]);
      expect(notifications, 1);
      queue.removeFinished(removed);
      expect(notifications, 1);
    },
  );

  testWidgets(
    'direct builder includes empty queue, kinds and stable enqueue metadata',
    (WidgetTester tester) async {
      final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
        resolvePayload: (DiscoveryResourceItem item) =>
            Completer<DiscoveryPayload>().future,
        importer: (DiscoveryDownloadTask task, File file) async =>
            const DiscoveryImportOutcome(),
      );
      addTearDown(queue.dispose);
      List<DownloadTaskEntry>? entries;
      await _pump(
        tester,
        DiscoveryDownloadTasksSection(
          queueOverride: queue,
          tasksBuilder: (BuildContext context, List<DownloadTaskEntry> tasks) {
            entries = tasks;
            return const SizedBox();
          },
        ),
      );
      expect(entries, isEmpty);
      final int before = DateTime.now().millisecondsSinceEpoch;
      for (final DiscoveryMediaKind kind in DiscoveryMediaKind.values) {
        queue.enqueue(
          DiscoveryResourceItem(
            id: kind.name,
            sourceId: 'source',
            title: 'Shared title Vol 1',
            kind: kind,
            payloadKind: DiscoveryPayloadKind.httpFile,
            payload: const DiscoveryHttpPayload(
              url: 'https://example.com/file',
            ),
          ),
          destinationDir: '',
        );
      }
      await tester.pump();
      expect(entries, hasLength(4));
      expect(
        entries!.map((DownloadTaskEntry entry) => entry.kind),
        <DownloadTaskKind>[
          DownloadTaskKind.novel,
          DownloadTaskKind.audiobook,
          DownloadTaskKind.game,
          DownloadTaskKind.manga,
        ],
      );
      expect(entries!.first.status, DownloadTaskStatus.active);
      expect(entries!.last.status, DownloadTaskStatus.queued);
      expect(
        entries!.every(
          (DownloadTaskEntry entry) => entry.collectionKey == null,
        ),
        isTrue,
      );
      expect(entries!.first.createdAt, greaterThanOrEqualTo(before));
      expect(entries!.first.onClear, isNull);
      expect(entries!.first.onRetry, isNull);
      final String originalId = entries!.last.id;
      final int? originalCreatedAt = entries!.last.createdAt;
      queue.tasks.last.status = DiscoveryDownloadStatus.failed;
      queue.retry(queue.tasks.last);
      await tester.pump();
      expect(entries!.last.id, originalId);
      expect(entries!.last.createdAt, originalCreatedAt);
      queue.tasks.last.status = DiscoveryDownloadStatus.failed;
      await _pump(
        tester,
        DiscoveryDownloadTasksSection(
          queueOverride: queue,
          tasksBuilder: (BuildContext context, List<DownloadTaskEntry> tasks) {
            entries = tasks;
            return const SizedBox();
          },
        ),
      );
      expect(entries!.last.onRetry, isNotNull);
      entries!.last.onClear!();
      await tester.pump();
      expect(queue.tasks, hasLength(3));
      expect(queue.tasks.first.status, DiscoveryDownloadStatus.running);

      final BuildContext context = tester.element(find.byType(Scaffold));
      expect(entries!.first.builder(context), isA<DownloadTaskCard>());
    },
  );

  testWidgets(
    'manga groups exact series and gives repeated volumes distinct task IDs',
    (WidgetTester tester) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final MokuroMoeDownloadQueue queue = MokuroMoeDownloadQueue(
        db: db,
        clientFactory: () => MokuroMoeClient(),
        runnerOverride:
            ({required String seriesName, required String volumeName}) =>
                const Stream<MokuroMoeVolumeDownloadEvent>.empty(),
      );
      addTearDown(() async {
        queue.dispose();
        await db.close();
      });
      List<DownloadTaskEntry>? entries;
      await _pump(
        tester,
        MokuroMoeTasksSection(
          queueOverride: queue,
          tasksBuilder: (BuildContext context, List<DownloadTaskEntry> tasks) {
            entries = tasks;
            return const SizedBox();
          },
        ),
      );
      expect(entries, isEmpty);
      queue.enqueue(seriesName: 'Series', volumeNames: <String>['01', '02']);
      queue.enqueue(seriesName: 'Series Special', volumeNames: <String>['01']);
      await tester.pump();
      expect(entries, hasLength(3));
      expect(entries![0].collectionKey, entries![1].collectionKey);
      expect(entries![0].collectionKey, isNot(entries![2].collectionKey));
      expect(entries![0].collectionTitle, 'Series');
      expect(entries![0].kind, DownloadTaskKind.manga);
      queue.tasks.first.status = MokuroMoeTaskStatus.done;
      queue.enqueue(seriesName: 'Series', volumeNames: <String>['01']);
      await tester.pump();
      expect(
        entries!.map((DownloadTaskEntry entry) => entry.id).toSet(),
        hasLength(4),
      );
      final BuildContext context = tester.element(find.byType(Scaffold));
      expect(entries!.first.builder(context), isA<DownloadTaskCard>());
    },
  );
}
