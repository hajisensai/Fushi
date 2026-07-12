import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 2：[VideoBookRepository.importSplitPlaylist] 把一个多集播放列表拆成
/// N 条独立 VideoBooks 行 + 一个 playlist 合集（成员按序），与 v38 迁移落库形状对齐。
HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

void main() {
  test('拆成 N 条独立集行 + playlist 合集，每集自带进度、首集不与他集撞 uid', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);

    final List<PlaylistEntry> entries = <PlaylistEntry>[
      const PlaylistEntry(
          title: 'E1', path: '/v/Show E01.mkv', positionMs: 1000),
      const PlaylistEntry(
          title: 'E2', path: '/v/Show E02.mkv', positionMs: 2000),
      const PlaylistEntry(title: '', path: '/v/Show E03.mkv'),
    ];

    final ({int collectionId, List<String> episodeUids}) result = await repo
        .importSplitPlaylist(collectionName: 'Show', entries: entries);

    // 每集 uid = video/<集文件名>，有序返回。
    expect(result.episodeUids,
        <String>['video/Show E01', 'video/Show E02', 'video/Show E03']);

    final List<VideoBookRow> rows = await repo.listAll();
    expect(rows, hasLength(3));
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in rows) r.bookUid: r,
    };
    // 每集自带进度进 lastPositionMs；playlistJson 不写；标题空则回退文件名。
    expect(byUid['video/Show E01']!.lastPositionMs, 1000);
    expect(byUid['video/Show E02']!.lastPositionMs, 2000);
    expect(byUid['video/Show E03']!.lastPositionMs, 0);
    expect(byUid['video/Show E03']!.title, 'Show E03'); // 空标题→文件名
    for (final VideoBookRow r in rows) {
      expect(r.playlistJson, isNull);
      expect(r.currentEpisode, 0);
    }

    // playlist 合集：type=playlist，名=Show，成员按序 = 各集 uid。
    final MediaCollectionRow collection =
        (await db.getMediaCollectionById(result.collectionId))!;
    expect(collection.collectionType, 'playlist');
    expect(collection.name, 'Show');
    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(result.collectionId);
    expect(members.map((MediaCollectionItemRow m) => m.entryKey).toList(),
        result.episodeUids);
  });

  test('删某集清合集引用；删空则合集自删', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);

    final ({int collectionId, List<String> episodeUids}) result =
        await repo.importSplitPlaylist(
      collectionName: 'Show',
      entries: const <PlaylistEntry>[
        PlaylistEntry(title: 'E1', path: '/v/a.mkv'),
        PlaylistEntry(title: 'E2', path: '/v/b.mkv'),
      ],
    );

    await repo.deleteVideoBook(result.episodeUids.first);
    expect(
        (await db.getCollectionItems(result.collectionId))
            .map((MediaCollectionItemRow m) => m.entryKey),
        <String>[result.episodeUids[1]]);
    expect(await db.getMediaCollectionById(result.collectionId), isNotNull);

    await repo.deleteVideoBook(result.episodeUids[1]);
    expect(await db.getMediaCollectionById(result.collectionId), isNull,
        reason: '移空后 playlist 合集自删');
  });
}
