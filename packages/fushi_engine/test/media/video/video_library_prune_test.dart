import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/source_library/library_prune_guard.dart';
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

      final LibraryPruneReport report = await pruneMissingVideoRows(
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

      final LibraryPruneReport report = await pruneMissingVideoRows(
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
      // 25 条候选、20 条缺失：超过 ratio 0.5 且超过 absoluteFloor 10。
      // 留 5 个真文件，免得先被「库根空了」那道护栏拦下。
      for (int i = 0; i < 5; i++) {
        final String path = p.join(root.path, 'here$i.mkv');
        File(path).writeAsStringSync('x');
        await addVideo(path);
      }
      for (int i = 0; i < 20; i++) {
        await addVideo(p.join(root.path, 'v$i.mkv'));
      }

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.skipped, isTrue);
      expect(report.deleted, 0);
      expect(report.skipReason, contains('exceeds threshold'));
      expect(await repo.listAll(), hasLength(25));
    });

    test('库根在但一个视频都没有（空挂载点）→ 小库也不删', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      // 两条，低于比例护栏的绝对下限——没有这道门就会整库删光。
      await addVideo(p.join(root.path, 'a.mkv'));
      await addVideo(p.join(root.path, 'b.mkv'));

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.skipped, isTrue);
      expect(report.skipReason, contains('no video files'));
      expect(await repo.listAll(), hasLength(2));
    });

    test('子目录留下空壳（子挂载点掉线）→ 其下条目不判失效；整个目录删掉 → 判失效', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final String here = p.join(root.path, 'here.mkv');
      File(here).writeAsStringSync('x');
      await addVideo(here);
      // disk2 掉线：挂载点目录还在，但是空的。
      final Directory mount = Directory(p.join(root.path, 'disk2'))
        ..createSync();
      final String onMount = await addVideo(
        p.join(mount.path, 'show', 'ep1.mkv'),
      );
      // 用户把一整季连目录删掉：最近的现存上级是非空的库根。
      final String deletedSeason = await addVideo(
        p.join(root.path, 'season2', 's2e1.mkv'),
      );

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.unreachable, 1);
      expect(report.deleted, 1);
      expect(await db.getVideoBookByBookUid(onMount), isNotNull);
      expect(await db.getVideoBookByBookUid(deletedSeason), isNull);
    });

    test('给了基线：本轮新入库的行不进分母（整库改名不能卡着阈值放行）', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final Set<String> baseline = <String>{};
      // 改名前 20 条，文件已不在旧路径。
      for (int i = 0; i < 20; i++) {
        baseline.add(await addVideo(p.join(root.path, 'A', 'old$i.mkv')));
      }
      // 本轮扫描在新路径下等量入库。
      for (int i = 0; i < 20; i++) {
        final String path = p.join(root.path, 'B', 'new$i.mkv');
        File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
        await addVideo(path);
      }

      // 不给基线：20/40 = 0.5，恰好不越过阈值，旧行全删——这正是要堵的洞。
      final LibraryPruneReport diluted = await pruneMissingVideoRows(
        repository: repo,
        root: root,
        dryRun: true,
      );
      expect(diluted.skipped, isFalse);

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
        baselineBookUids: baseline,
      );
      expect(report.considered, 20);
      expect(report.skipped, isTrue);
      expect(report.skipReason, contains('exceeds threshold'));
      expect(await repo.listAll(), hasLength(40));
    });

    test('多集合集行只看主路径判不了整行失效 → 不动', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final String here = p.join(root.path, 'here.mkv');
      File(here).writeAsStringSync('x');
      await addVideo(here);
      final String uid = await addVideo(p.join(root.path, 'ep1.mkv'));
      await repo.updatePlaylistJson(uid, '["ep1.mkv","ep2.mkv"]');

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.deleted, 0);
      expect(await db.getVideoBookByBookUid(uid), isNotNull);
    });

    test('刮削资料清理在跑（拿不到租约）→ 跳过并如实报告', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      final String here = p.join(root.path, 'here.mkv');
      File(here).writeAsStringSync('x');
      await addVideo(here);
      await addVideo(p.join(root.path, 'gone.mkv'));
      final VideoScrapeOperationLease maintenance =
          VideoScrapeOperationGate.tryEnterMaintenance()!;
      addTearDown(maintenance.release);

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.skipped, isTrue);
      expect(report.skipReason, contains('maintenance'));
      expect(report.missing, 1);
      expect(await repo.listAll(), hasLength(2));
    });

    test('force（显式「移除并清理」）：库根整个删掉了也照清', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      await addVideo(p.join(root.path, 'a.mkv'));
      await addVideo(p.join(root.path, 'b.mkv'));
      root.deleteSync(recursive: true);

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
        force: true,
      );

      expect(report.deleted, 2);
      expect(await repo.listAll(), isEmpty);
    });

    test('force 越过护栏后照删；dryRun 只算不删', () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'fushi_prune_',
      );
      addTearDown(() => root.delete(recursive: true));
      for (int i = 0; i < 20; i++) {
        await addVideo(p.join(root.path, 'v$i.mkv'));
      }

      final LibraryPruneReport dry = await pruneMissingVideoRows(
        repository: repo,
        root: root,
        force: true,
        dryRun: true,
      );
      expect(dry.missing, 20);
      expect(dry.deleted, 0);
      expect(await repo.listAll(), hasLength(20));

      final LibraryPruneReport forced = await pruneMissingVideoRows(
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
      final String keep = p.join(root.path, 'keep.mkv');
      File(keep).writeAsStringSync('x');
      await addVideo(keep);
      final String path = p.join(root.path, 'a.mkv');
      File(path).writeAsStringSync('x');
      await addVideo(path);
      File(path).deleteSync();

      final LibraryPruneReport first = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );
      final LibraryPruneReport second = await pruneMissingVideoRows(
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

      final LibraryPruneReport report = await pruneMissingVideoRows(
        repository: repo,
        root: root,
      );

      expect(report.deleted, 0);
      expect(await repo.listAll(), hasLength(1));
    });
  });
}
