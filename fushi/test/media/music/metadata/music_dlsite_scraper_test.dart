import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/metadata/music_dlsite_scraper.dart';
import 'package:fushi/src/pages/implementations/music/music_album_dlsite_section.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/metadata/image_download.dart'
    show ImageDownloadException;
import 'package:fushi_engine/media/music/metadata/music_dlsite_album.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _rj = 'RJ01109339';

/// product.json 的最小真实形状（字段名照 2026-10 实测响应）。
String _product(String workno, {int age = 1}) =>
    jsonEncode(<Map<String, Object?>>[
      <String, Object?>{
        'workno': workno,
        'work_name': '耳舐め&耳ふーサンドイッチ',
        'maker_name': 'チームランドセル',
        'work_type': 'SOU',
        'work_type_string': 'ボイス・ASMR',
        'regist_date': '2024-05-01 16:00:00',
        'age_category': age,
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
    'wishlist_count': 777,
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
  late bool coverFails;

  /// product.json 的 `age_category`（1 全年龄 / 2 R-15 / 3 成人向）。
  late int age;

  /// 每次下载主图时回调（测试在「在途」时插入取消等动作）。
  late void Function(String url)? onDownload;

  /// 每次取时钟时回调（测试在「判定之后、写入之前」插入并发落库）。
  late void Function()? onClock;

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
            utf8.encode(notFound ? '[]' : _product(workno, age: age)),
            200,
          );
        }
        return http.Response.bytes(utf8.encode(_rating(workno)), 200);
      }),
    ),
    downloadImage: (String url) async {
      onDownload?.call(url);
      if (coverFails) {
        throw const ImageDownloadException('image download HTTP 404');
      }
      // 与真下载器一致：临时文件一律 `.img`，格式只能看主图 URL。
      final File f = File('${tmp.path}/dl_${url.hashCode}.img');
      await f.writeAsBytes(<int>[1, 2, 3]);
      return f;
    },
    coverDirectory: () async => Directory('${tmp.path}/covers'),
    clock: () {
      onClock?.call();
      return 42;
    },
  );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('music_dlsite_test');
    requests = <Uri>[];
    notFound = false;
    coverFails = false;
    age = 1;
    onDownload = null;
    onClock = null;
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

  test('主图下载失败：资料照常落库、专辑不挂封面，下次再取会重试补图', () async {
    coverFails = true;
    final MusicDlsiteAlbumInfo? info = await scraper().scrapeAlbum('asmr');
    expect(info!.snapshot!.work, isNotNull);
    expect((await db.getMusicAlbum('asmr'))!.coverPath, isNull);

    coverFails = false;
    await scraper().scrapeAlbum('asmr');
    expect(
      (await db.getMusicAlbum('asmr'))!.coverPath,
      endsWith('dlsite_$_rj.jpg'),
    );
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

  group('R-18 作品默认 NSFW（拍板台 NCzkl6oLnf-adult-cover）', () {
    Future<bool> nsfw(String uid) =>
        db.isMediaNsfw(TagHostKind.musicAlbum, uid);

    test('成人向：专辑标成 NSFW，主图照补；全年龄 / R-15 不标', () async {
      age = 3;
      await scraper().scrapeAlbum('asmr');
      expect(await nsfw('asmr'), isTrue);
      expect(
        (await db.getMusicAlbum('asmr'))!.coverPath,
        endsWith('dlsite_$_rj.jpg'),
        reason: '封面照补，交给「模糊 NSFW 封面」管',
      );
      expect(
        (await db.mediaNsfwClock(TagHostKind.musicAlbum, 'asmr')).nsfwAt,
        42,
        reason: '戳取注入的时钟',
      );

      age = 2;
      await scraper().scrapeAlbum('embedded');
      expect(await nsfw('embedded'), isFalse);
      expect(await nsfw('plain'), isFalse);
    });

    test('有内嵌封面不补图时也按分级标（曲目自带的封面同样是 R-18）', () async {
      age = 3;
      await scraper().scrapeAlbum('embedded');
      expect((await db.getMusicAlbum('embedded'))!.coverPath, isNull);
      expect(await nsfw('embedded'), isTrue);
    });

    test('用户取消过 NSFW：重取资料 / 整库识别都不再标回去', () async {
      age = 3;
      await scraper().scrapeAlbum('asmr');
      await db.setMediaNsfw(TagHostKind.musicAlbum, 'asmr', false);
      await scraper().scrapeAlbum('asmr');
      expect(await nsfw('asmr'), isFalse);
      await scraper().scrapeLibrary();
      expect(await nsfw('asmr'), isFalse);
    });

    test('自动标记与并发取消：取消在判定之后落库，自动标记不得凭更晚的戳盖回去（HBK-AUDIT-216）', () async {
      age = 3;
      await scraper().scrapeAlbum('embedded');
      // 回到「从没决定过」：资料已缓存，整库识别时走缓存命中补标。
      await db.delete(db.mediaNsfwFlags).go();
      bool fired = false;
      onClock = () {
        if (fired) return;
        fired = true;
        // 用户 / 互联在自动标记取时钟的同一刻落库取消（戳 10 早于自动标记的 42）。
        unawaited(
          db.setMediaNsfw(TagHostKind.musicAlbum, 'embedded', false, at: 10),
        );
      };
      await scraper().scrapeLibrary();
      expect(fired, isTrue);
      expect(await nsfw('embedded'), isFalse);
      expect(await db.mediaNsfwClock(TagHostKind.musicAlbum, 'embedded'), (
        nsfwAt: null,
        clearedAt: 10,
      ));
    });

    test('markMediaNsfwIfUndecided：只写从没决定过的宿主，设过 / 取消过的原样不动', () async {
      await db.markMediaNsfwIfUndecided(TagHostKind.musicAlbum, 'new', at: 5);
      expect(await db.mediaNsfwClock(TagHostKind.musicAlbum, 'new'), (
        nsfwAt: 5,
        clearedAt: null,
      ));
      await db.markMediaNsfwIfUndecided(TagHostKind.musicAlbum, 'new', at: 9);
      expect(
        (await db.mediaNsfwClock(TagHostKind.musicAlbum, 'new')).nsfwAt,
        5,
        reason: '已标过不再推进戳',
      );
      await db.setMediaNsfw(TagHostKind.musicAlbum, 'off', false, at: 3);
      await db.markMediaNsfwIfUndecided(TagHostKind.musicAlbum, 'off', at: 9);
      expect(await db.mediaNsfwClock(TagHostKind.musicAlbum, 'off'), (
        nsfwAt: null,
        clearedAt: 3,
      ));
    });

    test('整库：同一部作品的几张专辑都标；已取过资料的专辑在整库识别时补标', () async {
      age = 3;
      // 先只取一张，模拟「早先取过资料、那时还不会标」：清掉它的标记行。
      await scraper().scrapeAlbum('embedded');
      await db.delete(db.mediaNsfwFlags).go();
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('t5', 'asmr-bonus', '/asmr/$_rj 耳舐め/特典/01.mp3'),
          ],
          albums: <MusicAlbumsCompanion>[_album('asmr-bonus', '特典')],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      await scraper().scrapeLibrary();
      for (final String uid in <String>['asmr', 'asmr-bonus', 'embedded']) {
        expect(await nsfw(uid), isTrue, reason: uid);
      }
    });
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

  test('整库：同一部作品分在两张专辑里，资料只取一次，两张专辑的封面都补上', () async {
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          _track('t5', 'asmr-bonus', '/asmr/$_rj 耳舐め/特典/01.mp3'),
        ],
        albums: <MusicAlbumsCompanion>[_album('asmr-bonus', '特典')],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    final MusicDlsiteLibraryReport r = await scraper().scrapeLibrary();
    expect(r.total, 2, reason: '$_rj（两张专辑）+ RJ299717');
    final List<String> productHits = <String>[
      for (final Uri u in requests)
        if (u.path.endsWith('product.json')) u.queryParameters['workno']!,
    ];
    expect(productHits.where((String w) => w == _rj).length, 1);
    for (final String uid in <String>['asmr', 'asmr-bonus']) {
      expect(
        (await db.getMusicAlbum(uid))!.coverPath,
        endsWith('dlsite_$_rj.jpg'),
        reason: '$uid 没有自己的封面，补 DLsite 主图',
      );
    }
  });

  test('整库：缓存命中的第一张补图在途时取消，第二张不再下载、不补图、不标 NSFW（HBK-AUDIT-229）', () async {
    const String rj2 = 'RJ01000001';
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          _track('t6', 'asmr2', '/asmr/$rj2 囁き/01.mp3'),
        ],
        albums: <MusicAlbumsCompanion>[_album('asmr2', '囁き')],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    age = 3;
    // 先把两部作品的资料取进缓存，主图那次下不来；再清掉标记，回到「待补」状态。
    coverFails = true;
    await scraper().scrapeAlbum('asmr');
    await scraper().scrapeAlbum('asmr2');
    coverFails = false;
    await db.delete(db.mediaNsfwFlags).go();
    requests.clear();

    bool cancelled = false;
    final List<String> downloads = <String>[];
    onDownload = (String url) {
      downloads.add(url);
      cancelled = true; // 第一张主图还在下载时用户点了取消。
    };
    final MusicDlsiteLibraryReport r = await scraper().scrapeLibrary(
      cancelled: () => cancelled,
    );
    expect(r.total, 1, reason: '只有 embedded（RJ299717）没取过资料');
    expect(requests, isEmpty, reason: '取消之后也不再联网取 embedded');
    expect(downloads, hasLength(1), reason: '取消之后不再下载第二张主图');
    final List<String> covered = <String>[
      for (final String uid in <String>['asmr', 'asmr2'])
        if ((await db.getMusicAlbum(uid))!.coverPath != null) uid,
    ];
    final List<String> marked = <String>[
      for (final String uid in <String>['asmr', 'asmr2'])
        if (await db.isMediaNsfw(TagHostKind.musicAlbum, uid)) uid,
    ];
    expect(covered, hasLength(1), reason: '只有在途的那张落地');
    expect(marked, hasLength(1), reason: '取消后不再写 NSFW');
    expect(marked, covered, reason: '落地的那张先标后补');
  });

  test('整库：DLsite 网络失败只记 failed，不抛出', () async {
    final MusicDlsiteScraper s = MusicDlsiteScraper(
      database: () => db,
      locale: () => 'ja_JP',
      clientFactory: (String locale) => DlsiteClient(
        locale: locale,
        minRequestInterval: Duration.zero,
        client: MockClient(
          (_) async => throw const HandshakeException('handshake failed'),
        ),
      ),
      coverDirectory: () async => Directory('${tmp.path}/covers'),
      clock: () => 42,
    );
    final MusicDlsiteLibraryReport r = await s.scrapeLibrary();
    expect(r.total, 2);
    expect(r.failed, 2);
    expect(r.matched, 0);
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
    expect(values, contains('777'), reason: '收藏数');
    expect(values, contains('★ 4.50 · 120 ratings'));
    expect(values.any((String v) => v.contains('120')), isTrue);
    expect(musicDlsiteFacts(info.id, null).length, 1, reason: '没资料只出编号');
  });
}
