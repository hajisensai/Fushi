// 蓝光盘入库的合集对号（PR #1604 审查）：合集不能只按盘名全局对号。
//
// 盘名在无 META 时就是目录名，而压制 / 抓取出来的盘目录名极常见是 `DISC1` / `BDROM`
// / `Vol.1`——一个系列多卷就是 `S1/DISC1/BDMV` 与 `S2/DISC1/BDMV`。若第二张盘被对到
// 第一张的合集上，两张盘的 `00001.mpls` 基身份相同被判「已是成员」、第一张独有的标题
// 被移出，每次重扫按盘顺序把成员翻一遍。这里用真 Drift 库 + 真临时目录铺两张同名盘
// 走完整条扫描，钉住「各自一条合集、重扫成员不动」。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../video/bluray_fixture.dart';

/// 立刻失败的 ffmpeg 后端：导入路径不该起 ffmpeg，起了也不能等真超时。
class _NoFfmpeg implements FfmpegBackend {
  /// 查询类命令（BUG-2938 新增原语）：本假件不区分，交给 [run]。
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');
}

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

Future<SourceLibraryRow> _videoSource(FushiDatabase db, String root) async {
  final int id = await db.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Vids',
      mediaKind: 'video',
      rootPath: root,
      createdAt: 1000,
    ),
  );
  return (await db.getMediaSourceById(id))!;
}

/// 在 [root] 下铺一张盘：每个 [clips] 一条整段用满的标题，时长取 [secondsOf]
/// （缺省 1500 秒）。
void _writeDisc(
  String root,
  List<String> clips, {
  Map<String, int> secondsOf = const <String, int>{},
}) {
  for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
    Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
  }
  for (int i = 0; i < clips.length; i++) {
    final String clip = clips[i];
    const int start = 45000 * 4;
    final int seconds = secondsOf[clip] ?? 1500;
    File(
      p.join(root, 'BDMV', 'PLAYLIST', '0000${i + 1}.mpls'),
    ).writeAsBytesSync(
      buildMplsFixture(
        playItems: <FixturePlayItem>[
          FixturePlayItem(
            clipId: clip,
            inTimeTicks: start,
            outTimeTicks: start + 45000 * seconds,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: start),
        ],
      ),
    );
    File(p.join(root, 'BDMV', 'CLIPINF', '$clip.clpi')).writeAsBytesSync(
      buildClpiFixture(
        presentationStartTicks: start,
        presentationEndTicks: start + 45000 * seconds,
      ),
    );
    File(
      p.join(root, 'BDMV', 'STREAM', '$clip.m2ts'),
    ).writeAsBytesSync(Uint8List(4096));
  }
}

