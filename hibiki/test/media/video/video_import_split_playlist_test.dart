import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';

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
        title: 'E1',
        path: '/v/Show E01.mkv',
        positionMs: 1000,
      ),
      const PlaylistEntry(
        title: 'E2',
        path: '/v/Show E02.mkv',
        positionMs: 2000,
      ),
      const PlaylistEntry(title: '', path: '/v/Show E03.mkv'),
    ];

    final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
        collectionName: 'Show', entries: entries);

    // 每集 uid = video/<集文件名>，有序返回。
    expect(result.episodeUids, <String>[
      'video/Show E01',
      'video/Show E02',
      'video/Show E03',
    ]);

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
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      result.collectionId,
    ))!;
    expect(collection.collectionType, 'playlist');
    expect(collection.name, 'Show');
    final List<MediaCollectionItemRow> members = await db.getCollectionItems(
      result.collectionId,
    );
    expect(
      members.map((MediaCollectionItemRow m) => m.entryKey).toList(),
      result.episodeUids,
    );
  });

  test('下载 importer 崩溃重放：归一化路径作业务键，单事务不重复媒体/合集/成员', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    const List<PlaylistEntry> first = <PlaylistEntry>[
      PlaylistEntry(title: 'E1', path: r'D:\Downloads\Show E01.mkv'),
      PlaylistEntry(title: 'E2', path: r'D:\Downloads\Show E02.mkv'),
    ];
    const List<PlaylistEntry> replay = <PlaylistEntry>[
      PlaylistEntry(title: 'E1', path: 'D:/Downloads/Show E01.mkv'),
      PlaylistEntry(title: 'E2', path: 'D:/Downloads/Show E02.mkv'),
    ];

    final SplitPlaylistImportResult initial = await repo.importSplitPlaylist(
      collectionName: 'Show',
      entries: first,
      reuseExistingPaths: true,
    );
    final SplitPlaylistImportResult restarted = await repo.importSplitPlaylist(
      collectionName: 'Show',
      entries: replay,
      reuseExistingPaths: true,
    );

    expect(restarted.collectionId, initial.collectionId);
    expect(restarted.episodeUids, initial.episodeUids);
    expect(await repo.listAll(), hasLength(2));
    expect(await db.getAllMediaCollections(), hasLength(1));
    expect(await db.getCollectionItems(initial.collectionId), hasLength(2));
  });

  test('删某集清合集引用；删空则合集自删', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);

    final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
      collectionName: 'Show',
      entries: const <PlaylistEntry>[
        PlaylistEntry(title: 'E1', path: '/v/a.mkv'),
        PlaylistEntry(title: 'E2', path: '/v/b.mkv'),
      ],
    );

    await repo.deleteVideoBook(result.episodeUids.first);
    expect(
      (await db.getCollectionItems(
        result.collectionId,
      ))
          .map((MediaCollectionItemRow m) => m.entryKey),
      <String>[result.episodeUids[1]],
    );
    expect(await db.getMediaCollectionById(result.collectionId), isNotNull);

    await repo.deleteVideoBook(result.episodeUids[1]);
    expect(
      await db.getMediaCollectionById(result.collectionId),
      isNull,
      reason: '移空后 playlist 合集自删',
    );
  });

  group('reconcileSplitPlaylist：重扫按清单对齐成员（BUG-830）', () {
    /// 取合集当前成员对应的 videoPath 集（成员引用 bookUid → VideoBook.videoPath）。
    Future<Set<String>> memberPaths(
      HibikiDatabase db,
      VideoBookRepository repo,
      int collectionId,
    ) async {
      final Set<String> out = <String>{};
      for (final MediaCollectionItemRow m in await db.getCollectionItems(
        collectionId,
      )) {
        final VideoBookRow? row = await repo.getByBookUid(m.entryKey);
        if (row != null) out.add(row.videoPath);
      }
      return out;
    }

    test('清单增删某集 → 合集成员随之增删（只解绑不删本体）', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
        collectionName: 'Show',
        entries: const <PlaylistEntry>[
          PlaylistEntry(title: 'E1', path: '/v/Show E01.mkv'),
          PlaylistEntry(title: 'E2', path: '/v/Show E02.mkv'),
        ],
      );

      // 磁盘上编辑 m3u8：删 E01、留 E02、加 E03。
      final ({int added, int removed}) recon =
          await repo.reconcileSplitPlaylist(
        collectionId: result.collectionId,
        entries: const <PlaylistEntry>[
          PlaylistEntry(title: 'E2', path: '/v/Show E02.mkv'),
          PlaylistEntry(title: 'E3', path: '/v/Show E03.mkv'),
        ],
      );
      expect(recon.added, 1);
      expect(recon.removed, 1);

      expect(await memberPaths(db, repo, result.collectionId), <String>{
        '/v/Show E02.mkv',
        '/v/Show E03.mkv',
      });

      // 移出清单的 E01 只解绑，VideoBook 本体保留（保观看进度，非破坏性）。
      expect(
        await repo.getByBookUid('video/Show E01'),
        isNotNull,
        reason: '移出清单的集只 removeFromCollection，不删 VideoBook 本体',
      );
      // 未变的 E02 不重建、E03 只新建一条 → 总 3 本（E01 保留 + E02 + E03）。
      expect((await repo.listAll()).length, 3);
    });

    test('清单未变 → 幂等零改动，不产生重复 VideoBook', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      const List<PlaylistEntry> entries = <PlaylistEntry>[
        PlaylistEntry(title: 'E1', path: '/v/a.mkv'),
        PlaylistEntry(title: 'E2', path: '/v/b.mkv'),
      ];
      final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
          collectionName: 'Show', entries: entries);

      final ({int added, int removed}) recon =
          await repo.reconcileSplitPlaylist(
        collectionId: result.collectionId,
        entries: entries,
      );
      expect(recon.added, 0);
      expect(recon.removed, 0);
      // 未变集不重跑 importSplitPlaylist → 不撞 uid 加后缀造重复行（旧代码整体跳过之因）。
      expect((await repo.listAll()).length, 2);
      expect(await memberPaths(db, repo, result.collectionId), <String>{
        '/v/a.mkv',
        '/v/b.mkv',
      });
    });

    test('整批替换清单 → 先加后删，合集不被移空自删', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
        collectionName: 'Show',
        entries: const <PlaylistEntry>[
          PlaylistEntry(title: 'E1', path: '/v/a.mkv'),
          PlaylistEntry(title: 'E2', path: '/v/b.mkv'),
        ],
      );

      final ({int added, int removed}) recon =
          await repo.reconcileSplitPlaylist(
        collectionId: result.collectionId,
        entries: const <PlaylistEntry>[
          PlaylistEntry(title: 'E3', path: '/v/c.mkv'),
          PlaylistEntry(title: 'E4', path: '/v/d.mkv'),
        ],
      );
      expect(recon.added, 2);
      expect(recon.removed, 2);

      // 先加新集让合集非空、再删旧集 → 合集绝不瞬时空掉被「移空自删」误删。
      expect(
        await db.getMediaCollectionById(result.collectionId),
        isNotNull,
        reason: '先加后删，整批替换不误删合集',
      );
      expect(await memberPaths(db, repo, result.collectionId), <String>{
        '/v/c.mkv',
        '/v/d.mkv',
      });
    });
  });
}
