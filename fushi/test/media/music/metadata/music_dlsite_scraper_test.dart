import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/metadata/music_dlsite_scraper.dart';
import 'package:fushi/src/pages/implementations/music/music_album_dlsite_section.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/music/metadata/music_dlsite_album.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _rj = 'RJ01109339';

/// product.json 的最小真实形状（字段名照 2026-10 实测响应）。
String _product(String workno) => jsonEncode(<Map<String, Object?>>[
  <String, Object?>{
    'workno': workno,
    'work_name': '耳舐め&耳ふーサンドイッチ',
    'maker_name': 'チームランドセル',
    'work_type': 'SOU',
    'work_type_string': 'ボイス・ASMR',
    'regist_date': '2024-05-01 16:00:00',
    'age_category': 1,
    'genres': <Map<String, Object?>>[
      <String, Object?>{'name': '癒し'},
      <String, Object?>{'name': '耳かき'},
    ],
    'creaters': <String, Object?>{
      'voice_by': <Map<String, Object?>>[
        <String, Object?>{'name': '耳恋なか'},
        <String, Object?>{'name': 'そよかぜみらい'},
      ],
    },
    'image_main': <String, Object?>{
      'url': '//img.dlsite.jp/modpub/images2/work/doujin/$workno.jpg',
    },
  },
]);

String _rating(String workno) => jsonEncode(<String, Object?>{
  workno: <String, Object?>{
    'rate_average_2dp': 4.5,
    'rate_count': 120,
    'dl_count': 3000,
  },
});

