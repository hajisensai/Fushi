// 把互联 host 曲目下载成本机曲目（design-imusic-q12）：原样音质 + 整首（forDownload 签票）、封面经钉扎
// 通道、host 歌词写成 sidecar、导入后 host uid 并进本机曲目（歌词偏移 / 引用跟过来，fushi_host
// 远程曲目行删掉）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_download.dart';
import 'package:fushi/src/media/music/server/interconnect_music_client.dart';
import 'package:fushi/src/media/music/server/interconnect_music_download.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:path/path.dart' as p;

class _Host implements InterconnectMusicTransport {
  final List<Map<String, Object?>> issued = <Map<String, Object?>>[];

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
      issued.add(json! as Map<String, Object?>);
      body = <String, Object?>{
        'url': 'https://h/api/library/media/stream?token=d',
        'ticket': 'd',
        'segmentApplied': true,
      };
    } else if (path.endsWith('/lyrics')) {
      body = <String, Object?>{
        'source': 'sidecar',
        'format': 'lrc',
        'raw': base64Encode(utf8.encode('[00:01.00]host')),
      };
    } else if (path.contains('/covers/')) {
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
    );
  }

  @override
  void close() {}
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('imusic_dl_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('下载：整首原样签票、封面 + 歌词 sidecar、导入后 host uid 并进本机曲目', () async {
    final _Host host = _Host();
    final InterconnectMusicBrowser browser = InterconnectMusicBrowser(
      serverId: 'pc',
      displayName: 'PC',
      transport: host,
      maxBitrateKbps: () => 128,
    );
    final InterconnectDownloadManager downloads = InterconnectDownloadManager();
    final List<String> imported = <String>[];
    final List<({String hostUid, String localPath})> adopted =
        <({String hostUid, String localPath})>[];
    final List<String> transferred = <String>[];
    final InterconnectMusicDownloadService service =
        InterconnectMusicDownloadService(
          downloads: downloads,
          root: () async => tmp,
          import: (String path) async {
            imported.add(path);
            return null;
          },
          adopt: ({required String hostUid, required String localPath}) async =>
              adopted.add((hostUid: hostUid, localPath: localPath)),
          transfer:
              ({
                required String url,
                required Map<String, String> headers,
                required File dest,
                void Function(double progress)? onProgress,
                void Function(int received, int? total)? onBytes,
                Future<void>? cancelSignal,
              }) async {
                transferred.add(url);
                await dest.parent.create(recursive: true);
                await dest.writeAsBytes(<int>[
                  ...ascii.encode('fLaC'),
                  ...List<int>.filled(64, 0),
                ]);
              },
          writeTags: (String path, Object _) async {},
        );
    final MusicPluginDownloadStart outcome = await service.download(
      browser,
      const MusicServerTrack(
        id: 'host-uid',
        title: 'Song',
        artist: 'Aimer',
        album: 'Album',
        coverRef: 'a:alb1',
      ),
    );
    expect(outcome, MusicPluginDownloadStart.started);
    final Completer<void> done = Completer<void>();
    void check() {
      if (downloads.tasks.values.every(
            (InterconnectDownloadTask t) => !t.isRunning,
          ) &&
          !done.isCompleted) {
        done.complete();
      }
    }

    downloads.addListener(check);
    check();
    await done.future.timeout(const Duration(seconds: 10));
    downloads.removeListener(check);

    // 下载不带码率上限、要整首。
    expect(host.issued.single, <String, Object?>{
      'kind': 'musicTrack',
      'id': 'host-uid',
      'options': <String, Object?>{'segment': true},
    });
    expect(transferred.single, 'https://h/api/library/media/stream?token=d');
    final String audio = imported.single;
    expect(audio, endsWith('.flac'));
    expect(
      File(
        p.join(p.dirname(audio), '${p.basenameWithoutExtension(audio)}.lrc'),
      ).readAsStringSync(),
      '[00:01.00]host',
    );
    expect(File(p.join(p.dirname(audio), 'cover.jpg')).existsSync(), isTrue);
    expect(adopted.single, (hostUid: 'host-uid', localPath: audio));
  });

  test('adopt：歌词偏移等引用改指本机曲目，fushi_host 远程曲目行删掉', () async {
    await db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: 'local-uid',
            path: '/m/Song.flac',
            title: 'Song',
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
    await db
        .into(db.musicRemoteTracks)
        .insert(
          MusicRemoteTracksCompanion.insert(
            trackUid: 'host-uid',
            kind: 'fushi_host',
            sourceKey: 'pc',
            itemId: 'host-uid',
            title: 'Song',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: 'host-uid',
            source: 'user',
            format: 'lrc',
            raw: Uint8List.fromList(utf8.encode('[00:01.00]x')),
            offsetMs: const Value<int>(300),
            updatedAt: 5,
          ),
        );
    await adoptInterconnectMusicDownload(
      db,
      hostUid: 'host-uid',
      localPath: '/m/Song.flac',
    );
    final List<MusicLyricRow> lyrics = await db.select(db.musicLyrics).get();
    expect(lyrics.single.trackUid, 'local-uid');
    expect(lyrics.single.offsetMs, 300);
    expect(await db.select(db.musicRemoteTracks).get(), isEmpty);
    // 本机还没有这条路径（导入失败）：什么也不做。
    await adoptInterconnectMusicDownload(
      db,
      hostUid: 'x',
      localPath: '/nope.flac',
    );
  });
}