/// 在 [root] 下写一条播放列表 [id]：按顺序由 [items]（片段号, 秒）拼成；片段
/// 文件（clpi + m2ts）一并铺好，重复的片段只写一次。
void _writePlaylist(String root, String id, List<(String, int)> items) {
  for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
    Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
  }
  const int start = 45000 * 4;
  File(p.join(root, 'BDMV', 'PLAYLIST', '$id.mpls')).writeAsBytesSync(
    buildMplsFixture(
      playItems: <FixturePlayItem>[
        for (final (String clip, int seconds) in items)
          FixturePlayItem(
            clipId: clip,
            inTimeTicks: start,
            outTimeTicks: start + 45000 * seconds,
          ),
      ],
      marks: const <FixtureMark>[
        FixtureMark(playItemIndex: 0, timestampTicks: start),
      ],
    ),
  );
  for (final (String clip, int seconds) in items) {
    File(p.join(root, 'BDMV', 'CLIPINF', '$clip.clpi')).writeAsBytesSync(
      buildClpiFixture(
        presentationStartTicks: start,
        presentationEndTicks: start + 45000 * seconds,
      ),
    );
    File(
      p.join(root, 'BDMV', 'STREAM', '$clip.m2ts'),
    ).writeAsBytesSync(Uint8List(4096));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_bluray_');
    setFfmpegBackendForTesting(_NoFfmpeg());
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => p.join(tmp.path, 'documents'),
            'getTemporaryDirectory' => p.join(tmp.path, 'systemp'),
            'getApplicationSupportDirectory' => p.join(tmp.path, 'support'),
            _ => null,
          },
        );
  });
  tearDown(() {
    setFfmpegBackendForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    AppPaths.debugResetDocumentsLayoutCache();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Set<String>>> membersByCollection(FushiDatabase db) async {
    final VideoBookRepository repo = VideoBookRepository(db);
    final Map<String, Set<String>> result = <String, Set<String>>{};
    for (final MediaCollectionRow c in await repo.getAllMediaCollections()) {
      if (c.collectionType != 'playlist') continue;
      final Set<String> paths = <String>{};
      for (final MediaCollectionItemRow item in await repo.getCollectionItems(
        c.id,
      )) {
        final VideoBookRow? row = await repo.getByBookUid(item.entryKey);
        if (row != null) paths.add(p.normalize(row.videoPath));
      }
      result[c.name] = paths;
    }
    return result;
  }

  test('两张目录同名的盘各自一条合集，重扫成员不互相吞', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final String disc1 = p.join(tmp.path, 'S1', 'DISC1');
    final String disc2 = p.join(tmp.path, 'S2', 'DISC1');
    // 第一张三条标题、第二张两条：同名对号时第二张会把第一张独有的 00003 移出。
    _writeDisc(disc1, <String>['00011', '00012', '00013']);
    _writeDisc(disc2, <String>['00021', '00022']);

    final SourceLibraryScanner scanner = SourceLibraryScanner(db);
    final SourceScanSummary first = await scanner.scan(
      await _videoSource(db, tmp.path),
    );
    expect(first.succeeded, isTrue, reason: first.error ?? '');

    final Map<String, Set<String>> members = await membersByCollection(db);
    expect(members.keys, unorderedEquals(<String>['DISC1', 'DISC1 (S2)']));
    expect(members['DISC1'], <String>{
      for (final String n in <String>['00001', '00002', '00003'])
        p.normalize(p.join(disc1, 'BDMV', 'PLAYLIST', '$n.mpls')),
    });
    expect(members['DISC1 (S2)'], <String>{
      for (final String n in <String>['00001', '00002'])
        p.normalize(p.join(disc2, 'BDMV', 'PLAYLIST', '$n.mpls')),
    });

    // 重扫：对回各自的合集，成员一条不动、不新建第三条。
    final SourceScanSummary second = await scanner.scan(
      await _videoSource(db, tmp.path),
    );
    expect(second.succeeded, isTrue, reason: second.error ?? '');
    final Map<String, Set<String>> again = await membersByCollection(db);
    expect(again, members);
  });

  // 原盘菜单首版（2026-10-08）给「只能从菜单进入的特典」手写建行：没有来源、名字
  // 写成「盘目录名 · 00003」。刮削的每道入口都按来源挑条目，这一行在结构上永远刮
  // 不到（用户：「这个都是bd了，为什么还能没刮削出来」）。特典现在按扫描导入的
  // 规则入库：带来源、名字取盘名、**不进盘合集**（挂在正片作品下）。
  group('盘上的特典按扫描导入的规则入库', () {
    late FushiDatabase db;
    late SourceLibraryRow source;
    late String disc;
    late String bonus;

    setUp(() async {
      db = _memDb();
      disc = p.join(tmp.path, 'Kaguya', 'DISC2');
      // 两条正片 + 一条 60 秒特典：特典低于相对时长下限，不是标题。
      _writeDisc(
        disc,
        <String>['00011', '00012', '00013'],
        secondsOf: const <String, int>{'00013': 60},
      );
      bonus = p.join(disc, 'BDMV', 'PLAYLIST', '00003.mpls');
      source = await _videoSource(db, tmp.path);
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');
    });
    tearDown(() => db.close());

    Future<Set<String>> discMembers() async =>
        (await membersByCollection(db))['DISC2']!;

    test('扫描直接导入特典：带来源、名字取盘名、不进盘合集', () async {
      final VideoBookRow row = (await VideoBookRepository(
        db,
      ).findByVideoPath(bonus))!;
      expect(row.sourceId, source.id);
      expect(row.title, 'DISC2 - 00003');
      expect(await discMembers(), isNot(contains(p.normalize(bonus))));
    });

    test('菜单进入同一特典幂等：不重复建行、不进合集；重扫照旧', () async {
      final VideoBookRow scanned = (await VideoBookRepository(
        db,
      ).findByVideoPath(bonus))!;
      final VideoBookRow again = (await ensureBlurayTitleInLibrary(db, bonus))!;
      expect(again.bookUid, scanned.bookUid);
      final SourceScanSummary rescan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(rescan.succeeded, isTrue, reason: rescan.error ?? '');
      final List<VideoBookRow> onBonus = <VideoBookRow>[
        for (final VideoBookRow b in await VideoBookRepository(db).listAll())
          if (p.equals(b.videoPath, bonus)) b,
      ];
      expect(onBonus, hasLength(1));
      expect(onBonus.single.sourceId, source.id);
      expect(await discMembers(), isNot(contains(p.normalize(bonus))));
    });

    test('首版建出的无来源孤儿行自愈：补来源、改回盘名', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow scanned = (await repo.findByVideoPath(bonus))!;
      await repo.updateTitle(scanned.bookUid, 'DISC2 · 00003');
      await db.customStatement(
        'UPDATE video_books SET source_id = NULL WHERE book_uid = ?',
        <Object?>[scanned.bookUid],
      );
      final VideoBookRow healed = (await ensureBlurayTitleInLibrary(
        db,
        bonus,
      ))!;
      expect(healed.bookUid, scanned.bookUid);
      expect(healed.sourceId, source.id);
      expect(healed.title, 'DISC2 - 00003');
    });

    test('用户改过的标题不被覆盖', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow scanned = (await repo.findByVideoPath(bonus))!;
      await repo.updateTitle(scanned.bookUid, '制作特辑');
      final VideoBookRow row = (await ensureBlurayTitleInLibrary(db, bonus))!;
      expect(row.title, '制作特辑');
    });

    test('标题从菜单补进合集时，收了本盘标题的 m3u8 清单合集不算盘合集', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final String second = p.join(disc, 'BDMV', 'PLAYLIST', '00002.mpls');
      final VideoBookRow main = (await repo.findByVideoPath(
        p.join(disc, 'BDMV', 'PLAYLIST', '00001.mpls'),
      ))!;
      await repo.saveVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/other',
          title: 'other',
          videoPath: p.join(tmp.path, 'other.mkv'),
          importedAt: const Value<int?>(1),
        ),
      );
      // 盘合集清空（移空自删），只剩一个混着别处文件的清单合集收着本盘正片：
      // 它不是这张盘，标题不能被塞进去。
      for (final MediaCollectionRow c in await repo.getAllMediaCollections()) {
        if (c.name != 'DISC2') continue;
        for (final MediaCollectionItemRow item in await repo.getCollectionItems(
          c.id,
        )) {
          await db.removeFromCollection(c.id, MediaKind.video, item.entryKey);
        }
      }
      final int mixed = await db.createMediaCollection(
        'mixed',
        collectionType: 'playlist',
      );
      await db.addToCollection(mixed, MediaKind.video, main.bookUid);
      await db.addToCollection(mixed, MediaKind.video, 'video/other');

      final VideoBookRow row = (await ensureBlurayTitleInLibrary(db, second))!;
      expect(row.sourceId, source.id);
      final List<String> mixedMembers = <String>[
        for (final MediaCollectionItemRow item in await repo.getCollectionItems(
          mixed,
        ))
          item.entryKey,
      ];
      expect(mixedMembers, isNot(contains(row.bookUid)));
    });
  });

  // 用户截图：原盘菜单里有「特典映像」，作品资料页却只有正片一集。实测盘（Disc 1）：
  // 00000 = 18 秒警告 / 厂标，00001 = 正片，00002 = 5 段拼成的 7.8 分钟特典，
  // 01001 = 同一段 m2ts 连排 7 次的菜单背景。特典要进库并挂到正片下，两种垃圾不进。
  test('真实盘形状：特典进库挂到正片下，警告与菜单背景循环不进库', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final String disc = p.join(tmp.path, 'Kaguya', 'Disc 1');
    _writePlaylist(disc, '00000', <(String, int)>[('00009', 9), ('00010', 9)]);
    _writePlaylist(disc, '00001', <(String, int)>[('00001', 8430)]);
    _writePlaylist(disc, '00002', <(String, int)>[
      ('00002', 90),
      ('00003', 90),
      ('00006', 100),
      ('00007', 100),
      ('00008', 88),
    ]);
    _writePlaylist(disc, '01001', <(String, int)>[
      for (int i = 0; i < 7; i++) ('00013', 93),
    ]);
    final SourceLibraryRow source = await _videoSource(db, tmp.path);
    final SourceScanSummary scan = await SourceLibraryScanner(db).scan(source);
    expect(scan.succeeded, isTrue, reason: scan.error ?? '');

    String mpls(String id) => p.join(disc, 'BDMV', 'PLAYLIST', '$id.mpls');
    final VideoBookRepository repo = VideoBookRepository(db);
    expect(await repo.findByVideoPath(mpls('00000')), isNull);
    expect(await repo.findByVideoPath(mpls('01001')), isNull);
    final VideoBookRow main = (await repo.findByVideoPath(mpls('00001')))!;
    final VideoBookRow extra = (await repo.findByVideoPath(mpls('00002')))!;
    expect(extra.sourceId, source.id);
    // 单片盘仍是单成员合集：特典不进合集，卡片 / 封面口径不变。
    expect((await membersByCollection(db))['Disc 1'], <String>{
      p.normalize(mpls('00001')),
    });
    // 扫描末尾的索引把特典挂到正片作品下：作品资料页的特典区读的就是这张表。
    final VideoMetadataWorkRow work = (await db.getVideoMetadataWorkByBook(
      main.bookUid,
    ))!;
    expect(
      (await db.getVideoMetadataExtraByBook(extra.bookUid))?.workId,
      work.id,
    );
  });

  // PR #2058 审查：特典入库原先排在合集墓碑守卫之前——删掉整盘合集后重扫，特典
  // 照样复活；单独删掉的特典没有任何墓碑，重扫也会回来。
  group('删除过的盘 / 特典重扫不复活', () {
    late FushiDatabase db;
    late SourceLibraryRow source;
    late String disc;

    String mpls(String id) => p.join(disc, 'BDMV', 'PLAYLIST', '$id.mpls');

    setUp(() async {
      db = _memDb();
      disc = p.join(tmp.path, 'Kaguya', 'Disc 1');
      _writePlaylist(disc, '00001', <(String, int)>[('00001', 8430)]);
      _writePlaylist(disc, '00002', <(String, int)>[
        ('00002', 90),
        ('00003', 90),
        ('00006', 100),
      ]);
      _writePlaylist(disc, '00004', <(String, int)>[('00004', 200)]);
      source = await _videoSource(db, tmp.path);
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');
      final VideoBookRepository repo = VideoBookRepository(db);
      expect(await repo.findByVideoPath(mpls('00002')), isNotNull);
      expect(await repo.findByVideoPath(mpls('00004')), isNotNull);
    });
    tearDown(() => db.close());

    test('删掉整盘合集（连同条目）后重扫：标题与特典都不复活', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final MediaCollectionRow collection =
          (await repo.getAllMediaCollections()).singleWhere(
            (MediaCollectionRow c) => c.name == 'Disc 1',
          );
      await db.deleteMediaCollection(collection.id);
      await repo.deleteVideoBooks(<String>[
        for (final VideoBookRow row in await repo.listAll()) row.bookUid,
      ]);

      final SourceScanSummary rescan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(rescan.succeeded, isTrue, reason: rescan.error ?? '');
      expect(await repo.listAll(), isEmpty);
    });

    test('单独删掉一条特典后重扫：它不回来，其余照旧', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow extra = (await repo.findByVideoPath(mpls('00002')))!;
      final VideoLibraryDeleteResult result =
          await deleteVideoBooksWithDecision(
            repo: repo,
            database: db,
            pipeline: null,
            bookUids: <String>[extra.bookUid],
            decision: const DeleteDecision(scope: DeleteScope.keepLocalOnly),
            compactDatabase: false,
          );
      expect(result.deleted, 1);

      final SourceScanSummary rescan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(rescan.succeeded, isTrue, reason: rescan.error ?? '');
      expect(await repo.findByVideoPath(mpls('00002')), isNull);
      expect(await repo.findByVideoPath(mpls('00004')), isNotNull);
      expect(await repo.findByVideoPath(mpls('00001')), isNotNull);
      expect((await membersByCollection(db))['Disc 1'], <String>{
        p.normalize(mpls('00001')),
      });
    });
  });

  // 用户截图「好像到外面了」：旧版本从菜单进特典时建的孤儿行（无来源、名字「Disc 1 ·
  // 00002」）单独躺在库首层。启动回填的索引要认领它们，开一次 app 就自愈。
  test('启动索引认领旧版本留下的蓝光孤儿行：补来源、改回盘名、挂到正片下', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final String disc = p.join(tmp.path, 'Kaguya', 'Disc 1');
    _writePlaylist(disc, '00001', <(String, int)>[('00001', 8430)]);
    _writePlaylist(disc, '00002', <(String, int)>[
      ('00002', 90),
      ('00003', 90),
      ('00006', 100),
    ]);
    final SourceLibraryRow source = await _videoSource(db, tmp.path);
    final SourceScanSummary scan = await SourceLibraryScanner(db).scan(source);
    expect(scan.succeeded, isTrue, reason: scan.error ?? '');

    final VideoBookRepository repo = VideoBookRepository(db);
    final String extraPath = p.join(disc, 'BDMV', 'PLAYLIST', '00002.mpls');
    final VideoBookRow extra = (await repo.findByVideoPath(extraPath))!;
    // 还原成旧版本的样子：无来源、首版自动名、没挂到任何作品下。
    await repo.updateTitle(extra.bookUid, 'Disc 1 · 00002');
    await db.customStatement(
      'UPDATE video_books SET source_id = NULL WHERE book_uid = ?',
      <Object?>[extra.bookUid],
    );
    await db.customStatement(
      'DELETE FROM video_metadata_extras WHERE book_uid = ?',
      <Object?>[extra.bookUid],
    );

    final VideoSourceMetadataIndexer indexer = VideoSourceMetadataIndexer(db);
    expect(await indexer.index(source), isTrue);

    final VideoBookRow healed = (await repo.getByBookUid(extra.bookUid))!;
    expect(healed.sourceId, source.id);
    expect(healed.title, 'Disc 1 - 00002');
    final VideoBookRow main = (await repo.findByVideoPath(
      p.join(disc, 'BDMV', 'PLAYLIST', '00001.mpls'),
    ))!;
    final VideoMetadataWorkRow work = (await db.getVideoMetadataWorkByBook(
      main.bookUid,
    ))!;
    expect(
      (await db.getVideoMetadataExtraByBook(extra.bookUid))?.workId,
      work.id,
    );
    // 没有孤儿了：再跑一遍零写入（启动回填据此决定刷不刷新库页）。
    expect(await indexer.index(source), isFalse);
  });

  // 用户：31 分钟的 00002 被当成整部电影刮（media_type=movie、runtime=143）。盘名就是
  // 片名，盘上每条标题各自拿去识别，特辑必然认成正片。特典要像 NCOP 一样不单独成
  // 作品、挂到同盘正片的作品下。
  group('电影盘的特典不单独成作品，挂到正片下', () {
    late FushiDatabase db;
    late SourceLibraryRow source;
    late String disc;

    String mpls(String root, String id) =>
        p.join(root, 'BDMV', 'PLAYLIST', '$id.mpls');

    setUp(() async {
      db = _memDb();
      disc = p.join(tmp.path, 'Movie', 'DISC2');
      // 正片 1500 秒 + 300 秒特辑（20%，扫描选中）+ 60 秒菜单特典（扫描不选）。
      _writeDisc(
        disc,
        <String>['00011', '00012', '00013'],
        secondsOf: const <String, int>{'00012': 300, '00013': 60},
      );
      source = await _videoSource(db, tmp.path);
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');
      await ensureBlurayTitleInLibrary(db, mpls(disc, '00003'));
    });
    tearDown(() => db.close());

    test('刮削计划只有正片一个作品单元', () async {
      final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
        db,
      ).plan(source);
      final List<String> planned = <String>[
        for (final VideoSourceScrapeWork work in works)
          for (final VideoBookRow member in work.members)
            p.normalize(member.videoPath),
      ];
      expect(planned, <String>[p.normalize(mpls(disc, '00001'))]);
    });

    test('索引把特典绑到正片作品下，并清掉旧版误建的「电影」作品', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow featurette = (await repo.findByVideoPath(
        mpls(disc, '00002'),
      ))!;
      // 旧版本把 00002 当独立电影刮过：一份 book-owned 的错误规范作品。
      await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: Value<String?>(featurette.bookUid),
          mediaType: 'movie',
          title: 'DISC2',
          updatedAt: 1,
        ),
      );

      await VideoSourceMetadataIndexer(db).index(source);

      final VideoBookRow main = (await repo.findByVideoPath(
        mpls(disc, '00001'),
      ))!;
      final VideoMetadataWorkRow mainWork = (await db
          .getVideoMetadataWorkByBook(main.bookUid))!;
      for (final String id in <String>['00002', '00003']) {
        final VideoBookRow extra = (await repo.findByVideoPath(
          mpls(disc, id),
        ))!;
        expect(
          await db.getVideoMetadataWorkByBook(extra.bookUid),
          isNull,
          reason: '$id 不能有自己的规范作品',
        );
        final VideoMetadataExtraRow? bound = await db
            .getVideoMetadataExtraByBook(extra.bookUid);
        expect(bound?.workId, mainWork.id, reason: '$id 应挂在正片作品下');
      }
    });

    // PR #2058 审查：正片不在库（用户删了正片行）时，特典既不进计划、也挂不上任何
    // 作品。现在最长的那条特典顶上当父项照常刮削，其余特典挂到它下面。
    test('正片不在库：最长的特典顶上进计划，其余特典挂到它下面', () async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoBookRow main = (await repo.findByVideoPath(
        mpls(disc, '00001'),
      ))!;
      await repo.deleteVideoBooks(<String>[main.bookUid]);

      final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
        db,
      ).plan(source);
      expect(
        <String>[
          for (final VideoSourceScrapeWork work in works)
            for (final VideoBookRow member in work.members)
              p.normalize(member.videoPath),
        ],
        <String>[p.normalize(mpls(disc, '00002'))],
      );

      await VideoSourceMetadataIndexer(db).index(source);
      final VideoBookRow featurette = (await repo.findByVideoPath(
        mpls(disc, '00002'),
      ))!;
      final VideoBookRow menuExtra = (await repo.findByVideoPath(
        mpls(disc, '00003'),
      ))!;
      final VideoMetadataWorkRow work = (await db.getVideoMetadataWorkByBook(
        featurette.bookUid,
      ))!;
      expect(
        (await db.getVideoMetadataExtraByBook(menuExtra.bookUid))?.workId,
        work.id,
      );
    });

    // PR #2058 审查：「比最长标题短一半即特典」会把剧集盘正片判成特典——一条
    // 50 分钟特别篇让 25 分钟的各集全部低于一半，不刮削。
    test('剧集盘带一条长特别篇：各集与特别篇都照常进计划', () async {
      final String series = p.join(tmp.path, 'Series', 'VOL2');
      _writeDisc(
        series,
        <String>['00031', '00032', '00033', '00034', '00035'],
        secondsOf: const <String, int>{'00035': 3000},
      );
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');
      final Set<String> planned = <String>{
        for (final VideoSourceScrapeWork work in await VideoSourceWorkPlanner(
          db,
        ).plan(source))
          for (final VideoBookRow member in work.members)
            p.normalize(member.videoPath),
      };
      for (final String id in <String>[
        '00001',
        '00002',
        '00003',
        '00004',
        '00005',
      ]) {
        expect(planned, contains(p.normalize(mpls(series, id))), reason: id);
      }
    });

    test('剧集盘各集同一量级：都不是特典，照常各自进计划', () async {
      final String series = p.join(tmp.path, 'Series', 'VOL1');
      _writeDisc(series, <String>['00021', '00022', '00023']);
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');
      final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
        db,
      ).plan(source);
      final Set<String> planned = <String>{
        for (final VideoSourceScrapeWork work in works)
          for (final VideoBookRow member in work.members)
            p.normalize(member.videoPath),
      };
      for (final String id in <String>['00001', '00002', '00003']) {
        expect(planned, contains(p.normalize(mpls(series, id))));
      }
    });
  });

  // 同一部作品的几张盘刮削出来是同一张海报，书架上分不出哪张是哪张。盘内
  // `BDMV/META/DL` 带着厂商给的盘面图：按图本身解码出的朝向分流——竖图做合集
  // 主封面（竖卡墙），横图进附加图组 disc_art（只给横向槽位），不把横图垫进竖卡。
  group('原盘盘面图按横竖分流', () {
    late FushiDatabase db;
    late String disc;
    late Directory dl;

    List<int> jpeg(int width, int height) =>
        img.encodeJpg(img.Image(width: width, height: height));

    /// 写一份 `bdmt_<lang>.xml` 与其中的图（文件名 → 字节）。声明的 size 故意
    /// 写成与实际相反：朝向只认解码结果。
    void writeMeta(String lang, Map<String, List<int>> images) {
      for (final MapEntry<String, List<int>> e in images.entries) {
        File(p.join(dl.path, e.key)).writeAsBytesSync(e.value);
      }
      File(p.join(dl.path, 'bdmt_$lang.xml')).writeAsStringSync(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<disclib xmlns="urn:BDA:bdmv;disclib">'
        '<di:discinfo xmlns:di="urn:BDA:bdmv;discinfo">'
        '<di:title><di:name>KAGUYA</di:name></di:title>'
        '<di:description>'
        '${images.keys.map((String n) => '<di:thumbnail href="./$n" size="9x16" />').join()}'
        '</di:description></di:discinfo></disclib>',
      );
    }

    Future<MediaCollectionRow> discCollection() async =>
        (await db.getAllMediaCollections()).singleWhere(
          (MediaCollectionRow c) => c.collectionType == 'playlist',
        );

    Future<String?> discArt(int collectionId) async =>
        (await db.getMediaImagesForCollection(collectionId))
            .where((MediaImageRow r) => r.kind == 'disc_art')
            .map((MediaImageRow r) => r.path)
            .firstOrNull;

    Future<SourceLibraryRow> scanOnce() async {
      final SourceLibraryRow source = await _videoSource(db, tmp.path);
      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
      ).scan(source);
      expect(summary.succeeded, isTrue, reason: summary.error ?? '');
      return source;
    }

    setUp(() {
      db = _memDb();
      disc = p.join(tmp.path, 'Kaguya', 'Disc 1');
      _writeDisc(disc, <String>['00011', '00012']);
      dl = Directory(p.join(disc, 'BDMV', 'META', 'DL'))
        ..createSync(recursive: true);
      LocaleSettings.setLocale(AppLocale.en);
    });

    tearDown(() async {
      LocaleSettings.setLocale(AppLocale.en);
      await db.close();
    });

    test('竖图：做合集主封面（取最大的竖图），不进横向槽', () async {
      final List<int> big = jpeg(40, 60);
      writeMeta('eng', <String, List<int>>{
        'S.jpg': jpeg(20, 30),
        'P.jpg': big,
      });
      await scanOnce();
      final MediaCollectionRow c = await discCollection();
      expect(File(c.coverPath!).readAsBytesSync(), big);
      expect(p.isWithin(disc, c.coverPath!), isFalse, reason: '复制进封面目录');
      expect(await discArt(c.id), isNull);
    });

    test('横图：只进 disc_art，竖卡封面不动（回落刮削海报）', () async {
      final List<int> wide = jpeg(64, 36);
      writeMeta('eng', <String, List<int>>{
        'S.jpg': jpeg(32, 18),
        'L.jpg': wide,
      });
      await scanOnce();
      final MediaCollectionRow c = await discCollection();
      expect(c.coverPath, isNull);
      final String art = (await discArt(c.id))!;
      expect(File(art).readAsBytesSync(), wide);
      expect(p.isWithin(disc, art), isFalse, reason: '复制进封面目录');
    });

    test('同时有横竖：各归各位', () async {
      final List<int> tall = jpeg(40, 60);
      final List<int> wide = jpeg(64, 36);
      writeMeta('eng', <String, List<int>>{'P.jpg': tall, 'L.jpg': wide});
      await scanOnce();
      final MediaCollectionRow c = await discCollection();
      expect(File(c.coverPath!).readAsBytesSync(), tall);
      expect(File((await discArt(c.id))!).readAsBytesSync(), wide);
    });

    test('语言跟界面语言：界面日文取 jpn 那份，界面英文取 eng 那份', () async {
      final List<int> jpnArt = jpeg(64, 36);
      final List<int> engArt = jpeg(80, 45);
      writeMeta('jpn', <String, List<int>>{'J.jpg': jpnArt});
      writeMeta('eng', <String, List<int>>{'E.jpg': engArt});
      LocaleSettings.setLocale(AppLocale.ja);
      await scanOnce();
      final int id = (await discCollection()).id;
      expect(File((await discArt(id))!).readAsBytesSync(), jpnArt);
    });

    test('界面语言盘上没有：按盘上的文件名顺序取第一份', () async {
      final List<int> engArt = jpeg(64, 36);
      writeMeta('jpn', <String, List<int>>{'J.jpg': jpeg(80, 45)});
      writeMeta('eng', <String, List<int>>{'E.jpg': engArt});
      LocaleSettings.setLocale(AppLocale.ko);
      await scanOnce();
      final int id = (await discCollection()).id;
      expect(File((await discArt(id))!).readAsBytesSync(), engArt);
    });

    test('老合集重扫补上；用户手选的封面与已有盘面图都不被覆盖', () async {
      final List<int> tall = jpeg(40, 60);
      writeMeta('eng', <String, List<int>>{
        'P.jpg': tall,
        'L.jpg': jpeg(64, 36),
      });
      final SourceLibraryRow source = await scanOnce();
      final int id = (await discCollection()).id;
      // 本功能之前导入的老库：两处都是空的。
      await db.updateMediaCollectionCoverPath(id, null);
      await (db.delete(
        db.mediaImages,
      )..where(($MediaImagesTable t) => t.collectionId.equals(id))).go();
      final SourceLibraryScanner scanner = SourceLibraryScanner(db);
      expect((await scanner.scan(source)).succeeded, isTrue);
      expect((await discCollection()).id, id, reason: '重扫对回同一合集');
      expect(File((await discCollection()).coverPath!).readAsBytesSync(), tall);
      final String art = (await discArt(id))!;

      final String picked = p.join(tmp.path, 'picked.jpg');
      File(picked).writeAsBytesSync(jpeg(3, 5));
      await db.updateMediaCollectionCoverPath(id, picked);
      expect((await scanner.scan(source)).succeeded, isTrue);
      expect((await discCollection()).coverPath, picked);
      expect(await discArt(id), art);
    });

    test('盘面图解不开：扫描照常成功，什么都不写', () async {
      writeMeta('eng', <String, List<int>>{
        'bad.jpg': <int>[9, 8, 7],
      });
      await scanOnce();
      final MediaCollectionRow c = await discCollection();
      expect(c.coverPath, isNull);
      expect(await discArt(c.id), isNull);
    });

    test('盘上没有 META 图：什么都不写，照旧回落刮削图', () async {
      dl.deleteSync(recursive: true);
      await scanOnce();
      final MediaCollectionRow c = await discCollection();
      expect(c.coverPath, isNull);
      expect(await discArt(c.id), isNull);
    });
  });
}
