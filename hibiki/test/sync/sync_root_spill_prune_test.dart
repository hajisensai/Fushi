import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_core/fushi_core.dart';

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

    test('matches title-PREFIXED spill (slash-less folderId fusion, BUG-845)',
        () {
      // A book folderId cached without its trailing slash fuses the file name
      // onto the title: `<root>/屍人荘の殺人` + `audioBook_1_6_….json` becomes a
      // root-level `屍人荘の殺人audioBook_1_6_….json`. The marker is matched
      // anywhere in the name, so these are swept too.
      expect(isTtuPerBookFileName('屍人荘の殺人$_spilledAudioBook'), isTrue);
      expect(isTtuPerBookFileName('屍人荘の殺人$_spilledProgress'), isTrue);
      expect(isTtuPerBookFileName('屍人荘の殺人$_spilledStatistics'), isTrue);
      expect(isTtuPerBookFileName('屍人荘の殺人$_spilledCover'), isTrue);
      // A title with punctuation still fuses and is still caught.
      expect(isTtuPerBookFileName('A B.C!cover_1_6.png'), isTrue);
      // But a bare title with no fused marker is still safe.
      expect(isTtuPerBookFileName('屍人荘の殺人progression.json'), isFalse);
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

    test('sweeps title-PREFIXED spill while keeping the book folder (BUG-845)',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // The book folder is intact; the slash-less folderId fusion left several
      // churned title-prefixed audioBook copies as direct root children.
      await store.ensureFolder('root', '屍人荘の殺人');
      await seedFile(store, 'root/屍人荘の殺人', _spilledAudioBook);
      await seedFile(store, 'root', '屍人荘の殺人$_spilledAudioBook');
      await seedFile(store, 'root',
          '屍人荘の殺人audioBook_1_6_1700000009999_43.5.json');
      await seedFile(store, 'root', '屍人荘の殺人$_spilledCover');

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

      expect(report.rootSpillFilesRemoved, 3,
          reason: 'every title-prefixed root spill copy is swept');
      expect(report.errors, isEmpty);

      final Set<String> rootNames = (await store.listChildren('root'))
          .map((AssetEntry e) => e.name)
          .toSet();
      // The book folder survives; no title-prefixed spill remains at root.
      expect(rootNames, contains('屍人荘の殺人'));
      expect(rootNames.any(isTtuPerBookFileName), isFalse);
      // The legitimate in-folder file is untouched.
      final AssetEntry? nested =
          await store.findAsset('root/屍人荘の殺人', _spilledAudioBook);
      expect(nested, isNotNull);
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

    // TODO-1346「书架/视频进度好像没了」根因排查守卫。用户上报进度疑似丢失，怀疑本
    // 云端根目录清扫会误删合法进度。定论：进度真值只在本地 Drift（reader_positions /
    // video_books.playlist_json）里，而 pruneRootSpill 只操作 *云端* root 的直接子
    // *文件*。这两条断言把该安全契约钉死，防止未来把清扫谓词放宽到会碰文件夹 / 本地库：
    //   (1) `isFolder` 永远优先于名字——即使某本书的 sanitized 标题恰好撞上 per-book
    //       文件名（`progress_1_6_...`），它作为文件夹绝不能被当成溢出删掉（书文件夹里
    //       正是该书的真实进度 / 封面）。
    //   (2) 一次 pruneRootSpill 后，本地 DB 的阅读位置与视频进度一字不动。
    test(
        'never deletes a folder colliding with the spill name, and leaves local '
        'DB reading/video progress intact (TODO-1346)', () async {
      final FakeAssetStore store = FakeAssetStore();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // 本地真值进度：一条阅读位置（章内精确 charOffset）+ 一个多集视频（进度都在
      // playlist_json 各集 positionMs / current_episode，last_position_ms 对播放列表
      // 恒为 0——与用户 DB 现象一致）。
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookKey: const Value('安達としまむら2'),
          sectionIndex: const Value(12),
          normCharOffset: const Value(8334),
          charOffset: const Value(12981),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      await db.upsertVideoBook(
        const VideoBooksCompanion(
          bookUid: Value('video/playlist/K-ON! 全集列表'),
          title: Value('K-ON!'),
          videoPath: Value(''),
          currentEpisode: Value(47),
          playlistJson: Value(
              '[{"title":"ep47","path":"/ep47.mp4","positionMs":633174}]'),
        ),
      );

      // 一个真会被清掉的溢出文件，加一个 *名字撞谓词但本体是文件夹* 的书文件夹。
      await seedFile(store, 'root', _spilledProgress);
      await store.ensureFolder('root', 'progress_1_6_collides_as_folder');
      await seedFile(
          store, 'root/progress_1_6_collides_as_folder', _spilledProgress);

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

      // 只删了那一个溢出裸文件；名字撞谓词的文件夹被 `isFolder` 守卫放过。
      expect(report.rootSpillFilesRemoved, 1);
      expect(report.errors, isEmpty);
      final Set<String> rootNames = (await store.listChildren('root'))
          .map((AssetEntry e) => e.name)
          .toSet();
      expect(rootNames, contains('progress_1_6_collides_as_folder'),
          reason: 'a folder must never be swept, even if its name matches the '
              'per-book file pattern');
      final AssetEntry? nested = await store.findAsset(
          'root/progress_1_6_collides_as_folder', _spilledProgress);
      expect(nested, isNotNull,
          reason: 'files inside a book folder are legitimate progress');

      // 本地库进度一字未动：阅读位置精确 charOffset + 视频按集进度都在。
      final ReaderPositionRow? pos = await db.getReaderPosition('安達としまむら2');
      expect(pos, isNotNull);
      expect(pos!.charOffset, 12981);
      expect(pos.sectionIndex, 12);
      final VideoBookRow? vb =
          await db.getVideoBookByBookUid('video/playlist/K-ON! 全集列表');
      expect(vb, isNotNull);
      expect(vb!.currentEpisode, 47);
      expect(vb.playlistJson, contains('633174'));
    });
  });
}
