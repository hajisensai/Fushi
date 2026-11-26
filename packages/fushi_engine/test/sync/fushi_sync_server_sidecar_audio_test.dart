/// M9OEh1PeYH：互联远端播放 host 的本地视频时拿不到外挂音轨。
///
/// 本机播放器起播时挂视频旁的外挂音轨（BUG-5475），host 的 `/streamurl` 却只下发
/// 字幕、没有可取的音轨流。修复后：
/// 1. host [LocalLibraryHostService.listVideoSidecarAudioTracks] 与本机播放器同一份
///    发现判据（同目录 + 子目录、只认这个视频自己的、只认音轨扩展名）；
/// 2. `/streamurl` 下发 `externalAudioTracks[]`（标签 / 语言 + 同 token 的音轨流 URL），
///    [RemoteVideoStreamUrls.fromJson] 读得出来；
/// 3. 音轨流 `.../sidecaraudio` 豁免 Basic、靠流 token：裸 GET 拿到字节并支持 Range；
///    缺 token 401、错 token 403、下标越界 404；释放流票后作废；
/// 4. 能力位；不实现 [VideoSidecarAudioListHost] 的老 host 不发列表。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _token = 'sidecar-audio-token';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

LocalLibraryHostService _hostService({
  required FushiDatabase db,
  required Directory work,
}) => LocalLibraryHostService(
  db: db,
  dictionaryResourceRoot: work,
  packages: SyncAssetPackageService(db: db),
  refreshDictionaryCache: () async {},
  runExclusive: (Future<void> Function() body) => body(),
);

/// GET [url]；[basic] 为 true 时带 Basic 鉴权。返回 (状态码, 正文字节)。
Future<(int, List<int>)> _get(
  String url, {
  bool basic = true,
  String? range,
}) async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest req = await http.getUrl(Uri.parse(url));
    if (basic) {
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('fushi:$_token'))}',
      );
    }
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse res = await req.close();
    final List<int> body = <int>[
      for (final List<int> chunk in await res.toList()) ...chunk,
    ];
    return (res.statusCode, body);
  } finally {
    http.close(force: true);
  }
}

Future<(int, List<int>)> _post(String url) async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest req = await http.postUrl(Uri.parse(url));
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('fushi:$_token'))}',
    );
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    return (res.statusCode, const <int>[]);
  } finally {
    http.close(force: true);
  }
}

/// `Movie.mkv` 旁：同目录日语音轨、子目录英语 5.1 音轨；外加别的视频的音轨、字幕。
Future<void> _seedMovie(FushiDatabase db, Directory work) async {
  final Directory dir = Directory(p.join(work.path, 'vids'))
    ..createSync(recursive: true);
  final File vid = File(p.join(dir.path, 'Movie.mkv'))
    ..writeAsBytesSync(<int>[1, 2, 3]);
  File(p.join(dir.path, 'Movie.jpn.mka')).writeAsStringSync('JPN-AUDIO');
  Directory(p.join(dir.path, 'Audio 5.1')).createSync();
  File(
    p.join(dir.path, 'Audio 5.1', 'Movie_Eng_Audio_5.1.mka'),
  ).writeAsStringSync('ENG-AUDIO-51');
  File(p.join(dir.path, 'Other.jpn.mka')).writeAsStringSync('OTHER');
  File(p.join(dir.path, 'Movie.ja.srt')).writeAsStringSync('1\n');
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'video/movie',
      title: 'Movie',
      videoPath: vid.path,
    ),
  );
}

/// 改动前的 host：不实现 [VideoSidecarAudioListHost]。
class _LegacyHost implements FushiLibraryHostService {
  _LegacyHost(this.video);

  final File video;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == 'video/movie' ? video : null;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  test('RemoteVideoExternalAudioTrack JSON 往返，缺省值不上 wire', () {
    const RemoteVideoExternalAudioTrack full = RemoteVideoExternalAudioTrack(
      url: 'http://h/a',
      label: 'Eng Audio 5.1',
      language: 'eng',
    );
    final RemoteVideoExternalAudioTrack back =
        RemoteVideoExternalAudioTrack.fromJson(
          jsonDecode(jsonEncode(full.toJson())),
        )!;
    expect(back.url, full.url);
    expect(back.label, full.label);
    expect(back.language, full.language);
    expect(
      const RemoteVideoExternalAudioTrack(url: 'u').toJson(),
      <String, Object?>{'url': 'u'},
    );
  });

  group('host listVideoSidecarAudioTracks', () {
    late Directory work;
    late FushiDatabase db;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('sidecar_audio_host_');
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('与本机播放器同一份判据：同目录 + 子目录，只认这个视频自己的音轨', () async {
      await _seedMovie(db, work);
      final LocalLibraryHostService svc = _hostService(db: db, work: work);
      expect(svc, isA<VideoSidecarAudioListHost>());
      final List<SidecarAudioTrackFile> got = await svc
          .listVideoSidecarAudioTracks('video/movie');
      final String dir = p.join(work.path, 'vids');
      expect(got.map((SidecarAudioTrackFile t) => t.path), <String>[
        p.join(dir, 'Movie.jpn.mka'),
        p.join(dir, 'Audio 5.1', 'Movie_Eng_Audio_5.1.mka'),
      ]);
      expect(got.map((SidecarAudioTrackFile t) => t.language), <String?>[
        'jpn',
        'eng',
      ]);
      expect(got[1].label, 'Eng Audio 5.1');
      expect(
        got.map((SidecarAudioTrackFile t) => t.path),
        (await discoverSidecarAudioTrackFiles(
          p.join(dir, 'Movie.mkv'),
        )).map((SidecarAudioTrackFile t) => t.path),
      );
    });

    test('未知视频 → 空表', () async {
      final LocalLibraryHostService svc = _hostService(db: db, work: work);
      expect(await svc.listVideoSidecarAudioTracks('video/nope'), isEmpty);
    });
  });

