/// 番剧下载入库封面测试（用户 2026-08-02：作品海报只落合集自有封面，不借道
/// 首集条目——多集合集的子篇不得顶着作品级竖版海报）。
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
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 最小合法 PNG 魔数字节。
final List<int> _fakePng = <int>[
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

  test('作品海报落合集自有封面 coverPath，成员条目一张海报都不沾', () async {
    final Future<AnimeDownloadImportOutcome?> Function(
      AnimeDownloadPlan,
      List<String>,
    ) importer = buildAnimeDownloadImporter(
      db,
      httpClient: MockClient(
        (http.Request req) async => http.Response.bytes(_fakePng, 200),
      ),
      collectionCoversDirectory: tmp,
    );

    final AnimeDownloadImportOutcome? outcome = await importer(
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
    expect(File(expectedCover).existsSync(), isTrue);

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
    final Future<AnimeDownloadImportOutcome?> Function(
      AnimeDownloadPlan,
      List<String>,
    ) importer = buildAnimeDownloadImporter(
      db,
      httpClient: MockClient(
        (http.Request req) async => http.Response.bytes(_fakePng, 200),
      ),
      collectionCoversDirectory: tmp,
    );

    final AnimeDownloadImportOutcome? outcome = await importer(
      _plan(),
      <String>[p.join('D:', 'dl', '某番剧 - 01.mkv')],
    );

    expect(outcome, isNotNull);
    final MediaCollectionRow col =
        (await db.getMediaCollectionById(outcome!.collectionId))!;
    expect(col.coverPath, isNull);
  });
}
