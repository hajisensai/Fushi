import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端库扫描的**对账**：手动删掉视频文件后，重扫要回收「行还在、文件没了」的
/// 条目及其刮削资料。
///
/// 现象出处：部署无头服务端扫描入库后，用户手动删掉视频文件，服务端仍保留原条目与
/// 刮削数据——扫描器此前只增不删（`_scanVideos` 只遍历磁盘上现存的文件）。
void main() {
  late Directory tmp;
  late Directory libraryRoot;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_prune_');
    libraryRoot = Directory(p.join(tmp.path, 'library'))..createSync();
    final ServerPaths paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
    enginePaths = paths;
    // 生产库走 `applyPragmas`（含 `PRAGMA foreign_keys = ON`），刮削资料靠 FK
    // 级联清掉；内存测试库要显式打开同一个 pragma，否则测不到真行为。
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<ScanSummary> scan({bool prune = true}) =>
      LibraryScanner(
        db: db,
        subtitleLanguage: 'ja',
        extractCovers: false,
        pruneMissing: prune,
      ).scanAll(<LibraryRootConfig>[
        LibraryRootConfig(id: 'v', path: libraryRoot.path, kind: 'video'),
      ]);

  test('删掉视频文件后重扫：回收该行与挂在其上的刮削资料', () async {
    final String keep = p.join(libraryRoot.path, 'keep.mkv');
    final String drop = p.join(libraryRoot.path, 'drop.mkv');
    File(keep).writeAsStringSync('x');
    File(drop).writeAsStringSync('x');

    final ScanSummary first = await scan();
    expect(first.videosAdded, 2);
    expect(first.videosPruned, 0);

    final VideoBookRepository repo = VideoBookRepository(db);
    final String dropUid = (await repo.findByVideoPath(drop))!.bookUid;
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: dropUid,
        source: 'tmdb',
        subjectId: '1',
        title: 'dropped',
        scrapedAt: DateTime.now(),
      ),
    );

    File(drop).deleteSync(); // 用户手动删掉视频文件

    final ScanSummary second = await scan();

    expect(second.videosPruned, 1);
    expect(await db.getVideoBookByBookUid(dropUid), isNull);
    expect(await db.getVideoScrapeMeta(dropUid), isNull);
    expect(await repo.findByVideoPath(keep), isNotNull);
  });

  test('pruneMissing: false 时只导入不清理', () async {
    final String drop = p.join(libraryRoot.path, 'drop.mkv');
    File(drop).writeAsStringSync('x');
    await scan();
    File(drop).deleteSync();

    final ScanSummary second = await scan(prune: false);

    expect(second.videosPruned, 0);
    expect(await VideoBookRepository(db).listAll(), hasLength(1));
  });

  test('重扫同一根不产生重复行（去重仍生效）', () async {
    File(p.join(libraryRoot.path, 'a.mkv')).writeAsStringSync('x');

    final ScanSummary first = await scan();
    final ScanSummary second = await scan();

    expect(first.videosAdded, 1);
    expect(second.videosAdded, 0);
    expect(second.videosSkipped, 1);
    expect(await VideoBookRepository(db).listAll(), hasLength(1));
  });
}