  group('端到端：/streamurl 下发外挂音轨 + token 音轨流', () {
    late Directory work;
    late FushiDatabase hostDb;
    late FushiSyncServer server;
    late String base;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('sidecar_audio_e2e_');
      hostDb = _memDb();
      await _seedMovie(hostDb, work);
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: _token,
        allowLan: false,
        libraryService: _hostService(db: hostDb, work: work),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      await hostDb.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    Future<Map<String, Object?>> streamUrl() async {
      final (int status, List<int> body) = await _get(
        '$base/api/library/videos/video/movie/streamurl',
      );
      expect(status, 200, reason: utf8.decode(body));
      return jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    }

    test('capabilities 声明 videoSidecarAudio', () async {
      final (int status, List<int> body) = await _get('$base/api/capabilities');
      expect(status, 200);
      final Map<String, dynamic> json =
          jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      expect(
        (json['liveLibrary']
            as Map<String, dynamic>)[kVideoSidecarAudioCapability],
        isTrue,
      );
    });

    test('/streamurl 列出音轨；播放器裸 GET（不带 Basic）拿到各自字节，支持 Range', () async {
      final RemoteVideoStreamUrls urls = RemoteVideoStreamUrls.fromJson(
        await streamUrl(),
      );
      expect(urls.externalAudioTracks, hasLength(2));
      expect(
        urls.externalAudioTracks.map(
          (RemoteVideoExternalAudioTrack t) => t.language,
        ),
        <String?>['jpn', 'eng'],
      );
      expect(urls.externalAudioTracks[1].label, 'Eng Audio 5.1');
      final Uri first = Uri.parse(urls.externalAudioTracks[0].url);
      expect(first.path, endsWith('/$kVideoSidecarAudioPathSuffix'));
      // 与视频流同一张 token。
      expect(
        first.queryParameters['token'],
        Uri.parse(urls.streamUrl).queryParameters['token'],
      );

      final (int s0, List<int> b0) = await _get(
        urls.externalAudioTracks[0].url,
        basic: false,
      );
      expect(s0, 200);
      expect(utf8.decode(b0), 'JPN-AUDIO');
      final (int s1, List<int> b1) = await _get(
        urls.externalAudioTracks[1].url,
        basic: false,
      );
      expect(s1, 200);
      expect(utf8.decode(b1), 'ENG-AUDIO-51');
      final (int sr, List<int> br) = await _get(
        urls.externalAudioTracks[1].url,
        basic: false,
        range: 'bytes=4-8',
      );
      expect(sr, 206);
      expect(utf8.decode(br), 'AUDIO');
    });

    test('缺 token 401、错 token 403、下标越界 404、释放流票后作废', () async {
      final Map<String, Object?> json = await streamUrl();
      final RemoteVideoStreamUrls urls = RemoteVideoStreamUrls.fromJson(json);
      final Uri good = Uri.parse(urls.externalAudioTracks[0].url);
      Uri withQuery(Map<String, String> q) => good.replace(queryParameters: q);

      final (int missing, _) = await _get(
        withQuery(<String, String>{'n': '0'}).toString(),
        basic: false,
      );
      expect(missing, 401);
      final (int wrong, _) = await _get(
        withQuery(<String, String>{'token': 'nope', 'n': '0'}).toString(),
        basic: false,
      );
      expect(wrong, 403);
      for (final String n in <String>['2', '-1', 'x', '../Other.jpn.mka']) {
        final (int status, _) = await _get(
          withQuery(<String, String>{
            'token': good.queryParameters['token']!,
            'n': n,
          }).toString(),
          basic: false,
        );
        expect(status, 404, reason: 'n=$n');
      }

      final String ticket = json['ticket']! as String;
      final (int released, _) = await _post(
        '$base/api/library/videos/video/movie/streamrelease?ticket=$ticket',
      );
      expect(released, 204);
      final (int after, _) = await _get(good.toString(), basic: false);
      expect(after, 403, reason: '流票释放后音轨流与视频流一起作废');
    });
  });

  group('混版本：老 host（无 VideoSidecarAudioListHost）', () {
    late Directory work;
    late FushiSyncServer server;
    late String base;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('sidecar_audio_legacy_');
      final File video = File(p.join(work.path, 'Movie.mkv'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      File(p.join(work.path, 'Movie.jpn.mka')).writeAsStringSync('JPN');
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: _token,
        allowLan: false,
        libraryService: _LegacyHost(video),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('不发 externalAudioTracks', () async {
      final (int status, List<int> body) = await _get(
        '$base/api/library/videos/video/movie/streamurl',
      );
      expect(status, 200, reason: utf8.decode(body));
      final Map<String, Object?> json =
          jsonDecode(utf8.decode(body)) as Map<String, Object?>;
      expect(json.containsKey('externalAudioTracks'), isFalse);
      expect(RemoteVideoStreamUrls.fromJson(json).externalAudioTracks, isEmpty);
    });
  });
}
