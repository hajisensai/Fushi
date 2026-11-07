import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginTrack;

import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';

/// 远程曲目（反馈 0tRY-D2JgG，v147）：YouTube / 在线插件曲目加入音乐库与本地歌单。
///
/// 钉死的是「同一首同一个 uid」——落库再还原的播放项与从搜索结果直接播的播放项 uid / 占位路径
/// 一致，歌词缓存 / 断点 / 最近播放 / 统计 / 制卡（都按 uid 或路径走）在远程曲目上天然可用。
void main() {
  final YoutubeMusicClient youtube = YoutubeMusicClient(displayName: 'YouTube');
  const MusicServerTrack ytTrack = MusicServerTrack(
    id: 'dQw4w9WgXcQ',
    title: 'Never Gonna Give You Up',
    artist: 'Rick Astley',
    durationMs: 213000,
    coverRef: 'dQw4w9WgXcQ',
  );
  final MusicPlayItem ytItem = musicServerPlayItem(youtube, ytTrack);

  MusicRemoteTrackRow rowOf(
    MusicRemoteTracksCompanion c, {
    int? libraryAddedAt,
  }) => MusicRemoteTrackRow(
    trackUid: c.trackUid.value,
    kind: c.kind.value,
    sourceKey: c.sourceKey.value,
    itemId: c.itemId.value,
    title: c.title.value,
    artist: c.artist.value,
    album: c.album.value,
    durationMs: c.durationMs.value,
    coverUrl: c.coverUrl.value,
    libraryAddedAt: libraryAddedAt,
    createdAt: 1,
    updatedAt: 1,
  );

  group('身份与换算', () {
    test('YouTube 搜索结果 → 远程曲目行 → 播放项：uid / 路径与直接播一致', () {
      expect(musicItemIsRemoteTrack(ytItem), isTrue);
      final MusicRemoteTracksCompanion c = musicRemoteTrackCompanionOf(ytItem)!;
      expect(c.kind.value, 'youtube');
      expect(c.sourceKey.value, kYoutubeMusicServerId);
      expect(c.itemId.value, 'dQw4w9WgXcQ');
      expect(c.trackUid.value, musicServerTrackUid('youtube', 'dQw4w9WgXcQ'));
      expect(c.coverUrl.value, startsWith('https://'));
      final MusicPlayItem back = musicPlayItemOfRemote(rowOf(c))!;
      expect(back.trackUid, ytItem.trackUid);
      expect(back.path, ytItem.path);
      expect(back.title, ytItem.title);
      expect(back.artist, ytItem.artist);
      expect(back.durationMs, 213000);
      expect(back.coverPath, ytItem.coverPath);
    });

    test('插件曲目同理（uid = musicPluginTrackUid，路径 = 插件占位）', () {
      final MusicPlayItem item = musicPluginPlayItem(
        'netease',
        const MusicPluginTrack(id: '42', title: 'Song', albumTitle: 'Album'),
      );
      final MusicRemoteTracksCompanion c = musicRemoteTrackCompanionOf(item)!;
      expect(c.kind.value, 'plugin');
      expect(c.sourceKey.value, 'netease');
      expect(c.itemId.value, '42');
      final MusicPlayItem back = musicPlayItemOfRemote(rowOf(c))!;
      expect(back.trackUid, musicPluginTrackUid('netease', '42'));
      expect(back.path, musicPluginTrackPath('netease', '42'));
      expect(back.album, 'Album');
    });

    test('本地文件 / 服务器 HTTP 流不是远程曲目；uid 与身份对不上的也不算', () {
      const MusicPlayItem local = MusicPlayItem(
        trackUid: 'abc',
        path: '/music/a.flac',
        title: 'a',
      );
      expect(musicRemoteTrackCompanionOf(local), isNull);
      const MusicPlayItem http = MusicPlayItem(
        trackUid: 'srv0',
        path: 'https://jellyfin.example/Audio/1/stream',
        title: 'b',
      );
      expect(musicItemIsRemoteTrack(http), isFalse);
      final MusicPlayItem forged = MusicPlayItem(
        trackUid: 'not-the-derived-uid',
        path: ytItem.path,
        title: 'x',
      );
      expect(musicRemoteTrackCompanionOf(forged), isNull);
    });

    test('本地封面路径不落成 coverUrl（只收 http(s)）', () {
      final MusicPlayItem item = MusicPlayItem(
        trackUid: ytItem.trackUid,
        path: ytItem.path,
        title: 't',
        coverPath: r'C:\covers\x.jpg',
      );
      expect(musicRemoteTrackCompanionOf(item)!.coverUrl.value, isNull);
    });

    test('不认识的种类（将来版本写的）还原不出播放项', () {
      final MusicRemoteTrackRow row = rowOf(
        musicRemoteTrackCompanionOf(ytItem)!,
      ).copyWith(kind: 'future-kind');
      expect(musicPlayItemOfRemote(row), isNull);
      expect(MusicRemoteTrackKind.fromWire('future-kind'), isNull);
    });

    test('合规门：iOS 上远程曲目不存在，其余平台存在', () {
      expect(musicRemoteTracksAvailableOn(isIOS: true), isFalse);
      expect(musicRemoteTracksAvailableOn(isIOS: false), isTrue);
    });
  });

  group('歌单解析与本地歌单编辑器', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> seedLocalTrack(String uid) => db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          MusicTracksCompanion.insert(
            trackUid: uid,
            path: '/music/$uid.flac',
            title: 'local $uid',
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        ],
        albums: const <MusicAlbumsCompanion>[],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );

    test('编辑器新建带远程曲目的歌单：远程行同事务落库、不进音乐库；解析出混排条目', () async {
      await seedLocalTrack('l1');
      final MusicLocalPlaylistEditor editor = MusicLocalPlaylistEditor(
        db,
        remote: <MusicRemoteTracksCompanion>[
          musicRemoteTrackCompanionOf(ytItem)!,
        ],
        clock: () => 7,
      );
      final MusicPlaylistTarget created = await editor.createPlaylist(
        'Mix',
        trackIds: <String>['l1', ytItem.trackUid, 'gone'],
      );
      expect(created.trackCount, 3);
      expect(await db.listMusicRemoteLibraryTracks(), isEmpty);

      final List<MusicPlaylistItem> items = await loadMusicPlaylistItems(
        db,
        created.id,
        remoteAvailable: true,
      );
      // 'gone' 两边都解析不到（别的设备的本地曲目）：跳过、不删行。
      expect(items, hasLength(2));
      expect(items[0].entry, isA<MusicLocalEntry>());
      expect(items[1].entry, isA<MusicRemoteEntry>());
      final MusicPlayItem played = items[1].entry.playItem(
        const <String, MusicAlbumRow>{},
      )!;
      expect(played.trackUid, ytItem.trackUid);
      expect(played.path, ytItem.path);
      expect(await db.listMusicPlaylistEntries(created.id), hasLength(3));

      // 合规门没过的平台：远程条目不显示（行仍在，同步不丢）。
      final List<MusicPlaylistItem> ios = await loadMusicPlaylistItems(
        db,
        created.id,
        remoteAvailable: false,
      );
      expect(ios.map((MusicPlaylistItem i) => i.entry.trackUid), <String>[
        'l1',
      ]);
    });

    test('可加歌的歌单不含智能歌单，带条目数', () async {
      final MusicLocalPlaylistEditor editor = MusicLocalPlaylistEditor(
        db,
        clock: () => 1,
      );
      final MusicPlaylistTarget a = await editor.createPlaylist(
        'A',
        trackIds: <String>['x', 'y'],
      );
      await db
          .into(db.musicPlaylists)
          .insert(
            MusicPlaylistsCompanion.insert(
              playlistUid: 'smart',
              name: 'Smart',
              rulesJson: const Value<String?>('{}'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await editor.addToPlaylist(a.id, <String>['z']);
      final List<MusicPlaylistTarget> targets = await editor
          .editablePlaylists();
      expect(targets.map((MusicPlaylistTarget t) => t.title), <String>['A']);
      expect(targets.single.trackCount, 3);
    });

    test('曲库快照：远程曲目只在门过时读入，歌曲分区本地在前、远程随后', () async {
      await seedLocalTrack('l1');
      await db.addMusicRemoteTrackToLibrary(
        musicRemoteTrackCompanionOf(ytItem)!,
        at: 3,
      );
      final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(
        db,
        remoteAvailable: true,
      );
      expect(
        snap.songEntries.map((MusicLibraryEntry e) => e.trackUid),
        <String>['l1', ytItem.trackUid],
      );
      final MusicLibrarySnapshot ios = await MusicLibrarySnapshot.load(
        db,
        remoteAvailable: false,
      );
      expect(ios.remoteTracks, isEmpty);
    });

    test('只有歌单（远程曲目没进库）时曲库不算空', () async {
      await MusicLocalPlaylistEditor(db, clock: () => 1).createPlaylist('P');
      final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(
        db,
        remoteAvailable: true,
      );
      expect(snap.isEmpty, isFalse);
    });
  });
}
