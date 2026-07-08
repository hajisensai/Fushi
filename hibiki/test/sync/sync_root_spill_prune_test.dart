import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

// BUG-619 re-report / TODO-1340: per-book metadata/cover files that spilled
// directly into the sync root (from the old empty-title `ensureBookFolder('')`
// collapse) accumulate into many duplicate copies ("丢很多份"). TODO-1329
// stopped new spills at the source but never cleaned the residue. These tests
// pin the sweep contract: every `progress_*` / `statistics_*` / `audioBook_*` /
// `cover_*` file sitting as a DIRECT child of the root is deleted, while book
// folders, reserved namespaces, nested (legitimate) per-book files, and
// unrelated root files are left untouched.

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// A stray root-level file name of each ttu per-book type, plus one cover.
const String _spilledProgress = 'progress_1_6_1700000000000_0.5.json';
const String _spilledAudioBook = 'audioBook_1_6_1700000001111_42.0.json';
const String _spilledStatistics =
    'statistics_1_6_1700000000000_100_60_0_0_0_0_0_0_0_0_0_0_na.json';
const String _spilledCover = 'cover_1_6.jpeg';

void main() {
  group('isTtuPerBookFileName (root-spill predicate)', () {
    test('matches every per-book metadata/cover file name', () {
      expect(isTtuPerBookFileName(_spilledProgress), isTrue);
      expect(isTtuPerBookFileName(_spilledAudioBook), isTrue);
      expect(isTtuPerBookFileName(_spilledStatistics), isTrue);
      expect(isTtuPerBookFileName(_spilledCover), isTrue);
      expect(isTtuPerBookFileName('cover_1_6.png'), isTrue);
      expect(isTtuPerBookFileName('cover_1_6.webp'), isTrue);
    });

    test('does NOT match book folders, packages or unrelated files', () {
      // A real book's folder name (a sanitized title) is not a per-book file.
      expect(isTtuPerBookFileName('屍人荘の殺人'), isFalse);
      expect(isTtuPerBookFileName('progress notes.txt'), isFalse);
      // Reserved namespaces + package assets live in the root but are not
      // per-book ttu files.
      expect(isTtuPerBookFileName('__dictionaries__'), isFalse);
      expect(isTtuPerBookFileName('audiobook.hibikiaudio'), isFalse);
      expect(isTtuPerBookFileName('mydict.hibikidict'), isFalse);
      // Wrong schema marker / a title that merely starts with a type word.
      expect(isTtuPerBookFileName('progress_2_0_x.json'), isFalse);
      expect(isTtuPerBookFileName('progression.json'), isFalse);
    });
  });

  group('SyncOrchestrator.pruneRootSpill', () {
    late Directory work;
    setUp(() async {
      work = await Directory.systemTemp.createTemp('root_spill_');
    });
    tearDown(() async {
      if (work.existsSync()) await work.delete(recursive: true);
    });

    Future<void> seedFile(
      FakeAssetStore store,
      String namespace,
      String name,
    ) async {
      final File tmp = File('${work.path}/blob')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await store.putAsset(namespace, name, tmp);
    }

    test('deletes only the spilled root files, keeps folders + nested + others',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // Spilled per-book files sitting directly in the root.
      await seedFile(store, 'root', _spilledProgress);
      await seedFile(store, 'root', _spilledAudioBook);
      await seedFile(store, 'root', _spilledStatistics);
      await seedFile(store, 'root', _spilledCover);
      // A duplicate spilled progress with a different churned timestamp — the
      // "丢很多份" case: every copy must go, not just the first.
      await seedFile(store, 'root', 'progress_1_6_1699000000000_0.4.json');

      // Things that MUST survive: a real book folder, a nested legitimate
      // per-book file, reserved namespaces, and an unrelated root file.
      await store.ensureFolder('root', '屍人荘の殺人');
      await seedFile(store, 'root/屍人荘の殺人', _spilledProgress);
      await store.ensureFolder('root', '__dictionaries__');
      await store.ensureFolder('root', '__local_audio__');
      await seedFile(store, 'root', 'notes.txt');

      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final SyncOrchestrator orchestrator = SyncOrchestrator(
        db: db,
        backend: FakeSyncBackend(store),
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
        syncLocalAudio: false,
      );

      final SyncRunReport report = SyncRunReport();
      await orchestrator.pruneRootSpill('root', report);

      expect(report.rootSpillFilesRemoved, 5,
          reason: 'all four types + the duplicate progress copy are swept');
      expect(report.errors, isEmpty);

      final List<AssetEntry> rootChildren = await store.listChildren('root');
      final Set<String> rootNames =
          rootChildren.map((AssetEntry e) => e.name).toSet();
      // No per-book file remains directly in the root.
      expect(
        rootNames.any(isTtuPerBookFileName),
        isFalse,
        reason: 'root must hold no per-book metadata/cover file',
      );
      // Folders + unrelated file survive.
      expect(rootNames, containsAll(<String>['屍人荘の殺人', 'notes.txt']));
      // Nested legitimate per-book file inside the book folder is untouched.
      final AssetEntry? nested =
          await store.findAsset('root/屍人荘の殺人', _spilledProgress);
      expect(nested, isNotNull,
          reason: 'a per-book file inside its own folder is legitimate');
    });

    test('clean root is a no-op (idempotent)', () async {
      final FakeAssetStore store = FakeAssetStore();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      await store.ensureFolder('root', 'Normal Book');

      final Directory tmp = Directory('${work.path}/tmp')..createSync();
      final SyncOrchestrator orchestrator = SyncOrchestrator(
        db: db,
        backend: FakeSyncBackend(store),
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
        syncLocalAudio: false,
      );

      final SyncRunReport report = SyncRunReport();
      await orchestrator.pruneRootSpill('root', report);
      expect(report.rootSpillFilesRemoved, 0);
      expect(report.errors, isEmpty);
    });
  });
}
