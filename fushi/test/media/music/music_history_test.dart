import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/music_history.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 播放流（最近播放）的 app 侧：播放项 → 快照落库 → 重建出可再播的播放项；
/// 来源种类 wire 值与编码。
void main() {
  late Directory directory;
  late FushiDatabase db;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('music_history');
    db = FushiDatabase.atFile(
      '${directory.path}/test.db',
      isMainProcess: false,
    );
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  test('在线插件曲目：快照落库后重建出同一路径 / 身份的播放项，带上来源', () async {
    final MusicPlayItem item = musicPluginPlayItem(
      'demo',
      const MusicPluginTrack(
        id: '186016',
        title: '晴天',
        artists: <MusicPluginArtistRef>[MusicPluginArtistRef(name: '周杰伦')],
        albumTitle: '叶惠美',
        albumId: '18905',
        durationMs: 269000,
        coverUrl: 'https://p1.example/cover.jpg',
      ),
    );
    final MusicPlaySource source = MusicPlaySource.pluginPlaylist(
      'demo',
      '3778678',
      title: '热歌榜',
      cover: 'https://p1.example/pl.jpg',
    );
    await db.startMusicPlayEvent(
      trackUid: item.trackUid,
      startedAt: 100,
      snapshot: musicPlayEventSnapshotOf(item, source: source),
    );

    final List<MusicRecentTrack> tracks = await loadRecentMusicTracks(db);
    expect(tracks, hasLength(1));
    final MusicRecentTrack t = tracks.single;
    expect(t.inLibrary, isFalse);
    expect(t.lastPlayedAt, 100);
    expect(t.item.trackUid, item.trackUid);
    expect(t.item.path, item.path);
    expect(parseMusicPluginTrackPath(t.item.path), (
      pluginId: 'demo',
      trackId: '186016',
    ));
    expect(t.item.title, '晴天');
    expect(t.item.artist, item.artist);
    expect(t.item.album, '叶惠美');
    expect(t.item.albumUid, item.albumUid);
    expect(t.item.durationMs, 269000);
    expect(t.item.coverPath, 'https://p1.example/cover.jpg');
    expect(t.source, source);
    expect(t.source?.title, '热歌榜');

    final List<MusicRecentPlaySource> sources = await loadRecentMusicSources(
      db,
    );
    expect(sources.single.source.kind, MusicPlaySourceKind.pluginPlaylist);
    expect(sources.single.source.hostRef, (hostId: 'demo', itemId: '3778678'));
    expect(sources.single.source.cover, 'https://p1.example/pl.jpg');
    expect(
      await loadRecentMusicSources(
        db,
        kinds: <MusicPlaySourceKind>{MusicPlaySourceKind.album},
      ),
      isEmpty,
    );
  });

  test('本地曲目：以曲库行为准（CUE 起止 / ReplayGain），专辑封面缺了用快照补', () async {
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          MusicTracksCompanion.insert(
            trackUid: 'cue2',
            path: '/m/whole.flac',
            title: 'Track 2',
            cueStartMs: const Value<int?>(60000),
            cueEndMs: const Value<int?>(120000),
            albumUid: const Value<String?>('a1'),
            rgTrackGain: const Value<double?>(-6.5),
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        ],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'a1',
            title: 'Album',
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    await db.startMusicPlayEvent(
      trackUid: 'cue2',
      startedAt: 5,
      snapshot: musicPlayEventSnapshotOf(
        const MusicPlayItem(
          trackUid: 'cue2',
          path: '/m/whole.flac',
          title: 'stale title',
          coverPath: '/covers/a1.jpg',
        ),
        source: const MusicPlaySource.album('a1', title: 'Album'),
      ),
    );
    final MusicRecentTrack t = (await loadRecentMusicTracks(db)).single;
    expect(t.inLibrary, isTrue);
    expect(t.item.title, 'Track 2');
    expect(t.item.startMs, 60000);
    expect(t.item.endMs, 120000);
    expect(t.item.album, 'Album');
    expect(t.item.rgTrackGain, -6.5);
    expect(t.item.coverPath, '/covers/a1.jpg');
    expect(t.source?.kind, MusicPlaySourceKind.album);
  });

  test('来源种类 wire 值冻结；不认识的归 other；非宿主种类没有 hostRef', () {
    expect(
      <String>[
        for (final MusicPlaySourceKind k in MusicPlaySourceKind.values) k.wire,
      ],
      <String>[
        'album',
        'playlist',
        'plugin_album',
        'plugin_playlist',
        'server_album',
        'server_playlist',
        'artist',
        'other',
      ],
    );
    expect(
      MusicPlaySourceKind.fromWire('future_kind'),
      MusicPlaySourceKind.other,
    );
    expect(const MusicPlaySource.album('a1').hostRef, isNull);
    expect(
      const MusicPlaySource(
        kind: MusicPlaySourceKind.pluginAlbum,
        id: 'bad',
      ).hostRef,
      isNull,
    );
    expect(MusicPlaySource.serverAlbum('srv', 'x/y').hostRef, (
      hostId: 'srv',
      itemId: 'x/y',
    ));
  });
}