MusicTracksCompanion _track(
  String uid,
  String album,
  String path, {
  bool embeddedCover = false,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: path,
  title: uid,
  albumUid: Value<String?>(album),
  hasEmbeddedCover: Value<bool>(embeddedCover),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

MusicAlbumsCompanion _album(String uid, String title) =>
    MusicAlbumsCompanion.insert(
      albumUid: uid,
      title: title,
      addedAt: 1,
      updatedAt: 1,
    );

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late List<Uri> requests;
  late bool notFound;

  MusicDlsiteScraper scraper() => MusicDlsiteScraper(
    database: () => db,
    locale: () => 'ja_JP',
    clientFactory: (String locale) => DlsiteClient(
      locale: locale,
      minRequestInterval: Duration.zero,
      client: MockClient((http.Request req) async {
        requests.add(req.url);
        final String workno =
            req.url.queryParameters['workno'] ??
            req.url.queryParameters['product_id'] ??
            '';
        if (req.url.path.endsWith('product.json')) {
          return http.Response.bytes(
            utf8.encode(notFound ? '[]' : _product(workno)),
            200,
          );
        }
        return http.Response.bytes(utf8.encode(_rating(workno)), 200);
      }),
    ),
    downloadImage: (String url) async {
      final File f = File('${tmp.path}/dl_${url.hashCode}.jpg');
      await f.writeAsBytes(<int>[1, 2, 3]);
      return f;
    },
    coverDirectory: () async => Directory('${tmp.path}/covers'),
    clock: () => 42,
  );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('music_dlsite_test');
    requests = <Uri>[];
    notFound = false;
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          _track('t1', 'asmr', '/asmr/$_rj 耳舐め/mp3/01.mp3'),
          _track('t2', 'asmr', '/asmr/$_rj 耳舐め/mp3/02.mp3'),
          _track('t3', 'plain', '/music/Lemon/01.flac'),
          _track(
            't4',
            'embedded',
            '/asmr/RJ299717/01.mp3',
            embeddedCover: true,
          ),
        ],
        albums: <MusicAlbumsCompanion>[
          _album('asmr', 'mp3'),
          _album('plain', 'Lemon'),
          _album('embedded', 'ねこぐらし'),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('认编号：文件夹里带 RJ 的专辑认得出，普通专辑认不出、也不发请求', () async {
    final MusicDlsiteScraper s = scraper();
    expect((await s.workIdForAlbum('asmr'))?.value, _rj);
    expect(await s.workIdForAlbum('plain'), isNull);
    expect(await s.albumInfo('plain'), isNull);
    expect(await s.scrapeAlbum('plain'), isNull);
    final MusicDlsiteAlbumInfo? before = await s.albumInfo('asmr');
    expect(before?.fetched, isFalse);
    expect(requests, isEmpty);
  });

  test('取资料：原始快照落库、社团 / 声优 / 标签 / 评分解出来，没有封面的专辑补 DLsite 主图', () async {
    final MusicDlsiteAlbumInfo? info = await scraper().scrapeAlbum('asmr');
    expect(info, isNotNull);
    final DlsiteWork work = info!.snapshot!.work!;
    expect(work.circle, 'チームランドセル');
    expect(work.voiceActors, <String>['耳恋なか', 'そよかぜみらい']);
    expect(work.genres, <String>['癒し', '耳かき']);
    expect(work.rating?.count, 120);
    expect(work.rating?.downloads, 3000);
    expect(info.fetchedAt, 42);
    expect(requests.map((Uri u) => u.path), <String>[
      '/maniax/api/=/product.json',
      '/maniax/product/info/ajax',
    ]);

    final MusicMetadataRawSnapshotRow? row = await db.getMusicRawSnapshot(
      provider: 'dlsite',
      snapshotKind: kMusicDlsiteSnapshotKind,
      externalId: _rj,
    );
    expect(row, isNotNull, reason: '快照按作品编号落 music_metadata_raw_snapshots');

    final MusicAlbumRow? album = await db.getMusicAlbum('asmr');
    expect(album!.coverPath, endsWith('dlsite_$_rj.jpg'));
    expect(File(album.coverPath!).existsSync(), isTrue);

    // 再读缓存不发请求。
    requests.clear();
    final MusicDlsiteAlbumInfo? cached = await scraper().albumInfo('asmr');
    expect(cached!.snapshot!.work!.circle, 'チームランドセル');
    expect(requests, isEmpty);
  });

  test('曲目有内嵌封面时不拿 DLsite 主图覆盖', () async {
    await scraper().scrapeAlbum('embedded');
    expect((await db.getMusicAlbum('embedded'))!.coverPath, isNull);
  });

  test('封面上锁时不补图', () async {
    await db
        .into(db.musicLockedFields)
        .insert(
          MusicLockedFieldsCompanion.insert(
            entityKind: 'album',
            entityUid: 'asmr',
            field: 'cover',
            lockedAt: 1,
          ),
        );
    await scraper().scrapeAlbum('asmr');
    expect((await db.getMusicAlbum('asmr'))!.coverPath, isNull);
  });

  test('查无此作：落「取过、没有」的快照，不打评分端点', () async {
    notFound = true;
    final MusicDlsiteAlbumInfo? info = await scraper().scrapeAlbum('asmr');
    expect(info!.fetched, isTrue);
    expect(info.snapshot!.work, isNull);
    expect(requests.length, 1);
  });

  test('整库：只取认得出编号且没取过的专辑，取过的不再请求', () async {
    final MusicDlsiteLibraryReport r1 = await scraper().scrapeLibrary();
    expect(r1.total, 2, reason: 'asmr + embedded；plain 认不出');
    expect(r1.matched, 2);
    expect(r1.failed, 0);
    requests.clear();
    final MusicDlsiteLibraryReport r2 = await scraper().scrapeLibrary();
    expect(r2.total, 0);
    expect(requests, isEmpty);
  });

  test('资料行：编号、社团、声优、类型、发售日、评分（人数）、销量、分级', () async {
    final MusicDlsiteAlbumInfo? info = await scraper().scrapeAlbum('asmr');
    final List<(String, String)> facts = musicDlsiteFacts(
      info!.id,
      info.snapshot!.work,
    );
    final List<String> values = <String>[
      for (final (String, String) f in facts) f.$2,
    ];
    expect(values.first, _rj);
    expect(values, contains('チームランドセル'));
    expect(values, contains('耳恋なか / そよかぜみらい'));
    expect(values, contains('2024-05-01'));
    expect(values, contains('3000'));
    expect(values.any((String v) => v.contains('120')), isTrue);
    expect(musicDlsiteFacts(info.id, null).length, 1, reason: '没资料只出编号');
  });
}
