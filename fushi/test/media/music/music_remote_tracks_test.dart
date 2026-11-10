import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart';
import 'package:fushi_music/fushi_music.dart'
    show MusicPluginArtistRef, MusicPluginTrack;

import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;

/// 远程曲目（反馈 0tRY-D2JgG，v148）：YouTube / 在线插件曲目加入音乐库与本地歌单。
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
    coverRef: c.coverRef.present ? c.coverRef.value : null,
    albumId: c.albumId.present ? c.albumId.value : null,
    artistRefs: c.artistRefs.present ? c.artistRefs.value : null,
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

    test('插件曲目落库带艺人引用与专辑 id，还原后「去艺人 / 去专辑」可用（#3046 遗留）', () {
      final MusicPlayItem item = musicPluginPlayItem(
        'netease',
        const MusicPluginTrack(
          id: '43',
          title: 'Song',
          albumId: 'alb-7',
          albumTitle: 'Album',
          artists: <MusicPluginArtistRef>[
            MusicPluginArtistRef(id: 'ar-1', name: 'Singer'),
            MusicPluginArtistRef(name: 'Guest'),
          ],
        ),
      );
      final MusicRemoteTracksCompanion c = musicRemoteTrackCompanionOf(item)!;
      expect(c.albumId.value, 'alb-7');
      final MusicPlayItem back = musicPlayItemOfRemote(rowOf(c))!;
      expect(back.sourceAlbumId, 'alb-7');
      expect(back.albumUid, item.albumUid);
      expect(back.albumUid, musicPluginAlbumUid('netease', 'alb-7'));
      expect(
        back.artistRefs.map((MusicPlayArtistRef a) => (a.id, a.name)),
        <(String?, String)>[('ar-1', 'Singer'), (null, 'Guest')],
      );
    });

    test('艺人引用列坏数据（别的版本写的）还原成空表、不抛', () {
      expect(musicRemoteArtistRefsOf(null), isEmpty);
      expect(musicRemoteArtistRefsOf('not json'), isEmpty);
      expect(musicRemoteArtistRefsOf('{"name":"x"}'), isEmpty);
      expect(
        musicRemoteArtistRefsOf(
          '[{"id":1},{"name":"Ok","id":""}]',
        ).map((MusicPlayArtistRef a) => (a.id, a.name)),
        <(String?, String)>[(null, 'Ok')],
      );
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

    test('服务器曲目不受合规门约束；YouTube / 插件只问合规门', () {
      expect(
        musicRemoteKindAvailable(MusicRemoteTrackKind.server, online: false),
        isTrue,
      );
      for (final MusicRemoteTrackKind k in <MusicRemoteTrackKind>[
        MusicRemoteTrackKind.youtube,
        MusicRemoteTrackKind.plugin,
      ]) {
        expect(musicRemoteKindAvailable(k, online: false), isFalse);
        expect(musicRemoteKindAvailable(k, online: true), isTrue);
      }
    });
  });

  group('服务器曲目（Jellyfin / Subsonic，v149，反馈 se3Fw8HmOX）', () {
    const String jellyfinToken = 'JF-SECRET-TOKEN-1234';
    const JellyfinServerConfig jfConfig = JellyfinServerConfig(
      serverUrl: 'http://nas:8096',
      username: 'me',
      userId: 'uid',
      accessToken: jellyfinToken,
      serverName: 'Home NAS',
    );
    const String subsonicPassword = 'SS-SECRET-PASSWORD';
    const String subsonicApiKey = 'SS-SECRET-APIKEY';
    SubsonicServerConfig ssConfig({String? password, String? apiKey}) =>
        SubsonicServerConfig(
          id: 'navi',
          name: 'Navidrome',
          serverUrl: Uri.parse('https://music.example.com'),
          username: 'listener',
          password: password,
          apiKey: apiKey,
        );
    const MusicServerTrack track = MusicServerTrack(
      id: 'tr-1',
      title: 'Server Song',
      artist: 'Band',
      album: 'Record',
      albumId: 'al-1',
      durationMs: 180000,
      coverRef: 'al-1',
      codec: 'flac',
    );

    /// 一行里所有落库字段的值（凭据守卫逐字段查）。
    List<String> storedValues(MusicRemoteTracksCompanion c) => <String>[
      for (final Value<Object?> v in <Value<Object?>>[
        c.trackUid,
        c.kind,
        c.sourceKey,
        c.itemId,
        c.title,
        c.artist,
        c.album,
        c.durationMs,
        c.coverUrl,
        c.coverRef,
        c.albumId,
        c.artistRefs,
      ])
        if (v.present && v.value != null) '${v.value}',
    ];

    void expectNoCredentials(
      MusicRemoteTracksCompanion c, {
      required List<String> secrets,
    }) {
      final List<String> values = storedValues(c);
      expect(values, isNotEmpty);
      for (final String v in values) {
        for (final String secret in secrets) {
          expect(v, isNot(contains(secret)), reason: '落库字段带了凭据：$v');
        }
        final String lower = v.toLowerCase();
        // 服务器身份（Jellyfin = `jellyfin:<服务器地址>|<userId>`）本来就含服务器地址、但
        // 不含凭据；其余字段连地址都不许有。
        final bool identity = v == c.sourceKey.value;
        for (final String marker in <String>[
          'token',
          'api_key',
          'apikey',
          'u=',
          'p=',
          't=',
          's=',
          '@',
          if (!identity) ...<String>['http://', 'https://'],
        ]) {
          expect(lower, isNot(contains(marker)), reason: '落库字段像地址 / 凭据：$v');
        }
      }
    }

    test('Jellyfin 曲目落库：只有服务器身份 + 条目 id + 元数据，没有 token / 地址', () {
      final JellyfinMusicClient jf = JellyfinMusicClient(jfConfig);
      // 前提：同一首从服务器页直接播时，流地址与封面地址确实带 token。
      final MusicPlayItem direct = musicServerPlayItem(jf, track);
      expect(direct.path, contains(jellyfinToken));
      expect(jf.coverUri(track.coverRef).toString(), contains(jellyfinToken));

      final MusicRemoteTracksCompanion c = musicServerRemoteTrackCompanion(
        jf,
        track,
      )!;
      expect(c.kind.value, 'server');
      expect(c.sourceKey.value, jf.serverId);
      expect(c.itemId.value, 'tr-1');
      expect(c.trackUid.value, musicServerTrackUid(jf.serverId, 'tr-1'));
      expect(c.trackUid.value, direct.trackUid, reason: '与直接播同一个 uid');
      expect(c.coverUrl.value, isNull);
      expect(c.coverRef.value, 'al-1');
      expect(c.albumId.value, 'al-1');
      expectNoCredentials(c, secrets: <String>[jellyfinToken]);
    });

    test('Subsonic 曲目落库（密码 / API key 两种认证）：没有 u= / p= / t= / apiKey', () {
      for (final SubsonicServerConfig config in <SubsonicServerConfig>[
        ssConfig(password: subsonicPassword),
        ssConfig(apiKey: subsonicApiKey),
      ]) {
        final SubsonicMusicClient ss = SubsonicMusicClient(config);
        addTearDown(ss.close);
        // 前提：直接播的流地址确实带认证参数。
        final Map<String, String> q = Uri.parse(
          musicServerPlayItem(ss, track).path,
        ).queryParameters;
        expect(q.containsKey('apiKey') || q.containsKey('t'), isTrue);
        final MusicRemoteTracksCompanion c = musicServerRemoteTrackCompanion(
          ss,
          track,
        )!;
        expect(c.sourceKey.value, 'subsonic-navi');
        expectNoCredentials(
          c,
          secrets: <String>[
            subsonicPassword,
            subsonicApiKey,
            'listener',
            if (q['t'] case final String token) token,
          ],
        );
      }
    });

    test('Apple Music / YouTube 不走服务器曲目', () {
      expect(musicServerRemoteTrackCompanion(youtube, ytTrack), isNull);
      expect(musicServerKindStorable(MusicServerKind.appleMusic), isFalse);
      expect(musicServerKindStorable(MusicServerKind.youtube), isFalse);
      expect(musicServerKindStorable(MusicServerKind.jellyfin), isTrue);
      expect(musicServerKindStorable(MusicServerKind.subsonic), isTrue);
    });

    test('起播时按当前配置重算地址：换了 token 后从同一行还原出的流带新 token', () {
      final MusicRemoteTrackRow row = rowOf(
        musicServerRemoteTrackCompanion(JellyfinMusicClient(jfConfig), track)!,
      );
      const JellyfinServerConfig rotated = JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'me',
        userId: 'uid',
        accessToken: 'JF-ROTATED-TOKEN',
        serverName: 'Home NAS',
      );
      final JellyfinMusicClient now = JellyfinMusicClient(rotated);
      expect(now.serverId, row.sourceKey, reason: '换 token 不换服务器身份');
      final MusicServerBinding binding = MusicServerBinding(
        now,
        maxBitrateKbps: 192,
      );
      final MusicPlayItem item = musicPlayItemOfRemote(row, server: binding)!;
      expect(item.trackUid, row.trackUid);
      expect(item.path, contains('JF-ROTATED-TOKEN'));
      expect(item.path, isNot(contains(jellyfinToken)));
      // 与从服务器页按同一码率上限直接播的地址一致。
      expect(
        item.path,
        musicServerPlayItem(now, track, maxBitrateKbps: 192).path,
      );
      expect(item.albumUid, musicServerAlbumUid(now.serverId, 'al-1'));
      expect(
        musicRemoteCoverUrlOf(row, server: binding),
        now.coverUri('al-1').toString(),
      );
      expect(
        musicRemoteCoverUrlOf(row, server: binding),
        contains('JF-ROTATED-TOKEN'),
      );
    });

    test('服务器配置没了 / 对不上：还原不出播放项、没有封面，不抛', () {
      final MusicRemoteTrackRow row = rowOf(
        musicServerRemoteTrackCompanion(JellyfinMusicClient(jfConfig), track)!,
      );
      expect(musicPlayItemOfRemote(row), isNull);
      expect(musicRemoteCoverUrlOf(row), isNull);
      final SubsonicMusicClient other = SubsonicMusicClient(
        ssConfig(password: subsonicPassword),
      );
      addTearDown(other.close);
      final MusicServerBinding wrong = MusicServerBinding(other);
      expect(musicPlayItemOfRemote(row, server: wrong), isNull);
      expect(musicRemoteCoverUrlOf(row, server: wrong), isNull);
      final MusicRemoteEntry entry = MusicRemoteEntry(row);
      expect(entry.available, isFalse);
      expect(entry.playItem(const <String, MusicAlbumRow>{}), isNull);
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

    test('服务器曲目：曲库与歌单按当前服务器配置绑定；没配的服务器显示为不可用、不进队列', () async {
      final JellyfinMusicClient jf = JellyfinMusicClient(
        const JellyfinServerConfig(
          serverUrl: 'http://nas:8096',
          username: 'me',
          userId: 'uid',
          accessToken: 'tok',
        ),
      );
      const MusicServerTrack t1 = MusicServerTrack(id: 'a', title: 'A');
      const MusicServerTrack t2 = MusicServerTrack(id: 'b', title: 'B');
      final MusicRemoteTracksCompanion c1 = musicServerRemoteTrackCompanion(
        jf,
        t1,
      )!;
      // 第二首来自这台设备上没配的服务器（歌单从别的设备同步来 / 配置删了）。
      final MusicRemoteTracksCompanion c2 =
          musicServerRemoteTrackCompanion(jf, t2)!.copyWith(
            sourceKey: const Value<String>('gone-server'),
            trackUid: Value<String>(musicServerTrackUid('gone-server', 'b')),
          );
      await db.addMusicRemoteTrackToLibrary(c1, at: 2);
      await db.addMusicRemoteTrackToLibrary(c2, at: 1);
      int loads = 0;
      Future<Map<String, MusicServerBinding>> servers() async {
        loads++;
        return <String, MusicServerBinding>{
          jf.serverId: MusicServerBinding(jf),
        };
      }

      // 合规门不过的平台（iOS）上服务器曲目照样显示。
      final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(
        db,
        remoteAvailable: false,
        servers: servers,
      );
      expect(loads, 1);
      expect(
        snap.remoteTracks.map((MusicRemoteEntry e) => e.trackUid),
        <String>[c1.trackUid.value, c2.trackUid.value],
      );
      final MusicRemoteEntry bound = snap.remoteTracks.first;
      expect(bound.available, isTrue);
      expect(
        bound.playItem(const <String, MusicAlbumRow>{})!.path,
        musicServerPlayItem(jf, t1).path,
      );
      final MusicRemoteEntry missing = snap.remoteTracks.last;
      expect(missing.available, isFalse);
      expect(missing.playItem(const <String, MusicAlbumRow>{}), isNull);
      expect(missing.coverUrl, isNull);

      final MusicPlaylistTarget p =
          await MusicLocalPlaylistEditor(db, clock: () => 3).createPlaylist(
            'Srv',
            trackIds: <String>[c1.trackUid.value, c2.trackUid.value],
          );
      final List<MusicPlaylistItem> items = await loadMusicPlaylistItems(
        db,
        p.id,
        remoteAvailable: false,
        servers: servers,
      );
      expect(items, hasLength(2), reason: '服务器没配的条目仍列出（显示不可用），不删行');
      expect(
        items.map(
          (MusicPlaylistItem i) => (i.entry as MusicRemoteEntry).available,
        ),
        <bool>[true, false],
      );
    });

    test('没有服务器曲目时不读服务器配置', () async {
      await db.addMusicRemoteTrackToLibrary(
        musicRemoteTrackCompanionOf(ytItem)!,
        at: 3,
      );
      int loads = 0;
      await MusicLibrarySnapshot.load(
        db,
        remoteAvailable: true,
        servers: () async {
          loads++;
          return const <String, MusicServerBinding>{};
        },
      );
      expect(loads, 0);
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
