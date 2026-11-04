// GBDddvjDsj / BUG-4024（流媒体部分）：网页档每播一集落一本独立流媒体书，这些书不属于
// 任何合集，继续观看 / 视频库里同一部剧按集散开。修复：拿到站点剧集 metadata 时把库里
// 已有的各集收进以剧名为自然键的 playlist 合集（[linkWebVideoSeriesEpisodes]）。
// 本文件锁三层：
// 1. 纯函数：合集名（电影不建）、成员身份与落书同一 uid、槽位季 × 10000 + 集；
// 2. 真 drift 内存库：建 / 复用 / 幂等 / 存量回填 / 墓碑让路，且收编后视频库折叠映射与
//    续播系列上下文（[resolveVideoPlaylistCollectionId]）都落到这个合集；
// 3. 源码守卫：播放页在 metadata 到达与新一集落书两处都调收编（播放页依赖 media_kit /
//    WebView，宿主测试无法实例化）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/netflix_metadata.dart';
import 'package:fushi/src/media/video/url_stream_video.dart'
    show streamVideoBookUid;
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi/src/media/video/web_video_series_collection.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import '../../helpers/source_guard.dart';

FushiDatabase _memoryDb() {
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(db.close);
  return db;
}

const NetflixTitleMetadata _show = NetflixTitleMetadata(
  id: '80100172',
  title: 'Dark',
  isShow: true,
  episodes: <NetflixEpisode>[
    NetflixEpisode(id: '80100173', seasonSeq: 1, seq: 1, title: 'Secrets'),
    NetflixEpisode(id: '80100174', seasonSeq: 1, seq: 2, title: 'Lies'),
    NetflixEpisode(id: '80100175', seasonSeq: 2, seq: 1, title: 'Beginnings'),
  ],
);

String _uid(String watchId) =>
    streamVideoBookUid('https://www.netflix.com/watch/$watchId');

/// 与 `ensureWebVideoEpisodeBook` 同形状的一集流媒体书。
Future<void> _insertEpisode(FushiDatabase db, String watchId) => db
    .into(db.videoBooks)
    .insert(
      VideoBooksCompanion.insert(
        bookUid: _uid(watchId),
        title: 'Netflix · $watchId',
        videoPath: 'https://www.netflix.com/watch/$watchId',
      ),
    );

Future<List<String>> _members(FushiDatabase db, int collectionId) async =>
    <String>[
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        collectionId,
      ))
        item.entryKey,
    ];

/// 视频页「继续观看」/ 卡片归组用的同一张映射。
Future<Map<String, int>> _libraryFold(FushiDatabase db) async =>
    applyVideoFolderCollectionPolicy(
      primary: await db.getPrimaryCollectionIdByEntry(),
      collections: await db.getAllMediaCollections(),
      items: await db.getAllCollectionItems(),
      books: await db.allVideoBooks(),
      sources: await db.getMediaSourcesByKind('video'),
    );

