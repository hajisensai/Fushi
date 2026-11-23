/// 统一互联模块层（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §3.5，拍板
/// design-imusic-q0 选 a）的验收：
///
/// 1. 六个迁进模块层的功能（漫画 OCR 任务、通用任务、代下载、BT 引擎、订阅、助手）全接上时，
///    `/api/capabilities` 与迁移前**逐字节相同**（[_kLegacyCapabilitiesJson] 是迁移前的服务器在同样
///    装配下吐出的原文）；
/// 2. 都没接时键不出现、前缀仍被模块占住回 404（不掉进 WebDAV 文件树）；
/// 3. 模块前缀 / 能力键冲突在构造时就报错；
/// 4. 统一流票：签发 → Range 取流 → 释放即作废；签发凭据吊销即作废（BUG-4393）；视频票不能走统一
///    取流路径，音乐票也不能拿去取视频。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/interconnect_module.dart';
import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/torrent_engine/host_torrent_engine.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String _token = 'module-layer-token';
const String _peerToken = 'peer-token-1';

/// 迁移前（815279ce19，即 develop d095b87a48 + 设计稿）的服务器在 [_startFull] 同样装配下 `/api/capabilities` 的原文。
const String _kLegacyCapabilitiesJson =
    '{"srsChangesV1":true,"mangaOcr":{"supported":false,"modelsReady":fal'
    'se},"jobs":{"kinds":[]},"downloads":{"supported":true,"backend":"emb'
    'edded","kinds":["video"],"deleteFilesParam":true},"torrentEngine":{"'
    'supported":true,"backend":"embedded","features":[],"pauseControlAvai'
    'lable":null,"detailAvailable":null,"allowedRoots":[]},"subscriptions'
    '":{"supported":true,"providers":["nyaa"]},"assistant":{"available":t'
    'rue},"lookup":{"dictionary":false,"history":false},"mining":false,"g'
    'ameStream":false,"hostUpdate":false,"webdav":{"treeListingLevels":2}'
    ',"liveLibrary":{"dictionaries":false,"books":false,"audio":false,"lo'
    'calAudioContentIdV2":false,"videos":false,"manga":false,"videoMetada'
    'ta":false,"tags":false,"pdfBooks":false,"mediaLinks":false,"streamVi'
    'deos":false,"deletionTombstones":false,"videoDeletion":false,"videoT'
    'ranscode":false,"videoSubtitleDefault":false,"videoSubtitleDefaultEp'
    'isode":false,"videoSubtitleClear":false,"videoSidecarSubtitles":fals'
    'e,"discShareV1":false,"videoClipExport":false,"videoClipAudioDiscTit'
    'le":false,"videoClipAudioDiscTitleAngle":false,"videoClipAudioDiscTi'
    'tleDvd":false,"videoClipAudioDiscTitleDvdAngle":false,"videoSubtitle'
    'Backfill":false,"videoGraphicSubtitleTrack":false,"videoMetadataOrde'
    'ring":false,"serviceConfig":false,"sourceShare":false,"pluginRelay":'
    'false,"profileTransfer":false},"tls":{"enabled":false},"pairing":{"v'
    '2":true}}';

