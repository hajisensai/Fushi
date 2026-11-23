// 服务器曲目身份打通后的几处：生成字幕优先用离线副本、只给 uid + 路径时的认法（歌词）、
// 「正在播放」里服务器曲目的收藏。

import 'dart:async';
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

/// 收藏请求由测试逐个放行 / 失败的服务器。
class _GatedFavServer extends Fake
    implements MusicServerBrowser, MusicServerFavoriteEditing {
  _GatedFavServer(this.serverId);

  @override
  final String serverId;
  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;

  final List<Completer<void>> calls = <Completer<void>>[];

  @override
  Future<void> setFavorite(
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  }) {
    final Completer<void> c = Completer<void>();
    calls.add(c);
    return c.future;
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

  group('只给 uid + 路径的认法（歌词解析）', () {
    late Map<String, MusicServerLocalCopy> copies;
    late MusicServerTrackResolver resolver;
    setUp(() {
      copies = <String, MusicServerLocalCopy>{};
      resolver = MusicServerTrackResolver(
        () async => <MusicServerBrowser>[server],
        localCopies: (String uid) => copies[uid],
      );
    });

    test('流地址：认回服务器与曲目', () async {
      final MusicServerResolvedTrack? r = await resolver.resolve(
        trackUid: musicServerTrackUid('jf1', 't1'),
        path: 'http://srv/t1',
      );
      expect(r?.browser, same(server));
      expect(r?.trackId, 't1');
      expect(r?.ref.kind, MusicServerKind.jellyfin);
    });

    test('离线副本路径：经副本索引认回', () async {
      final String uid = musicServerTrackUid('jf1', 't2');
      copies[uid] = _copy('C:/dl/t2.flac', 'jf1', 't2');
      final MusicServerResolvedTrack? r = await resolver.resolve(
        trackUid: uid,
        path: 'C:/dl/t2.flac',
      );
      expect(r?.trackId, 't2');
      expect(r?.transcoded, isFalse);
    });

    test('别的服务器的同形地址 / 本地曲目：认不出', () async {
      expect(
        await resolver.resolve(
          trackUid: musicServerTrackUid('jf9', 't1'),
          path: 'http://srv/t1',
        ),
        isNull,
      );
      expect(
        await resolver.resolve(trackUid: 'local', path: 'C:/m/a.flac'),
        isNull,
      );
    });
  });

  group('正在播放：服务器曲目的收藏', () {
    test('连点：早先那次晚到的失败不抹掉后来那次的显示；最后一次失败还原到服务器确认的值', () async {
      final _GatedFavServer gated = _GatedFavServer('jf9');
      final MusicServerFavoriteStore store = MusicServerFavoriteStore();
      bool shown() => store.isFavorite(
        gated,
        MusicServerItemKind.track,
        't',
        reported: false,
      );

      // A：收藏（会失败、晚到）；B：取消收藏（成功）。
      final Future<void> a = store.setFavorite(
        gated,
        MusicServerItemKind.track,
        't',
        favorite: true,
      );
      expect(shown(), isTrue);
      final Future<void> b = store.setFavorite(
        gated,
        MusicServerItemKind.track,
        't',
        favorite: false,
      );
      expect(shown(), isFalse);
      gated.calls[1].complete();
      await b;
      gated.calls[0].completeError(StateError('A failed'));
      await expectLater(a, throwsStateError);
      expect(shown(), isFalse, reason: 'A 不是最后一次：不还原，显示归 B');

      // C：收藏（失败，且是最后一次）→ 还原到服务器确认过的 B（取消收藏）。
      final Future<void> c = store.setFavorite(
        gated,
        MusicServerItemKind.track,
        't',
        favorite: true,
      );
      expect(shown(), isTrue);
      gated.calls[2].completeError(StateError('C failed'));
      await expectLater(c, throwsStateError);
      expect(shown(), isFalse);

      // 没有确认过的值：失败还原到服务器报的值。
      final Future<void> d = store.setFavorite(
        gated,
        MusicServerItemKind.track,
        'u',
        favorite: true,
      );
      gated.calls[3].completeError(StateError('D failed'));
      await expectLater(d, throwsStateError);
      expect(
        store.isFavorite(gated, MusicServerItemKind.track, 'u', reported: true),
        isTrue,
      );
      expect(
        store.isFavorite(
          gated,
          MusicServerItemKind.track,
          'u',
          reported: false,
        ),
        isFalse,
      );
    });

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