void main() {
  group('纯函数', () {
    test('剧集取剧名作合集名；电影 / 没集 / 没剧名不建合集', () {
      expect(webVideoSeriesCollectionName(_show), 'Dark');
      expect(
        webVideoSeriesCollectionName(
          const NetflixTitleMetadata(
            id: '1',
            title: 'Movie',
            isShow: false,
            episodes: <NetflixEpisode>[],
          ),
        ),
        isNull,
      );
      expect(
        webVideoSeriesCollectionName(
          const NetflixTitleMetadata(
            id: '1',
            title: '  ',
            isShow: true,
            episodes: <NetflixEpisode>[
              NetflixEpisode(id: '2', seasonSeq: 1, seq: 1, title: ''),
            ],
          ),
        ),
        isNull,
      );
    });

    test('成员 uid 与落书同一身份，槽位按季 / 集', () {
      expect(webVideoSeriesMembers(_show), <WebVideoSeriesMember>[
        (bookUid: _uid('80100173'), sortIndex: 10001),
        (bookUid: _uid('80100174'), sortIndex: 10002),
        (bookUid: _uid('80100175'), sortIndex: 20001),
      ]);
    });
  });

  group('linkWebVideoSeriesEpisodes', () {
    test('看过的集收进同一 playlist 合集，按季 / 集排；没看过的集不造书', () async {
      final FushiDatabase db = _memoryDb();
      // 先看了 S2E1 再回头看 S1E1（落书顺序与集序相反）；S1E2 没看过。
      await _insertEpisode(db, '80100175');
      await _insertEpisode(db, '80100173');

      final int? cid = await linkWebVideoSeriesEpisodes(db, _show);

      expect(cid, isNotNull);
      final MediaCollectionRow? col = await db.getMediaCollectionById(cid!);
      expect(col?.name, 'Dark');
      expect(col?.collectionType, 'playlist');
      expect(await _members(db, cid), <String>[
        _uid('80100173'),
        _uid('80100175'),
      ]);
      expect(await db.getVideoBookByBookUid(_uid('80100174')), isNull);
    });

    test('收编后视频库折叠与续播系列上下文都落到这个合集（不再散卡）', () async {
      final FushiDatabase db = _memoryDb();
      final VideoBookRepository repo = VideoBookRepository(db);
      await _insertEpisode(db, '80100173');
      await _insertEpisode(db, '80100174');
      // 修复前：两集都没有合集归属 = 两张散卡、续播无剧集上下文。
      expect(await _libraryFold(db), isEmpty);
      expect(
        await resolveVideoPlaylistCollectionId(
          repo: repo,
          bookUid: _uid('80100174'),
        ),
        isNull,
      );

      final int? cid = await linkWebVideoSeriesEpisodes(db, _show);

      final Map<String, int> fold = await _libraryFold(db);
      expect(fold[MediaKind.video.compositeKey(_uid('80100173'))], cid);
      expect(fold[MediaKind.video.compositeKey(_uid('80100174'))], cid);
      expect(
        await resolveVideoPlaylistCollectionId(
          repo: repo,
          bookUid: _uid('80100174'),
        ),
        cid,
      );
    });

    test('幂等；后看的集按集序插进已有合集', () async {
      final FushiDatabase db = _memoryDb();
      await _insertEpisode(db, '80100173');
      await _insertEpisode(db, '80100175');
      final int? first = await linkWebVideoSeriesEpisodes(db, _show);
      expect(await linkWebVideoSeriesEpisodes(db, _show), first);
      expect(await _members(db, first!), hasLength(2));

      await _insertEpisode(db, '80100174');
      expect(await linkWebVideoSeriesEpisodes(db, _show), first);
      expect(await _members(db, first), <String>[
        _uid('80100173'),
        _uid('80100174'),
        _uid('80100175'),
      ]);
      expect(await db.getAllMediaCollections(), hasLength(1));
    });

    test('库里一集都没有 / 电影：不建合集', () async {
      final FushiDatabase db = _memoryDb();
      expect(await linkWebVideoSeriesEpisodes(db, _show), isNull);
      await db
          .into(db.videoBooks)
          .insert(
            VideoBooksCompanion.insert(
              bookUid: _uid('70000001'),
              title: 'Movie',
              videoPath: 'https://www.netflix.com/watch/70000001',
            ),
          );
      expect(
        await linkWebVideoSeriesEpisodes(
          db,
          const NetflixTitleMetadata(
            id: '70000001',
            title: 'Movie',
            isShow: false,
            episodes: <NetflixEpisode>[],
          ),
        ),
        isNull,
      );
      expect(await db.getAllMediaCollections(), isEmpty);
    });

    test('用户删过这个合集：自动收编不复活它', () async {
      final FushiDatabase db = _memoryDb();
      await _insertEpisode(db, '80100173');
      final int? cid = await linkWebVideoSeriesEpisodes(db, _show);
      await db.deleteMediaCollection(cid!);

      await _insertEpisode(db, '80100174');
      expect(await linkWebVideoSeriesEpisodes(db, _show), isNull);
      expect(await db.getAllMediaCollections(), isEmpty);
    });

    test('用户把某集移出过：不再收回，其余集照收', () async {
      final FushiDatabase db = _memoryDb();
      await _insertEpisode(db, '80100173');
      await _insertEpisode(db, '80100174');
      final int? cid = await linkWebVideoSeriesEpisodes(db, _show);
      await db.removeFromCollection(cid!, MediaKind.video, _uid('80100173'));

      await _insertEpisode(db, '80100175');
      expect(await linkWebVideoSeriesEpisodes(db, _show), cid);
      expect(await _members(db, cid), <String>[
        _uid('80100174'),
        _uid('80100175'),
      ]);
    });
  });

  group('播放页接线（源码守卫）', () {
    final String source = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi/web_source.part.dart',
      ).readAsStringSync(),
    );

    String body(String signature) {
      final int start = source.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0), reason: signature);
      final int next = source.indexOf('\n  void ', start + signature.length);
      final int nextFuture = source.indexOf(
        '\n  Future<',
        start + signature.length,
      );
      final List<int> ends = <int>[
        if (next >= 0) next,
        if (nextFuture >= 0) nextFuture,
      ];
      return source.substring(
        start,
        ends.isEmpty ? source.length : ends.reduce((a, b) => a < b ? a : b),
      );
    }

    test('metadata 到达时收编（顺带回填本修复前散着的集）', () {
      expect(
        body('void _onWebNetflixMetadata('),
        contains('_linkWebSeries(meta)'),
      );
    });

    test('新一集落书后，已有 metadata 就收编这一集', () {
      expect(
        body('Future<void> _bindWebEpisode('),
        contains('_linkWebSeries(boundMeta)'),
      );
    });

    test('收编走共享实现', () {
      expect(
        body('Future<void> _linkWebSeries('),
        contains('linkWebVideoSeriesEpisodes(appModel.database, meta)'),
      );
    });
  });
}
