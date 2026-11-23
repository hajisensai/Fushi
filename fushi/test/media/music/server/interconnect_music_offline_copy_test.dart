// 互联 host 曲目的离线副本（design-imusic-q12）：与 Jellyfin / Subsonic 同一条离线副本管线
// （MusicServerDownloadService）。host 现签一张「原样 + 整首」的票，按通道的证书指纹钉扎直接取；
// 封面经钉扎通道取字节；host 上生效的歌词（来源 / 偏移）存进歌词缓存；uid 不变（host 的
// track_uid），之后放本机文件，且不带服务器身份（host 没有播放上报 / 收藏接口）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/interconnect_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_downloads.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

class _Host implements InterconnectMusicTransport {
  final List<Object?> issued = <Object?>[];
  final List<String> covers = <String>[];

  @override
  Future<InterconnectMusicResponse> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Object? json,
    required Duration timeout,
  }) async {
    Object? body;
    Uint8List? raw;
    if (path == '/api/library/media/streamurl') {
      issued.add(json);
      body = <String, Object?>{
        'url': 'https://h/api/library/media/stream?token=t${issued.length}',
        'ticket': 't${issued.length}',
        'segmentApplied': true,
      };
    } else if (path.endsWith('/lyrics')) {
      body = <String, Object?>{
        'source': 'sidecar',
        'format': 'lrc',
        'raw': base64Encode(utf8.encode('[00:01.00]ホスト')),
        'offsetMs': 250,
        'isUserEdited': false,
        'updatedAt': 1,
      };
    } else if (path.contains('/covers/')) {
      covers.add(path);
      raw = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
    } else if (path.contains('/tracks/')) {
      body = <String, Object?>{'id': 'host-uid', 'title': 'Song'};
    } else {
      body = const <String, Object?>{};
    }
    return (
      status: 200,
      bytes: raw ?? Uint8List.fromList(utf8.encode(jsonEncode(body))),
      json: body is Map<String, Object?> ? body : null,
      resolve: (String p, Map<String, String> q) => Uri(
        scheme: 'https',
        host: 'h',
        path: p,
        queryParameters: q.isEmpty ? null : q,
      ),
      pin: 'AA:BB:CC',
    );
  }

  @override
  void close() {}
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late MusicServerDownloadIndex index;
  late InterconnectDownloadManager downloads;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('imusic_offline_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    index = MusicServerDownloadIndex()..attach(db);
    downloads = InterconnectDownloadManager();
  });
  tearDown(() async {
    index.dispose();
    musicServerLocalCopyLookup = null;
    downloads.dispose();
    await db.close();
    await root.delete(recursive: true);
  });

  test('host 曲目：钉扎直取整首原样、封面经通道、host 歌词入缓存、之后放本机文件', () async {
    final _Host host = _Host();
    final InterconnectMusicBrowser browser = InterconnectMusicBrowser(
      serverId: 'pc',
      displayName: 'PC',
      transport: host,
      // 串流设了码率上限，下载不带。
      maxBitrateKbps: () => 128,
    );
    expect(MusicServerDownloadService.supports(browser), isTrue);
    final List<({String pin, String url})> pinned =
        <({String pin, String url})>[];
    final List<({String trackUid, MusicHostLyrics? lyrics})> savedLyrics =
        <({String trackUid, MusicHostLyrics? lyrics})>[];
    final MusicServerDownloadService service = MusicServerDownloadService(
      downloads: downloads,
      db: db,
      root: () async => root,
      index: index,
      transfer:
          ({
            required String url,
            required Map<String, String> headers,
            required File dest,
            void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal,
          }) async => fail('host 地址必须走钉扎的传输'),
      pinnedTransfer: (String pin) =>
          ({
            required String url,
            required Map<String, String> headers,
            required File dest,
            void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal,
          }) async {
            pinned.add((pin: pin, url: url));
            await dest.parent.create(recursive: true);
            await dest.writeAsBytes(<int>[
              ...'fLaC'.codeUnits,
              ...List<int>.filled(64, 7),
            ]);
          },
      fetchBytes: (Uri uri) async => fail('host 封面必须经通道取'),
      saveHostLyrics:
          ({
            required String trackUid,
            required int? durationMs,
            required MusicHostLyrics? lyrics,
          }) async => savedLyrics.add((trackUid: trackUid, lyrics: lyrics)),
      measureLoudness: (String input) async =>
          (measurement: null, failed: true, returnCode: 1),
      clock: () => 1000,
    );
    const MusicServerTrack track = MusicServerTrack(
      id: 'host-uid',
      title: 'Song',
      artist: 'Aimer',
      album: 'Album',
      albumId: 'alb1',
      container: 'flac',
      coverRef: 'a:alb1',
    );
    expect(
      await service.download(browser, track),
      MusicServerDownloadStart.started,
    );
    for (int i = 0; i < 200 && !index.isDownloaded('host-uid'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(index.isDownloaded('host-uid'), isTrue);

    // 原样（不带码率上限）+ 整首，按通道的证书指纹钉扎直取。
    expect(host.issued.single, <String, Object?>{
      'kind': 'musicTrack',
      'id': 'host-uid',
      'options': <String, Object?>{'segment': true},
    });
    expect(pinned.single, (
      pin: 'AA:BB:CC',
      url: 'https://h/api/library/media/stream?token=t1',
    ));
    expect(host.covers.single, contains('/covers/'));
    final MusicServerDownloadRow row = index.rowOf('host-uid')!;
    expect(row.coverPath, endsWith('cover.jpg'));
    expect(row.serverKind, MusicServerKind.fushiHost.wire);
    expect(savedLyrics.single.trackUid, 'host-uid');
    expect(savedLyrics.single.lyrics?.offsetMs, 250);

    // 曲库里那一行是 fushi_host 种类；放本机文件、不带服务器身份。
    final MusicRemoteTrackRow lib = (await db.getMusicRemoteTrack('host-uid'))!;
    expect(lib.kind, MusicRemoteTrackKind.fushiHost.wire);
    final MusicPlayItem? offline = musicPlayItemOfRemote(lib);
    expect(offline?.path, row.filePath);
    expect(offline?.serverTrack, isNull);
    expect(musicRemoteCoverUrlOf(lib), row.coverPath);
    expect(MusicRemoteEntry(lib).available, isTrue);
    // 服务器页直接点开：同一个 uid（host 的 track_uid）、本机文件。
    final MusicPlayItem item = musicServerPlayItem(browser, track);
    expect(item.trackUid, 'host-uid');
    expect(item.path, row.filePath);
    expect(item.serverTrack, isNull);
  });

  test('没有副本的 host 曲目：占位路径、不带服务器身份（不进播放上报 / 补发队列）', () {
    final InterconnectMusicBrowser browser = InterconnectMusicBrowser(
      serverId: 'pc',
      displayName: 'PC',
      transport: _Host(),
    );
    final MusicPlayItem item = musicServerPlayItem(
      browser,
      const MusicServerTrack(id: 'u9', title: 'X'),
    );
    expect(item.trackUid, 'u9');
    expect(item.path, startsWith('fushi-host'));
    expect(item.serverTrack, isNull);
  });
}
