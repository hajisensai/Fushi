// 服务器曲目身份打通后的几处：生成字幕优先用离线副本、最近播放重建的项补身份、
// 「正在播放」里服务器曲目的收藏。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/asr/music_server_asr_audio.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/music_server_favorites.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/media/music/server/music_server_track_ref.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:path/path.dart' as p;

/// 能认流地址、能收藏的服务器（流地址形如 `http://srv/<id>`）。
class _Server extends Fake
    implements
        MusicServerBrowser,
        MusicServerStreamIdentity,
        MusicServerFavoriteEditing {
  _Server(this.serverId);

  @override
  final String serverId;
  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;

  final Set<String> starred = <String>{};
  int asked = 0;

  @override
  MusicServerStreamRef? streamRefOf(Uri uri) => uri.host == 'srv'
      ? MusicServerStreamRef(trackId: uri.pathSegments.last, transcoded: false)
      : null;

  @override
  Future<bool?> trackFavorite(String trackId) async {
    asked++;
    return starred.contains(trackId);
  }

  @override
  Future<void> setFavorite(
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  }) async {
    if (favorite) {
      starred.add(id);
    } else {
      starred.remove(id);
    }
  }
}

MusicServerLocalCopy _copy(String path, String serverId, String trackId) => (
  path: path,
  coverPath: null,
  codec: 'flac',
  serverId: serverId,
  trackId: trackId,
  loudness: null,
);

void main() {
  final _Server server = _Server('jf1');
  const MusicServerTrackRef refA = MusicServerTrackRef(
    kind: MusicServerKind.jellyfin,
    serverId: 'jf1',
    trackId: 'a',
  );

  group('生成字幕：离线副本优先', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('server_gaps_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('有离线副本：直接转写那份文件，不需要服务器配置（离线可用）', () async {
      final File f = File(p.join(tmp.path, 'a.flac'))
        ..writeAsBytesSync(<int>[1]);
      final MusicAsrAudioInput input = await musicServerAsrAudioInput(
        refA,
        servers: () async => const <String, MusicServerBinding>{},
        localCopies: (String uid) =>
            uid == refA.trackUid ? _copy(f.path, 'jf1', 'a') : null,
      );
      expect(input, isA<MusicAsrLocalAudio>());
      expect((input as MusicAsrLocalAudio).file.path, f.path);
    });

    test('副本文件不在：退回取流（没配服务器时照常报不可用）', () async {
      await expectLater(
        musicServerAsrAudioInput(
          refA,
          servers: () async => const <String, MusicServerBinding>{},
          localCopies: (_) => _copy(p.join(tmp.path, 'gone.flac'), 'jf1', 'a'),
        ),
        throwsA(anything),
      );
    });
  });

  group('最近播放重建的项补身份', () {
    late Map<String, MusicServerLocalCopy> copies;
    late MusicServerTrackResolver resolver;
    setUp(() {
      copies = <String, MusicServerLocalCopy>{};
      resolver = MusicServerTrackResolver(
        () async => <MusicServerBrowser>[server],
        localCopies: (String uid) => copies[uid],
      );
    });

    test('快照里的流地址：认回服务器与曲目，其余字段原样', () async {
      final MusicPlayItem rebuilt = MusicPlayItem(
        trackUid: musicServerTrackUid('jf1', 't1'),
        path: 'http://srv/t1',
        title: 'T1',
        durationMs: 1000,
        coverPath: 'C:/c.jpg',
      );
      final MusicPlayItem item = await resolver.withIdentity(rebuilt);
      expect(item.serverTrack?.serverId, 'jf1');
      expect(item.serverTrack?.trackId, 't1');
      expect(item.serverTrack?.kind, MusicServerKind.jellyfin);
      expect(item.path, rebuilt.path);
      expect(item.title, 'T1');
      expect(item.durationMs, 1000);
      expect(item.coverPath, 'C:/c.jpg');
    });

    test('快照里是离线副本路径：经副本索引认回', () async {
      final String uid = musicServerTrackUid('jf1', 't2');
      copies[uid] = _copy('C:/dl/t2.flac', 'jf1', 't2');
      final MusicPlayItem item = await resolver.withIdentity(
        MusicPlayItem(trackUid: uid, path: 'C:/dl/t2.flac', title: 'T2'),
      );
      expect(item.serverTrack?.trackId, 't2');
    });

    test('别的服务器的同形地址 / 本地曲目：原样不动', () async {
      final MusicPlayItem other = MusicPlayItem(
        trackUid: musicServerTrackUid('jf9', 't1'),
        path: 'http://srv/t1',
        title: 'x',
      );
      expect((await resolver.withIdentity(other)).serverTrack, isNull);
      const MusicPlayItem local = MusicPlayItem(
        trackUid: 'local',
        path: 'C:/m/a.flac',
        title: 'a',
      );
      expect(identical(await resolver.withIdentity(local), local), isTrue);
    });
  });

  group('正在播放：服务器曲目的收藏', () {
    test('能收藏；首次显示问一次服务器；切换回写服务器并刷新', () async {
      server.starred
        ..clear()
        ..add('t1');
      server.asked = 0;
      final MusicServerTrackResolver resolver = MusicServerTrackResolver(
        () async => <MusicServerBrowser>[server],
        localCopies: (_) => null,
      );
      final MusicServerTrackFavorites favs = MusicServerTrackFavorites(
        resolve: resolver.resolveItem,
        store: MusicServerFavoriteStore(),
      );
      int notified = 0;
      favs.addListener(() => notified++);
      final MusicPlayItem item = MusicPlayItem(
        trackUid: musicServerTrackUid('jf1', 't1'),
        path: 'C:/dl/t1.flac',
        title: 'T1',
        serverTrack: const MusicServerTrackRef(
          kind: MusicServerKind.jellyfin,
          serverId: 'jf1',
          trackId: 't1',
        ),
      );
      expect(favs.canFavorite(item), isTrue);
      expect(favs.isFavorite(item), isFalse, reason: '还没问到');
      await pumpEventQueue();
      expect(favs.isFavorite(item), isTrue);
      expect(server.asked, 1);
      expect(notified, greaterThan(0));

      await favs.toggle(item);
      expect(server.starred, isNot(contains('t1')));
      expect(favs.isFavorite(item), isFalse);
      expect(server.asked, 1, reason: '问过就不再问');
      favs.dispose();
    });

    test('没带服务器身份 / 试听片段 / 本地曲目：不出心形', () {
      final MusicServerTrackFavorites favs = MusicServerTrackFavorites(
        resolve: (_) async => null,
        store: MusicServerFavoriteStore(),
      );
      expect(
        favs.canFavorite(
          const MusicPlayItem(trackUid: 'local', path: 'C:/a.flac', title: 'a'),
        ),
        isFalse,
      );
      expect(
        favs.canFavorite(
          const MusicPlayItem(
            trackUid: 'srvx',
            path: 'http://srv/x',
            title: 'x',
            isPreview: true,
            serverTrack: MusicServerTrackRef(
              kind: MusicServerKind.jellyfin,
              serverId: 'jf1',
              trackId: 'x',
            ),
          ),
        ),
        isFalse,
      );
      favs.dispose();
    });
  });
}
