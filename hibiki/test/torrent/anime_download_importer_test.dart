/// 番剧下载入库封面（BUG-1393 / BUG-1394）+ added 活动事件（BUG-1416）。
///
/// 用户 2026-08-02：作品海报只落合集自有封面，不借道首集条目——多集合集的子篇不得
/// 顶着作品级竖版海报。同时钉住落盘走统一收口（`MediaCoverService.applyCoverBytes`
/// 的原子 `.tmp`+rename）：`reuseExistingPaths` 重放会覆盖同名文件，裸 writeAsBytes
/// 不驱逐解码缓存就是 BUG-1118 的形状。
///
/// BUG-1416：下载完成自动入库以前一条 `added` 活动事件都不记，首页时间轴看不到番剧
/// 入库。补记的同时必须扛住崩溃重放——`reuseExistingPaths` 让重放复用既有条目/合集，
/// 幂等判据只能是 `createdEpisodeUids`（本次真新建的集），不是时间窗、不是去重表。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/anime_download_importer.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart'
    show AnimeDownloadImportOutcome;
import 'package:hibiki/src/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:hibiki/src/utils/misc/hibiki_time_format.dart'
    show HibikiTimeFormat;
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 最小合法 PNG 魔数字节。
const List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
];

AnimeDownloadPlan _plan({String? coverUrl}) => AnimeDownloadPlan(
      id: 'plan-1',
      createdAtMs: 0,
      seriesTitle: '某番剧',
      torrentTitle: '[组] 某番剧 01-02',
      magnet: 'magnet:?xt=urn:btih:deadbeef',
      qbCategory: 'hibiki',
      anilistId: 42,
      coverUrl: coverUrl,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late Directory tmp;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('anime_dl_importer_');
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<AnimeDownloadImportOutcome?> Function(
    AnimeDownloadPlan,
    List<String>,
  ) importer({List<int> bytes = _fakePng}) => buildAnimeDownloadImporter(
        db,
        httpClient: MockClient(
          (http.Request req) async => http.Response.bytes(
            bytes,
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          ),
        ),
        collectionCoversDirectory: tmp,
      );

  test('作品海报落合集自有封面 coverPath，成员条目一张海报都不沾', () async {
    final AnimeDownloadImportOutcome? outcome = await importer()(
      _plan(coverUrl: 'https://img.anili.st/poster.jpg'),
      <String>[
        p.join('D:', 'dl', '某番剧 - 01.mkv'),
        p.join('D:', 'dl', '某番剧 - 02.mkv'),
      ],
    );

    expect(outcome, isNotNull);
    final MediaCollectionRow col =
        (await db.getMediaCollectionById(outcome!.collectionId))!;
    final String expectedCover =
        p.join(tmp.path, videoCoverFileName('${outcome.collectionId}'));
    expect(col.coverPath, expectedCover, reason: '海报直落合集自有封面列');
    expect(File(expectedCover).readAsBytesSync(), _fakePng);

    // 成员条目（含首集）不落作品海报——测试环境抽帧不可用，封面应保持 null，
    // 而绝不是那张下载成功了的海报。
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(outcome.collectionId);
    expect(items, hasLength(2));
    for (final MediaCollectionItemRow item in items) {
      final VideoBookRow book =
          (await db.getVideoBookByBookUid(item.entryKey))!;
      expect(book.coverPath, isNull, reason: '子篇条目封面只能是抽帧/剧照，绝不是作品海报');
    }

    // AniList 绑定照旧。
    expect(col.anilistId, 42);
  });

  test('无海报 URL：合集 coverPath 保持空，不误写', () async {
    final AnimeDownloadImportOutcome? outcome = await importer()(
      _plan(),
      <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')],
    );

    expect(outcome, isNotNull);
    expect((await db.getMediaCollectionById(outcome!.collectionId))!.coverPath,
        isNull);
  });

  test('重放导入覆盖同名合集封面：内容真被换掉（收口的原子写，非裸 writeAsBytes）', () async {
    const List<int> jpeg = <int>[0xFF, 0xD8, 0xFF, 0xAA, 0xBB];
    final AnimeDownloadImportOutcome? first = await importer()(
      _plan(coverUrl: 'https://img.anili.st/poster.jpg'),
      <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')],
    );
    final String dest =
        p.join(tmp.path, videoCoverFileName('${first!.collectionId}'));
    expect(File(dest).readAsBytesSync(), _fakePng);

    // reuseExistingPaths 让重放复用同一合集 → 同一目标文件名。
    final AnimeDownloadImportOutcome? second = await importer(bytes: jpeg)(
      _plan(coverUrl: 'https://img.anili.st/poster.jpg'),
      <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')],
    );
    expect(second!.collectionId, first.collectionId);
    expect(File(dest).readAsBytesSync(), jpeg);
    expect(File('$dest.tmp').existsSync(), isFalse, reason: '收口写不留 .tmp');
  });

  // ── BUG-1416：added 活动事件 ───────────────────────────────────────────
  //
  // 幂等判据钉在「本次真新建了集」上（SplitPlaylistImportResult.createdEpisodeUids），
  // 不是时间窗、不是合集是否已存在。四条用例分别守：真新增记 1 条 / 崩溃重放不重记 /
  // 字段值域走 ActivityMediaKind 不是裸字符串 / 同系列后续新集仍算真新增。

  Future<List<ActivityEventRow>> addedEvents() =>
      db.getRecentActivityEvents(eventTypes: <String>[kActivityAdded]);

  test('下载入库真新增：整本记 1 条 added（title=系列名、mediaKey=首集 uid）', () async {
    final AnimeDownloadImportOutcome? outcome = await importer()(
      _plan(),
      <String>[
        p.join('D:', 'dl', '某番剧 - 01.mkv'),
        p.join('D:', 'dl', '某番剧 - 02.mkv'),
      ],
    );
    expect(outcome, isNotNull);

    final List<ActivityEventRow> events = await addedEvents();
    expect(events, hasLength(1), reason: '多集合集整本 1 条，绝不每集一条');
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(outcome!.collectionId);
    expect(events.single.title, '某番剧');
    expect(events.single.mediaKey, items.first.entryKey,
        reason: 'mediaKey=首集 uid');
  });

  test('崩溃重放（同批路径重跑复用既有条目）：不重复记 added', () async {
    final List<String> paths = <String>[
      p.join('D:', 'dl', '某番剧 - 01.mkv'),
      p.join('D:', 'dl', '某番剧 - 02.mkv'),
    ];
    await importer()(_plan(), paths);
    expect(await addedEvents(), hasLength(1));

    // 进程在 DB 提交后、计划 flag 回写前崩溃 → 重启原样重放同一批路径。
    await importer()(_plan(), paths);
    expect(
      await addedEvents(),
      hasLength(1),
      reason: '一集都没新建（全部复用既有路径）→ 一条都不该再记',
    );
  });

  test('added 事件的 media_type 落 ActivityMediaKind.video，不是裸字符串', () async {
    await importer()(_plan(), <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')]);

    final ActivityEventRow row = (await addedEvents()).single;
    expect(row.eventType, kActivityAdded);
    expect(
      ActivityMediaKind.tryParse(row.mediaType),
      ActivityMediaKind.video,
      reason: 'media_type 必须是活动域枚举的 video 落库值，不得写成 MediaKind 的名字',
    );
    expect(row.durationMs, isNull, reason: 'added 无时长');
    expect(row.charsDelta, isNull, reason: 'added 无字符增量');
    expect(
      row.dateKey,
      HibikiTimeFormat.dayKey(
        DateTime.fromMillisecondsSinceEpoch(row.timestampMs),
      ),
      reason: 'dateKey 必须与 timestampMs 同一时刻派生',
    );
  });

  test('同系列后续批次带来新集：真新增，再记 1 条（幂等判据不是「合集已存在」）', () async {
    await importer()(_plan(), <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')]);
    expect(await addedEvents(), hasLength(1));

    // 同 seriesTitle → 复用既有合集，但 02 是全新的集。
    await importer()(_plan(), <String>[
      p.join('D:', 'dl', '某番剧 - 01.mkv'),
      p.join('D:', 'dl', '某番剧 - 02.mkv'),
    ]);
    expect(await addedEvents(), hasLength(2), reason: '真有新集进来就是真新增');
  });

  test('响应不是图片（错误页 HTML）：不落盘、合集 coverPath 保持空', () async {
    final AnimeDownloadImportOutcome? outcome =
        await buildAnimeDownloadImporter(
      db,
      httpClient: MockClient(
        (http.Request req) async => http.Response(
          '<html>404</html>',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        ),
      ),
      collectionCoversDirectory: tmp,
    )(
      _plan(coverUrl: 'https://img.anili.st/poster.jpg'),
      <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')],
    );

    expect(outcome, isNotNull);
    expect((await db.getMediaCollectionById(outcome!.collectionId))!.coverPath,
        isNull);
    expect(
      File(p.join(tmp.path, videoCoverFileName('${outcome.collectionId}')))
          .existsSync(),
      isFalse,
    );
  });
}
