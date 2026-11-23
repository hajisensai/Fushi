import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:fushi/src/media/music/music_history.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;

/// BUG-5267：最近播放快照（`music_play_events`）曾把服务器曲目带凭据的流地址 / 封面地址原样
/// 落库（Jellyfin `api_key=<access token>`、Subsonic `u` + `t` + `s` / `apiKey`）。
///
/// 钉死：落库只有身份占位；重播时由当前配置的服务器现算地址（换了 token 用新的）；没配那台
/// 服务器时不可用；写入守门兜住漏网调用方；v172 迁移清洗存量行且存量行仍可重播。
void main() {
  const String jfToken = 'JF-SECRET-TOKEN-1234';
  const JellyfinServerConfig jfConfig = JellyfinServerConfig(
    serverUrl: 'http://nas:8096',
    username: 'me',
    userId: 'uid',
    accessToken: jfToken,
    serverName: 'Home NAS',
  );
  const String ssPassword = 'SS-SECRET-PASSWORD';
  const String ssApiKey = 'SS-SECRET-APIKEY';
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
    id: 'Tr-1',
    title: 'Server Song',
    artist: 'Band',
    album: 'Record',
    albumId: 'Al-1',
    durationMs: 180000,
    coverRef: 'Al-1',
    codec: 'flac',
  );

  late Directory directory;
  late FushiDatabase db;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('music_hist_cred');
    db = FushiDatabase.atFile(
      '${directory.path}/test.db',
      isMainProcess: false,
    );
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  /// 播放流表里所有文本列的值。
  Future<List<String>> storedValues(FushiDatabase d) async {
    final List<QueryRow> rows = await d
        .customSelect(
          'SELECT path, cover_path, source_cover, source_id, title '
          'FROM music_play_events',
        )
        .get();
    return <String>[
      for (final QueryRow r in rows)
        for (final String c in <String>[
          'path',
          'cover_path',
          'source_cover',
          'source_id',
          'title',
        ])
          ?r.read<String?>(c),
    ];
  }

  /// 凭据守卫：不含已知秘密，也不含任何凭据形态的地址。
  Future<void> expectNoCredentials(
    FushiDatabase d, {
    required List<String> secrets,
  }) async {
    final List<String> values = await storedValues(d);
    expect(values, isNotEmpty);
    for (final String v in values) {
      for (final String s in secrets) {
        expect(v, isNot(contains(s)), reason: '落库字段带了凭据：$v');
      }
      expect(musicUrlCarriesCredentials(v), isFalse, reason: v);
      final String lower = v.toLowerCase();
      for (final String marker in <String>[
        'api_key=',
        'apikey=',
        '&t=',
        '&s=',
      ]) {
        expect(lower, isNot(contains(marker)), reason: '落库字段像凭据：$v');
      }
    }
  }

  MusicServerBindingLoader loaderOf(List<MusicServerBrowser> browsers) =>
      () async => <String, MusicServerBinding>{
        for (final MusicServerBrowser b in browsers)
          b.serverId: MusicServerBinding(b),
      };

  group('清洗判据（fushi_core music_server_ref.dart）', () {
    test('认出凭据形态；不带凭据的地址 / 本地路径 / 占位原样', () {
      expect(
        musicUrlCarriesCredentials(
          'http://nas:8096/Audio/x/stream?static=true&api_key=abc',
        ),
        isTrue,
      );
      expect(
        musicUrlCarriesCredentials(
          'https://m.example/rest/stream?u=a&t=deadbeef&s=salt&id=1',
        ),
        isTrue,
      );
      expect(
        musicUrlCarriesCredentials('https://m.example/rest/stream?apiKey=k'),
        isTrue,
      );
      expect(
        musicUrlCarriesCredentials('https://user:pw@m.example/a.mp3'),
        isTrue,
      );
      expect(
        musicUrlCarriesCredentials('https://img.example/cover.jpg?w=300'),
        isFalse,
      );
      for (final String keep in <String>[
        '/music/a.flac',
        'fushi-music-plugin://demo/1',
        'https://img.example/cover.jpg',
        musicServerTrackRefPath('Tr-1', serverId: 's'),
      ]) {
        expect(scrubMusicPersistedUrl(keep), keep);
      }
    });

    test('Jellyfin / Subsonic 地址换成占位（id 保留大小写），认不出的丢掉', () {
      expect(
        parseMusicServerRef(
          scrubMusicPersistedUrl(
            'http://nas:8096/Audio/AbC/universal?UserId=u&api_key=t',
          ),
        ),
        (
          kind: MusicServerRefKind.track,
          id: 'AbC',
          serverId: null,
          albumId: null,
        ),
      );
      expect(
        parseMusicServerRef(
          scrubMusicPersistedUrl(
            'http://nas:8096/Items/CoV/Images/Primary?api_key=t',
            serverId: 'srv',
          ),
        ),
        (
          kind: MusicServerRefKind.cover,
          id: 'CoV',
          serverId: 'srv',
          albumId: null,
        ),
      );
      expect(
        parseMusicServerRef(
          scrubMusicPersistedUrl(
            'https://m.example/sub/rest/stream.view?u=a&t=x&s=y&id=42',
          ),
        )?.id,
        '42',
      );
      expect(
        parseMusicServerRef(
          scrubMusicPersistedUrl(
            'https://m.example/rest/getCoverArt?apiKey=k&id=c9&size=400',
          ),
        )?.kind,
        MusicServerRefKind.cover,
      );
      expect(
        scrubMusicPersistedUrl('https://x.example/whatever?api_key=t'),
        isNull,
      );
    });
  });

  test('Jellyfin：落库只有占位；重播按当前配置现算（换 token 用新的），uid 不变', () async {
    final JellyfinMusicClient jf = JellyfinMusicClient(jfConfig);
    final MusicPlayItem item = musicServerPlayItem(jf, track);
    // 前提：内存里的流 / 封面地址确实带 token。
    expect(item.path, contains(jfToken));
    expect(item.coverPath, contains(jfToken));
    final MusicPlaySource source = MusicPlaySource.serverAlbum(
      jf.serverId,
      'Al-1',
      title: 'Record',
      cover: jf.coverUri('Al-1').toString(),
    );
    expect(source.cover, contains(jfToken));

    await db.startMusicPlayEvent(
      trackUid: item.trackUid,
      startedAt: 100,
      snapshot: musicPlayEventSnapshotOf(item, source: source),
    );
    await expectNoCredentials(db, secrets: <String>[jfToken]);
    final MusicPlayEventRow row = await db
        .select(db.musicPlayEvents)
        .getSingle();
    expect(parseMusicServerRef(row.path), (
      kind: MusicServerRefKind.track,
      id: 'Tr-1',
      serverId: jf.serverId,
      albumId: 'Al-1',
    ));
    expect(parseMusicServerRef(row.coverPath)?.kind, MusicServerRefKind.cover);
    expect(parseMusicServerRef(row.sourceCover)?.serverId, jf.serverId);

    // token 轮换后重播：用新 token 现算，旧 token 不再出现。
    const String rotatedToken = 'JF-ROTATED-TOKEN-9';
    final JellyfinMusicClient rotated = JellyfinMusicClient(
      const JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'me',
        userId: 'uid',
        accessToken: rotatedToken,
        serverName: 'Home NAS',
      ),
    );
    final List<MusicRecentTrack> recent = await loadRecentMusicTracks(
      db,
      servers: loaderOf(<MusicServerBrowser>[rotated]),
    );
    final MusicPlayItem back = recent.single.item;
    expect(back.trackUid, item.trackUid);
    expect(back.path, rotated.streamFor(track).uri.toString());
    expect(back.path, contains(rotatedToken));
    expect(back.path, isNot(contains(jfToken)));
    expect(back.coverPath, rotated.coverUri('Al-1').toString());
    expect(back.albumUid, item.albumUid);
    expect(back.title, 'Server Song');
    expect(back.durationMs, 180000);
    expect(recent.single.source?.cover, rotated.coverUri('Al-1').toString());

    final List<MusicRecentPlaySource> sources = await loadRecentMusicSources(
      db,
      servers: loaderOf(<MusicServerBrowser>[rotated]),
    );
    expect(sources.single.source.cover, rotated.coverUri('Al-1').toString());

    // 这台设备没配这台服务器：曲目不可用（不列出），来源封面没有。
    expect(
      await loadRecentMusicTracks(
        db,
        servers: loaderOf(const <MusicServerBrowser>[]),
      ),
      isEmpty,
    );
    final List<MusicRecentPlaySource> noServer = await loadRecentMusicSources(
      db,
      servers: loaderOf(const <MusicServerBrowser>[]),
    );
    expect(noServer.single.source.cover, isNull);
  });

  test('离线副本：快照落身份占位（不落本机路径），重播仍放副本并带服务器身份与增益', () async {
    final JellyfinMusicClient jf = JellyfinMusicClient(jfConfig);
    final String uid = musicServerTrackUid(jf.serverId, track.id);
    final String local = '${directory.path}/Server Song.flac';
    musicServerLocalCopyLookup = (String u) => u == uid
        ? (
            path: local,
            coverPath: null,
            codec: 'flac',
            serverId: jf.serverId,
            trackId: track.id,
            loudness: const MusicServerLoudness(
              trackGainDb: -2,
              albumGainDb: -3,
            ),
          )
        : null;
    addTearDown(() => musicServerLocalCopyLookup = null);
    final MusicPlayItem item = musicServerPlayItem(jf, track);
    expect(item.path, local);
    expect(item.serverTrack?.trackId, track.id);

    await db.startMusicPlayEvent(
      trackUid: item.trackUid,
      startedAt: 100,
      snapshot: musicPlayEventSnapshotOf(item),
    );
    await expectNoCredentials(db, secrets: <String>[jfToken]);
    final MusicPlayEventRow row = await db
        .select(db.musicPlayEvents)
        .getSingle();
    expect(parseMusicServerRef(row.path)?.id, track.id);

    final MusicPlayItem back = (await loadRecentMusicTracks(
      db,
      servers: loaderOf(<MusicServerBrowser>[jf]),
    )).single.item;
    expect(back.trackUid, uid);
    expect(back.path, local);
    expect(back.serverTrack?.serverId, jf.serverId);
    expect(back.serverTrack?.trackId, track.id);
    expect(back.rgTrackGain, -2);
    expect(back.rgAlbumGain, -3);
  });

  test('服务器配置删了：有离线副本的仍留在最近播放（放本机文件），没副本的不列出', () async {
    final JellyfinMusicClient jf = JellyfinMusicClient(jfConfig);
    final String uid = musicServerTrackUid(jf.serverId, track.id);
    final String local = '${directory.path}/Server Song.flac';
    musicServerLocalCopyLookup = (String u) => u == uid
        ? (
            path: local,
            coverPath: '${directory.path}/cover.jpg',
            codec: 'flac',
            serverId: jf.serverId,
            trackId: track.id,
            loudness: const MusicServerLoudness(trackGainDb: -2),
          )
        : null;
    addTearDown(() => musicServerLocalCopyLookup = null);
    const MusicServerTrack other = MusicServerTrack(id: 'Tr-2', title: 'Gone');
    for (final (int at, MusicServerTrack t) in <(int, MusicServerTrack)>[
      (100, track),
      (200, other),
    ]) {
      final MusicPlayItem item = musicServerPlayItem(jf, t);
      await db.startMusicPlayEvent(
        trackUid: item.trackUid,
        startedAt: at,
        snapshot: musicPlayEventSnapshotOf(item),
      );
    }

    final List<MusicRecentTrack> recent = await loadRecentMusicTracks(
      db,
      servers: loaderOf(const <MusicServerBrowser>[]),
    );
    expect(recent, hasLength(1), reason: '没副本的那首不可用');
    final MusicPlayItem back = recent.single.item;
    expect(back.trackUid, uid);
    expect(back.path, local);
    expect(back.title, 'Server Song');
    expect(back.coverPath, '${directory.path}/cover.jpg');
    expect(back.albumUid, musicServerAlbumUid(jf.serverId, 'Al-1'));
    expect(back.rgTrackGain, -2);
    expect(back.serverTrack, isNull, reason: '没配那台服务器：不带服务器身份');
  });

  test('Subsonic（token / apiKey 两种认证）：落库没有 u / t / s / apiKey，可重播', () async {
    for (final SubsonicServerConfig config in <SubsonicServerConfig>[
      ssConfig(password: ssPassword),
      ssConfig(apiKey: ssApiKey),
    ]) {
      await db.customStatement('DELETE FROM music_play_events');
      final SubsonicMusicClient ss = SubsonicMusicClient(config);
      addTearDown(ss.close);
      final MusicPlayItem item = musicServerPlayItem(ss, track);
      final Map<String, String> q = Uri.parse(item.path).queryParameters;
      expect(q.containsKey('apiKey') || q.containsKey('t'), isTrue);
      await db.startMusicPlayEvent(
        trackUid: item.trackUid,
        startedAt: 1,
        snapshot: musicPlayEventSnapshotOf(item),
      );
      await expectNoCredentials(
        db,
        secrets: <String>[ssPassword, ssApiKey, if (q['t'] != null) q['t']!],
      );
      final List<MusicRecentTrack> recent = await loadRecentMusicTracks(
        db,
        servers: loaderOf(<MusicServerBrowser>[ss]),
      );
      expect(recent.single.item.trackUid, item.trackUid);
      final Uri replay = Uri.parse(recent.single.item.path);
      expect(replay.path, endsWith('/rest/stream'));
      expect(replay.queryParameters['id'], 'Tr-1');
    }
  });

  test('非服务器曲目（YouTube 占位 / 本地文件）快照原样', () {
    final MusicPlayItem yt = musicServerPlayItem(
      YoutubeMusicClient(displayName: 'YouTube'),
      const MusicServerTrack(id: 'dQw4w9WgXcQ', title: 'x'),
    );
    expect(musicPlayEventSnapshotOf(yt).path, yt.path);
    const MusicPlayItem local = MusicPlayItem(
      trackUid: 'l',
      path: '/music/a.flac',
      title: 'a',
      coverPath: '/covers/a.jpg',
    );
    expect(musicPlayEventSnapshotOf(local).path, '/music/a.flac');
    expect(musicPlayEventSnapshotOf(local).coverPath, '/covers/a.jpg');
  });

  test('写入守门：调用方直接塞带凭据的地址也落不进库', () async {
    final JellyfinMusicClient jf = JellyfinMusicClient(jfConfig);
    final MusicPlayItem item = musicServerPlayItem(jf, track);
    await db.startMusicPlayEvent(
      trackUid: item.trackUid,
      startedAt: 1,
      snapshot: MusicPlayEventSnapshot(
        path: item.path,
        coverPath: item.coverPath,
        title: item.title,
        sourceKind: 'server_album',
        sourceId: '${jf.serverId}/Al-1',
        sourceCover: jf.coverUri('Al-1').toString(),
      ),
    );
    await expectNoCredentials(db, secrets: <String>[jfToken]);
    // 存量形态（占位里没写服务器身份）照样按 uid 找回服务器重播。
    final List<MusicRecentTrack> recent = await loadRecentMusicTracks(
      db,
      servers: loaderOf(<MusicServerBrowser>[jf]),
    );
    expect(recent.single.item.trackUid, item.trackUid);
    expect(recent.single.item.path, jf.streamFor(track).uri.toString());
  });

  test('v171 → v172 迁移清洗存量行；存量行仍可重播；配错服务器不串台；重跑幂等', () async {
    final JellyfinMusicClient jf = JellyfinMusicClient(jfConfig);
    final SubsonicMusicClient ss = SubsonicMusicClient(
      ssConfig(password: ssPassword),
    );
    addTearDown(ss.close);
    final MusicPlayItem jfItem = musicServerPlayItem(jf, track);
    final MusicPlayItem ssItem = musicServerPlayItem(ss, track);
    final String ssToken = Uri.parse(ssItem.path).queryParameters['t']!;
    final String path = '${directory.path}/legacy.db';
    final FushiDatabase fresh = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    // 旧版本落库的形态：绕过写入守门直接写原始地址，再退回 v171。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    final sqlite.PreparedStatement ins = raw.prepare(
      'INSERT INTO music_play_events (track_uid, started_at, listened_ms, '
      'completed, path, cover_path, title, source_kind, source_id, '
      'source_cover) VALUES (?, ?, 0, 0, ?, ?, ?, ?, ?, ?)',
    );
    ins.execute(<Object?>[
      jfItem.trackUid,
      10,
      jfItem.path,
      jfItem.coverPath,
      'jf',
      'server_album',
      '${jf.serverId}/Al-1',
      jf.coverUri('Al-1').toString(),
    ]);
    ins.execute(<Object?>[
      ssItem.trackUid,
      20,
      ssItem.path,
      ssItem.coverPath,
      'ss',
      null,
      null,
      null,
    ]);
    // 认不出的带凭据地址：整列丢掉。
    ins.execute(<Object?>[
      'weird',
      5,
      'https://odd.example/x?api_key=$jfToken',
      'https://img.example/plain.jpg',
      'weird',
      null,
      null,
      null,
    ]);
    // 本地 / 插件行不受影响。
    ins.execute(<Object?>[
      'plg',
      1,
      'fushi-music-plugin://demo/1',
      'https://img.example/c.jpg',
      'plg',
      null,
      null,
      null,
    ]);
    ins.dispose();
    raw.execute('PRAGMA user_version = 171');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    expect(migrated.schemaVersion, 173);
    await expectNoCredentials(
      migrated,
      secrets: <String>[jfToken, ssToken, ssPassword],
    );
    final Map<String, MusicPlayEventRow> rows = <String, MusicPlayEventRow>{
      for (final MusicPlayEventRow r
          in await migrated.select(migrated.musicPlayEvents).get())
        r.trackUid: r,
    };
    expect(parseMusicServerRef(rows[jfItem.trackUid]!.path)?.id, 'Tr-1');
    expect(
      parseMusicServerRef(rows[jfItem.trackUid]!.sourceCover)?.serverId,
      jf.serverId,
      reason: '来源 id 里带着服务器身份',
    );
    expect(parseMusicServerRef(rows[ssItem.trackUid]!.path)?.id, 'Tr-1');
    expect(rows['weird']!.path, isNull);
    expect(rows['weird']!.coverPath, 'https://img.example/plain.jpg');
    expect(rows['plg']!.path, 'fushi-music-plugin://demo/1');

    // 存量行重播：占位里没服务器身份，按 uid 在当前配置里找回；同 id 的另一台服务器
    // 对不上 uid，不会把 Jellyfin 的记录接到 Subsonic 上。
    final List<MusicRecentTrack> recent = await loadRecentMusicTracks(
      migrated,
      servers: loaderOf(<MusicServerBrowser>[jf, ss]),
    );
    final Map<String, MusicPlayItem> byUid = <String, MusicPlayItem>{
      for (final MusicRecentTrack t in recent) t.item.trackUid: t.item,
    };
    expect(byUid[jfItem.trackUid]!.path, jf.streamFor(track).uri.toString());
    expect(byUid[jfItem.trackUid]!.coverPath, jf.coverUri('Al-1').toString());
    expect(
      Uri.parse(byUid[ssItem.trackUid]!.path).queryParameters['id'],
      'Tr-1',
    );
    expect(
      byUid[ssItem.trackUid]!.path,
      startsWith('https://music.example.com'),
    );
    final List<MusicRecentTrack> onlySs = await loadRecentMusicTracks(
      migrated,
      servers: loaderOf(<MusicServerBrowser>[ss]),
    );
    expect(
      onlySs.map((MusicRecentTrack t) => t.item.trackUid),
      isNot(contains(jfItem.trackUid)),
    );

    // 重跑清洗：没有可改的行。
    expect(await migrated.scrubMusicPlayEventCredentials(), 0);
  });
}
