import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_library_prune.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 库扫描对账：`video_library_prune.dart` 的判据与回收。
///
/// 覆盖三件事，缺一条都会让「删了文件、库里还留着刮削资料」这个现象重新出现：
///   1. 候选范围只认目标库根内的行；
///   2. 失效判据 = 枚举没命中 **且** 文件确实不存在（网络流永不判失效）；
///   3. 删除走既有回收路径（行 + 级联的刮削资料），且护栏拦住危险批次。
void main() {
  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory engineRoot;

  setUp(() {
    // 生产库走 `FushiDatabase._openDb` 的 `applyPragmas`（含 `PRAGMA foreign_keys = ON`），
    // 刮削资料靠 FK 级联清掉；内存测试库要显式打开同一个 pragma，否则测不到真行为。
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    repo = VideoBookRepository(db);
    // 回收阶段（封面 GC）走 `enginePaths`，宿主进程负责装配；测试里装一份固定根。
    engineRoot = Directory.systemTemp.createTempSync('fushi_prune_engine_');
    enginePaths = FixedEnginePaths(
      documents: engineRoot,
      support: engineRoot,
      temp: engineRoot,
    );
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    if (engineRoot.existsSync()) engineRoot.deleteSync(recursive: true);
  });

  Future<String> addVideo(String path) async {
    final String uid = 'video/${p.basename(path)}';
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(p.basenameWithoutExtension(path)),
        videoPath: Value(path),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    return uid;
  }

  group('videoRowsWithinRoot', () {
    test('只认库根内的行，与库根同级的兄弟目录不算', () async {
      await addVideo('/lib/a.mkv');
      await addVideo('/lib/sub/b.mkv');
      await addVideo('/other/c.mkv');
      await addVideo('/libx/d.mkv'); // 前缀相同但不是子路径

      final List<String> got = videoRowsWithinRoot(
        await repo.listAll(),
        '/lib',
      ).map((VideoBookRow r) => r.videoPath).toList()..sort();

      expect(got, <String>['/lib/a.mkv', '/lib/sub/b.mkv']);
    });
  });

  group('selectStaleVideoRows', () {
    test('枚举命中 → 保留；未命中且二次确认不存在 → 失效', () async {
      await addVideo('/lib/present.mkv');
      await addVideo('/lib/gone.mkv');

      final List<VideoBookRow> stale = selectStaleVideoRows(
        candidates: await repo.listAll(),
        foundPaths: <String>{'/lib/present.mkv'},
        exists: (String path) => path != '/lib/gone.mkv',
      );

      expect(stale.map((VideoBookRow r) => r.bookUid), <String>[
        'video/gone.mkv',
      ]);
    });

    test('枚举漏项但文件仍在 → 不判失效（二次确认兜住漏项）', () async {
      await addVideo('/lib/maybe.mkv');

      final List<VideoBookRow> stale = selectStaleVideoRows(
        candidates: await repo.listAll(),
        foundPaths: const <String>{},
        exists: (String path) => true,
      );

      expect(stale, isEmpty);
    });

    test('网络流没有本地文件，永不判失效', () async {
      await addVideo('https://example.com/a.mkv');
      await addVideo('rtsp://example.com/b.mkv');
      await addVideo('anime-source://ext/1/2');

      final List<VideoBookRow> stale = selectStaleVideoRows(
        candidates: await repo.listAll(),
        foundPaths: const <String>{},
        exists: (String path) => false,
      );

      expect(stale, isEmpty);
    });
  });

  group('pruneMissingVideoRows', () {
    test('删掉文件后回收该行与挂在其上的刮削资料', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final String keepPath = p.join(root.path, 'keep.mkv');
      final String dropPath = p.join(root.path, 'drop.mkv');
      File(keepPath).writeAsStringSync('x');
      File(dropPath).writeAsStringSync('x');
      final String keepUid = await addVideo(keepPath);
      final String dropUid = await addVideo(dropPath);
      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: dropUid,
          source: 'tmdb',
          subjectId: '1',
          title: 'dropped',
          scrapedAt: DateTime.now(),
        ),
      );
      await db.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: keepUid,
          source: 'tmdb',
          subjectId: '2',
          title: 'kept',
          scrapedAt: DateTime.now(),
        ),
      );

      File(dropPath).deleteSync(); // 用户手动删掉视频文件

      final VideoPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.deleted, 1);
      expect(report.missing, 1);
      expect(await db.getVideoBookByBookUid(dropUid), isNull);
      expect(await db.getVideoBookByBookUid(keepUid), isNotNull);
      // 刮削资料靠 FK 级联清掉——这正是「文件删了资料还在」的那份数据。
      expect(await db.getVideoScrapeMeta(dropUid), isNull);
      expect(await db.getVideoScrapeMeta(keepUid), isNotNull);
    });

    test('库根不存在时拒绝执行（挂载点掉了不能把整库删光）', () async {
      await addVideo('/mnt/nfs-missing/a.mkv');
      await addVideo('/mnt/nfs-missing/b.mkv');

      final VideoPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: Directory('/mnt/nfs-missing'),
      );

      expect(report.skipped, isTrue);
      expect(report.skipReason, contains('library root missing'));
      expect(report.deleted, 0);
      expect(await repo.listAll(), hasLength(2));
    });

    test('失效占比越过护栏 → 不删，给出原因', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      // 20 条候选、全部缺失：超过 ratio 0.5 且超过 absoluteFloor 10。
      for (int i = 0; i < 20; i++) {
        await addVideo(p.join(root.path, 'v$i.mkv'));
      }

      final VideoPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.skipped, isTrue);
      expect(report.deleted, 0);
      expect(report.skipReason, contains('exceeds threshold'));
      expect(await repo.listAll(), hasLength(20));
    });

    test('force 越过护栏后照删；dryRun 只算不删', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      for (int i = 0; i < 20; i++) {
        await addVideo(p.join(root.path, 'v$i.mkv'));
      }

      final VideoPruneReport dry = await pruneMissingVideoRows(
        repository: repo,
        root: root,
        dryRun: true,
      );
      expect(dry.missing, 20);
      expect(dry.deleted, 0);
      expect(await repo.listAll(), hasLength(20));

      final VideoPruneReport forced = await pruneMissingVideoRows(
        repository: repo,
        root: root,
        force: true,
      );
      expect(forced.deleted, 20);
      expect(await repo.listAll(), isEmpty);
    });

    test('幂等：再跑一次没有可删的', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final String path = p.join(root.path, 'a.mkv');
      File(path).writeAsStringSync('x');
      await addVideo(path);
      File(path).deleteSync();

      final VideoPruneReport first = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );
      final VideoPruneReport second = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(first.deleted, 1);
      expect(second.deleted, 0);
      expect(second.missing, 0);
    });

    test('库根之外的行（下载产物 / 上传副本）不受影响', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final String outside = p.join(
        root.parent.path,
        'downloads/elsewhere.mkv',
      );
      await addVideo(outside);

      final VideoPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.deleted, 0);
      expect(await repo.listAll(), hasLength(1));
    });
  });
}
