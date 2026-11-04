// BUG-4024（本地部分）：侧边栏「继续观看」等入口只传 bookUid 打开播放页，合集里的
// 一集进播放页没有剧集列表。系列上下文改由共享路由入口 [openLocalVideoBook] 按视频库
// 折叠归属自己解析（[resolveVideoPlaylistCollectionId]）。本文件锁两层：
// 1. 解析器与视频库折叠映射同口径（真 drift 内存库）；
// 2. 共享入口在调用方没给合集 id 时必经解析器、侧边栏入口仍走共享入口（源码守卫——
//    播放页依赖 media_kit，宿主测试无法实例化路由）。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_folder_collection_policy.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_folder_group_coordinator.dart';

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

Future<void> _insertBook(
  FushiDatabase db,
  String uid, {
  String? path,
  int? sourceId,
}) => db
    .into(db.videoBooks)
    .insert(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: uid,
        videoPath: path ?? '/videos/$uid.mkv',
        sourceId: Value(sourceId),
      ),
    );

/// 视频页「继续观看」/ 卡片归组用的同一张映射（home_video_page.dart 加载库映射处）。
Future<Map<String, int>> _libraryFold(FushiDatabase db) async =>
    applyVideoFolderCollectionPolicy(
      primary: await db.getPrimaryCollectionIdByEntry(),
      collections: await db.getAllMediaCollections(),
      items: await db.getAllCollectionItems(),
      books: await db.allVideoBooks(),
      sources: await db.getMediaSourcesByKind('video'),
    );

void main() {
  group('resolveVideoPlaylistCollectionId', () {
    test('合集成员解析到其合集；散片解析为 null；查无此片为 null', () async {
      final FushiDatabase db = _memoryDb();
      final VideoBookRepository repo = VideoBookRepository(db);
      await _insertBook(db, 'ep1');
      await _insertBook(db, 'ep2');
      await _insertBook(db, 'movie');
      final int cid = await db.createMediaCollection(
        'Show',
        collectionType: 'playlist',
      );
      await db.addToCollection(cid, MediaKind.video, 'ep1', userIntent: false);
      await db.addToCollection(cid, MediaKind.video, 'ep2', userIntent: false);

      expect(
        await resolveVideoPlaylistCollectionId(repo: repo, bookUid: 'ep2'),
        cid,
      );
      expect(
        await resolveVideoPlaylistCollectionId(repo: repo, bookUid: 'movie'),
        isNull,
      );
      expect(
        await resolveVideoPlaylistCollectionId(repo: repo, bookUid: 'gone'),
        isNull,
      );
    });

    test('一集属多个合集时取与视频库折叠相同的主归属', () async {
      final FushiDatabase db = _memoryDb();
      final VideoBookRepository repo = VideoBookRepository(db);
      await _insertBook(db, 'ep1');
      final int first = await db.createMediaCollection(
        'Show',
        collectionType: 'playlist',
      );
      final int second = await db.createMediaCollection('Favourites');
      await db.addToCollection(
        second,
        MediaKind.video,
        'ep1',
        userIntent: false,
      );
      await db.addToCollection(
        first,
        MediaKind.video,
        'ep1',
        userIntent: false,
      );

      final int? resolved = await resolveVideoPlaylistCollectionId(
        repo: repo,
        bookUid: 'ep1',
      );
      expect(resolved, (await _libraryFold(db))['video|ep1']);
      expect(resolved, first < second ? first : second);
    });

    test('目录合集随来源分组档位：folder 档解析到目录合集，series 档不强折', () async {
      final FushiDatabase db = _memoryDb();
      final VideoBookRepository repo = VideoBookRepository(db);
      final VideoFolderGroupCoordinator coordinator =
          VideoFolderGroupCoordinator(database: db, repository: repo);
      const String path = '/lessons/easy/clip.mp4';
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Lessons',
          mediaKind: 'video',
          rootPath: '/lessons',
          createdAt: 1,
          videoGroupingMode: const Value('folder'),
        ),
      );
      await _insertBook(db, 'clip', path: path, sourceId: sourceId);
      await coordinator.groupPaths(
        videoPaths: <String>[path],
        sourceId: sourceId,
        groupingMode: 'folder',
        sourceRoot: '/lessons',
      );

      final int? folderCid = (await _libraryFold(db))['video|clip'];
      expect(folderCid, isNotNull);
      expect(
        await resolveVideoPlaylistCollectionId(repo: repo, bookUid: 'clip'),
        folderCid,
      );

      await (db.update(
        db.mediaSources,
      )..where((tbl) => tbl.id.equals(sourceId))).write(
        const MediaSourcesCompanion(videoGroupingMode: Value('series')),
      );
      await (db.update(db.videoBooks)
            ..where((tbl) => tbl.bookUid.equals('clip')))
          .write(const VideoBooksCompanion(videoGroupingMode: Value('series')));
      expect((await _libraryFold(db)).containsKey('video|clip'), isFalse);
      expect(
        await resolveVideoPlaylistCollectionId(repo: repo, bookUid: 'clip'),
        isNull,
      );
    });
  });

  group('openLocalVideoBook 自带系列上下文（源码守卫）', () {
    String read(String rel) => compactCode(File(rel).readAsStringSync());

    test('调用方未给合集 id 时由共享入口解析后再推路由', () {
      final String src = read(
        'lib/src/pages/implementations/home_video_page.dart',
      );
      final int start = src.indexOf('Future<void>openLocalVideoBook({');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('Navigator.push(', start);
      expect(end, greaterThan(start));
      final String head = src.substring(start, end);
      expect(
        head,
        contains(
          'playlistCollectionId??awaitresolveVideoPlaylistCollectionId('
          'repo:repo,bookUid:bookUid)',
        ),
      );
      expect(head, contains('if(!context.mounted)return;'));
      final String route = src.substring(end, end + 400);
      expect(route, contains('playlistCollectionId:collectionId,'));
    });

    test('侧边栏「继续观看」仍走共享入口（不自建播放页路由）', () {
      final String src = read(
        'lib/src/pages/implementations/home_nav_peek.dart',
      );
      expect(src, contains('openLocalVideoBook('));
      expect(src, isNot(contains('VideoFushiPage(')));
      expect(src, isNot(contains('VideoFushiPage.neutralized(')));
    });
  });
}