class _OcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _DownloadHost implements HostDownloadHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'backend': 'embedded',
    'kinds': <String>['video'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SubscriptionHost implements HostSubscriptionHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'providers': <String>['nyaa'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _TorrentEngine implements HostTorrentEngine {
  @override
  Future<TorrentEngineCapability> capability() async =>
      const TorrentEngineCapability(supported: true, backend: 'embedded');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Assistant implements HostAssistantProvider {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'available': true,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 测试用模块：提供一种流（音乐曲目），id → 临时目录里的文件。
class _StreamModule extends InterconnectHostModule {
  _StreamModule(this.files);

  final Map<String, File> files;
  final String prefix = '/api/test-module';

  @override
  String get capabilityKey => 'testModule';

  @override
  Future<Object?> capability() async => <String, Object?>{'v': 1};

  @override
  List<String> get routePrefixes => <String>[prefix];

  @override
  Future<shelf.Response> handle(InterconnectRequest request) async =>
      shelf.Response.ok(
        jsonEncode(<String, Object?>{
          'path': request.path,
          'pairedPeer': await request.isPairedPeer(),
          'hasFingerprint': request.credentialFingerprint != null,
        }),
      );

  @override
  Map<LibraryMediaStreamKind, LibraryMediaFileResolver> get streamResolvers =>
      <LibraryMediaStreamKind, LibraryMediaFileResolver>{
        LibraryMediaStreamKind.musicTrack: (String id) async => files[id],
      };
}

class _PrefixModule extends InterconnectHostModule {
  _PrefixModule(this.capabilityKey, this.routePrefixes);

  @override
  final String capabilityKey;

  @override
  final List<String> routePrefixes;

  @override
  Future<Object?> capability() async => null;

  @override
  Future<shelf.Response> handle(InterconnectRequest request) async =>
      shelf.Response.ok('');
}

String _basic(String password) =>
    'Basic ${base64Encode(utf8.encode('hibiki:$password'))}';

Future<({int status, String body, Map<String, String> headers})> _send(
  FushiSyncServer server,
  String method,
  String pathAndQuery, {
  String? password = _token,
  Object? json,
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery'),
    );
    if (password != null) req.headers.set('authorization', _basic(password));
    headers.forEach(req.headers.set);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final HttpClientResponse res = await req.close();
    final List<int> bytes = <int>[
      for (final List<int> chunk in await res.toList()) ...chunk,
    ];
    final String body = utf8.decode(bytes, allowMalformed: true);
    final Map<String, String> out = <String, String>{};
    res.headers.forEach((String k, List<String> v) => out[k] = v.join(','));
    return (status: res.statusCode, body: body, headers: out);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('interconnect_module_layer_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<FushiSyncServer> start({
    bool full = false,
    List<InterconnectHostModule> modules = const <InterconnectHostModule>[],
  }) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token,
      mangaOcrJobs: full
          ? MangaOcrHostJobManager(
              service: _OcrService(),
              jobRoot: Directory('${tmp.path}/ocr'),
            )
          : null,
      hostJobs: full
          ? HostJobManager(
              jobRoot: Directory('${tmp.path}/jobs'),
              runners: const [],
            )
          : null,
      downloads: full ? _DownloadHost() : null,
      torrentEngine: full ? _TorrentEngine() : null,
      subscriptions: full ? _SubscriptionHost() : null,
      assistant: full ? _Assistant() : null,
      modules: modules,
    );
    server.pairedPeerCredentialsProvider = () async => <String, String>{
      'peer-1': _peerToken,
    };
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  test('六个功能全接：能力 JSON 与迁移前逐字节相同', () async {
    final FushiSyncServer server = await start(full: true);
    final res = await _send(server, 'GET', '/api/capabilities');
    expect(res.status, 200);
    expect(res.body, _kLegacyCapabilitiesJson);
  });

  test('都没接：键不出现，前缀仍归模块回 404（不落进 WebDAV）', () async {
    final FushiSyncServer server = await start();
    final res = await _send(server, 'GET', '/api/capabilities');
    final Map<String, dynamic> caps =
        jsonDecode(res.body) as Map<String, dynamic>;
    for (final String key in <String>[
      'mangaOcr',
      'jobs',
      'downloads',
      'torrentEngine',
      'subscriptions',
      'assistant',
    ]) {
      expect(caps.containsKey(key), isFalse, reason: key);
    }
    final Map<String, String> offBodies = <String, String>{
      '/api/ocr/job': 'Manga OCR off',
      '/api/jobs': 'Host jobs off',
      '/api/jobs/x': 'Host jobs off',
      '/api/downloads': 'Host downloads off',
      '/api/torrent-engine/torrents': 'Host torrent engine off',
      '/api/subscriptions': 'Host subscriptions off',
      '/api/assistant': 'Host assistant off',
    };
    for (final MapEntry<String, String> e in offBodies.entries) {
      for (final String method in <String>['GET', 'PUT']) {
        final r = await _send(server, method, e.key);
        expect(r.status, 404, reason: '$method ${e.key}');
        expect(r.body, e.value, reason: '$method ${e.key}');
      }
    }
    expect(Directory('${tmp.path}/sync-data/api').existsSync(), isFalse);
  });

  test('BT 引擎：共享 token 403，已配对设备放行到 handler', () async {
    final FushiSyncServer server = await start(full: true);
    final shared = await _send(server, 'GET', '/api/torrent-engine/torrents');
    expect(shared.status, 403);
    expect(shared.body, '{"error":"paired_peer_required"}');
  });

  test('新模块：经 modules 注册即分发、拼能力位，请求带上身份', () async {
    final FushiSyncServer server = await start(
      modules: <InterconnectHostModule>[_StreamModule(<String, File>{})],
    );
    final caps =
        jsonDecode((await _send(server, 'GET', '/api/capabilities')).body)
            as Map<String, dynamic>;
    expect(caps['testModule'], <String, Object?>{'v': 1});
    final shared = await _send(server, 'GET', '/api/test-module/a/b');
    expect(jsonDecode(shared.body), <String, Object?>{
      'path': '/api/test-module/a/b',
      'pairedPeer': false,
      'hasFingerprint': true,
    });
    final peer = await _send(
      server,
      'GET',
      '/api/test-module',
      password: _peerToken,
    );
    expect((jsonDecode(peer.body) as Map<String, dynamic>)['pairedPeer'], true);
    final anon = await _send(server, 'GET', '/api/test-module', password: null);
    expect(anon.status, 401, reason: '模块路由一律要 Basic');
  });

  group('模块表构造即查冲突', () {
    test('前缀相同 / 互为前缀 / 与内置模块冲突都报错', () {
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x']),
          _PrefixModule('b', <String>['/api/x/y']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x']),
          _PrefixModule('a', <String>['/api/y']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => InterconnectModuleTable(<InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x/']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => FushiSyncServer(
          syncDataDir: tmp.path,
          port: 0,
          token: _token,
          modules: <InterconnectHostModule>[
            _PrefixModule('rogue', <String>['/api/jobs']),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('/api/xy 不归 /api/x', () {
      final InterconnectModuleTable table = InterconnectModuleTable(
        <InterconnectHostModule>[
          _PrefixModule('a', <String>['/api/x']),
        ],
      );
      expect(table.match('/api/x'), isNotNull);
      expect(table.match('/api/x/1'), isNotNull);
      expect(table.match('/api/xy'), isNull);
    });
  });

  group('统一流票', () {
    late File audio;
    late FushiSyncServer server;

    setUp(() async {
      audio = File('${tmp.path}/track.flac')
        ..writeAsBytesSync(List<int>.generate(1000, (int i) => i % 256));
      server = await start(
        modules: <InterconnectHostModule>[
          _StreamModule(<String, File>{'uid-1': audio}),
        ],
      );
    });

    Future<Map<String, dynamic>> issue(String id, {String? password}) async {
      final res = await _send(
        server,
        'POST',
        kLibraryMediaStreamUrlPath,
        password: password ?? _token,
        json: <String, Object?>{'kind': 'musicTrack', 'id': id},
      );
      expect(res.status, 200, reason: res.body);
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    String pathOf(String url) {
      final Uri u = Uri.parse(url);
      return '${u.path}?${u.query}';
    }

    test('签发 → 免 Basic Range 取流 206 → 释放后 403', () async {
      final Map<String, dynamic> grant = await issue('uid-1');
      final String path = pathOf(grant['url'] as String);
      expect(path, startsWith('$kLibraryMediaStreamPath?token='));
      final ranged = await _send(
        server,
        'GET',
        path,
        password: null,
        headers: <String, String>{'range': 'bytes=10-19'},
      );
      expect(ranged.status, 206);
      expect(ranged.body.length, 10);
      expect(server.mediaStreamCount, 1);
      expect(server.videoStreamTokenCount, 0);

      final released = await _send(
        server,
        'POST',
        '$kLibraryMediaStreamReleasePath?ticket=${grant['ticket']}',
      );
      expect(released.status, 204);
      expect(server.mediaStreamCount, 0);
      final after = await _send(server, 'GET', path, password: null);
      expect(after.status, 403);
    });

    test('只有签发者能释放', () async {
      final Map<String, dynamic> grant = await issue('uid-1');
      final other = await _send(
        server,
        'POST',
        '$kLibraryMediaStreamReleasePath?ticket=${grant['ticket']}',
        password: _peerToken,
      );
      expect(other.status, 204);
      expect(server.mediaStreamCount, 1, reason: '别人的凭据释放不动');
    });

    test('签发凭据被吊销即作废（BUG-4393）', () async {
      final Map<String, dynamic> grant = await issue(
        'uid-1',
        password: _peerToken,
      );
      final String path = pathOf(grant['url'] as String);
      expect((await _send(server, 'GET', path, password: null)).status, 200);
      server.pairedPeerCredentialsProvider = () async => <String, String>{};
      server.invalidatePeerTokenCache();
      final revoked = await _send(server, 'GET', path, password: null);
      expect(revoked.status, 403);
      expect(revoked.body, 'Token revoked');
      expect(server.mediaStreamCount, 0);
    });

    test('未知 id 404、未知种类 / 没人提供的种类拒签、签发要 Basic', () async {
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'musicTrack', 'id': 'nope'},
        )).status,
        404,
      );
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'musicVideo', 'id': '1'},
        )).status,
        404,
      );
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'bogus', 'id': '1'},
        )).status,
        400,
      );
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          password: null,
          json: <String, Object?>{'kind': 'musicTrack', 'id': 'uid-1'},
        )).status,
        401,
      );
    });

    test('音乐票取不了视频，视频路径也不认音乐票', () async {
      final Map<String, dynamic> grant = await issue('uid-1');
      final video = await _send(
        server,
        'GET',
        '/api/library/videos/uid-1/stream?token=${grant['ticket']}',
        password: null,
      );
      expect(video.status, isNot(200));
      expect(video.status, isNot(206));
    });
  });

  group('LibraryMediaStreams', () {
    test('上限淘汰最旧者，TTL 过期清掉，onDrop 每张都回调', () {
      DateTime clock = DateTime(2026, 11, 23);
      final List<String> dropped = <String>[];
      final LibraryMediaStreams streams = LibraryMediaStreams(
        now: () => clock,
        capacity: 3,
        onDrop: dropped.add,
      );
      final List<String> tokens = <String>[];
      for (int i = 0; i < 4; i++) {
        clock = clock.add(const Duration(seconds: 1));
        tokens.add(
          streams.issue(
            kind: LibraryMediaStreamKind.musicTrack,
            id: 'u$i',
            issuer: 'f',
          ),
        );
      }
      expect(streams.length, 3);
      expect(streams.contains(tokens.first), isFalse);
      expect(dropped, <String>[tokens.first]);
      clock = clock.add(const Duration(hours: 7));
      streams.prune();
      expect(streams.length, 0);
      expect(dropped, hasLength(4));
    });

    test('release 只认同种类同 id，并连带附属票', () {
      final LibraryMediaStreams streams = LibraryMediaStreams(
        now: DateTime.now,
      );
      final String main = streams.issue(
        kind: LibraryMediaStreamKind.musicVideo,
        id: '7',
        issuer: 'f',
      );
      streams.issue(
        kind: LibraryMediaStreamKind.musicVideo,
        id: '7',
        issuer: 'f',
        ticket: main,
      );
      expect(
        streams.release(
          kind: LibraryMediaStreamKind.musicTrack,
          id: '7',
          ticket: main,
        ),
        isEmpty,
      );
      expect(
        streams.release(
          kind: LibraryMediaStreamKind.musicVideo,
          id: '7',
          ticket: main,
        ),
        hasLength(2),
      );
      expect(streams.length, 0);
    });

    test('同一种流只能注册一个解析器', () {
      final LibraryMediaStreams streams = LibraryMediaStreams(
        now: DateTime.now,
      );
      streams.registerResolver(
        LibraryMediaStreamKind.musicTrack,
        (String _) async => null,
      );
      expect(
        () => streams.registerResolver(
          LibraryMediaStreamKind.musicTrack,
          (String _) async => null,
        ),
        throwsStateError,
      );
    });
  });

  test('守卫：服务器本体不再为已迁进模块层的功能手写分支 / 字段', () {
    final String server = <String>[
      File('lib/sync/fushi_sync_server.dart').readAsStringSync(),
      for (final FileSystemEntity f in Directory(
        'lib/sync/fushi_sync_server',
      ).listSync())
        if (f is File && f.path.endsWith('.dart')) f.readAsStringSync(),
    ].join(String.fromCharCode(10));
    for (final String banned in <String>[
      "reqPath == '/api/ocr/job'",
      "reqPath == '/api/jobs'",
      "reqPath == '/api/downloads'",
      'kTorrentEngineRoutePrefix',
      "reqPath == '/api/assistant'",
      "reqPath == '/api/subscriptions'",
      'handleMangaOcrRequest(',
      'handleHostJobRequest(',
      'handleHostDownloadRequest(',
      'handleHostTorrentEngineRequest(',
      'handleHostAssistantRequest(',
      'handleHostSubscriptionRequest(',
      'HostAssistantSessions? _assistant',
      'HostJobManager? _hostJobs',
      '_VideoStreamToken> _videoStreamTokens',
    ]) {
      expect(server.contains(banned), isFalse, reason: banned);
    }
  });
}
