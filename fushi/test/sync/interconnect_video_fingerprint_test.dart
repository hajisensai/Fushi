import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// 拍板台 IFCPPprIpT：远程播放互联 host 的视频制卡，卡片来源要带 `fushi://source`
/// 链接。本机没有原文件可算指纹，由 host 对它串流的同一个文件算全文件 SHA-256
/// （`/api/library/videos/<id>/fingerprint`），与本地制卡的 [VideoSourceFingerprint]
/// 同一口径——这样远程制的卡在 host 本机回跳时，本地核验能对上。

/// 只实现本测试触达的 [resolveVideoFile]；其余经 noSuchMethod 抛（触达即协议走偏）。
class _Host implements FushiLibraryHostService {
  _Host(this.files, {this.videos});

  /// `(id, episodeIndex)` → host 上的原文件。
  final Map<(String, int), File> files;
  final List<(String, int)> calls = <(String, int)>[];

  /// 视频清单（后台预热用）；null = 本测试不触达清单。
  final List<RemoteVideoInfo>? videos;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async =>
      videos ?? (throw UnimplementedError('listVideos'));

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async {
    calls.add((id, episodeIndex));
    return files[(id, episodeIndex)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<InterconnectSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(() async => db.close());
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String url, String tok) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

Future<({int status, String body})> _rawRequest(
  String base,
  String pathAndQuery, {
  String method = 'GET',
  String? token,
}) async {
  final HttpClient c = HttpClient();
  try {
    final HttpClientRequest req = await c.openUrl(
      method,
      Uri.parse('$base$pathAndQuery'),
    );
    if (token != null) {
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
    }
    final HttpClientResponse res = await req.close();
    return (status: res.statusCode, body: await utf8.decodeStream(res));
  } finally {
    c.close();
  }
}

void main() {
  const String token = 'video-fingerprint-token';
  late Directory dir;
  late File single;
  late File episode2;
  late _Host host;
  late String base;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('hbk_vfp');
    addTearDown(() => dir.deleteSync(recursive: true));
    single = File('${dir.path}/single.mkv')
      ..writeAsBytesSync(List<int>.generate(300000, (int i) => i % 251));
    episode2 = File('${dir.path}/ep2.mkv')
      ..writeAsBytesSync(List<int>.generate(200000, (int i) => i % 241));
    host = _Host(<(String, int), File>{
      ('video/夏目友人帳 第1話', 0): single,
      ('video/series', 2): episode2,
    });
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_vfp_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: host,
    );
    await server.start();
    addTearDown(server.stop);
    base = 'http://127.0.0.1:${server.port}';
  });

  test('client 取到的指纹 = host 原文件的全文件 SHA-256（与本地制卡同口径）', () async {
    final InterconnectSyncBackend backend = await _buildBackend(
      base: base,
      token: token,
    );
    expect(backend, isA<RemoteVideoFingerprintSource>());
    final String? remote = await backend.fetchRemoteVideoFingerprint(
      'video/夏目友人帳 第1話',
    );
    expect(remote, sha256.convert(single.readAsBytesSync()).toString());
    expect(
      remote,
      await VideoSourceFingerprint.instance.fingerprint(single.path),
      reason: 'host 本机回跳时用本地指纹核验，两边必须逐字相同',
    );
  });

  test('按集下标取那一集的文件（与 /streamurl 同一下标）', () async {
    final InterconnectSyncBackend backend = await _buildBackend(
      base: base,
      token: token,
    );
    final String? remote = await backend.fetchRemoteVideoFingerprint(
      'video/series',
      episodeIndex: 2,
    );
    expect(remote, sha256.convert(episode2.readAsBytesSync()).toString());
    expect(host.calls.last, ('video/series', 2));
  });

  test('BUG-4782：新 host 上没有该条目 / 文件已不在 → 担保不了（不是老 host 的 null）', () async {
    final InterconnectSyncBackend backend = await _buildBackend(
      base: base,
      token: token,
    );
    await expectLater(
      backend.fetchRemoteVideoFingerprint('video/nope'),
      throwsA(
        isA<RemoteVideoFingerprintUnavailable>().having(
          (RemoteVideoFingerprintUnavailable e) => e.reason,
          'reason',
          kVideoFingerprintReasonNotFound,
        ),
      ),
    );
    single.deleteSync();
    await expectLater(
      backend.fetchRemoteVideoFingerprint('video/夏目友人帳 第1話'),
      throwsA(
        isA<RemoteVideoFingerprintUnavailable>().having(
          (RemoteVideoFingerprintUnavailable e) => e.reason,
          'reason',
          kVideoFingerprintReasonUnreadable,
        ),
      ),
    );
  });

  test('BUG-4782：host 端担保不了时回 409 + reason，绝不回 404', () async {
    final String missing =
        '/api/library/videos/${Uri.encodeFull('video/nope')}/fingerprint';
    final ({int status, String body}) notFound = await _rawRequest(
      base,
      missing,
      token: token,
    );
    expect(notFound.status, kVideoFingerprintUnavailableStatus);
    expect(notFound.status, isNot(404));
    expect(
      (jsonDecode(notFound.body) as Map<String, dynamic>)['reason'],
      kVideoFingerprintReasonNotFound,
    );
    single.deleteSync();
    final ({int status, String body}) unreadable = await _rawRequest(
      base,
      '/api/library/videos/${Uri.encodeFull('video/夏目友人帳 第1話')}/fingerprint',
      token: token,
    );
    expect(unreadable.status, kVideoFingerprintUnavailableStatus);
    expect(
      (jsonDecode(unreadable.body) as Map<String, dynamic>)['reason'],
      kVideoFingerprintReasonUnreadable,
    );
  });

  test('拍板台 left3657：回跳 wait: false 时 host 没算过就回 202、不干等，后台算完后答出指纹', () async {
    final File fresh = File('${dir.path}/fresh.mkv')
      ..writeAsBytesSync(List<int>.generate(150000, (int i) => i % 239));
    host.files[('video/fresh', 0)] = fresh;
    final String path =
        '/api/library/videos/${Uri.encodeFull('video/fresh')}/fingerprint'
        '?$kVideoFingerprintWaitQueryParam=0';
    final ({int status, String body}) pending = await _rawRequest(
      base,
      path,
      token: token,
    );
    expect(pending.status, kVideoFingerprintPendingStatus);
    final InterconnectSyncBackend backend = await _buildBackend(
      base: base,
      token: token,
    );
    // host 已在后台开算：等同一次在途计算落定后，wait: false 也能拿到真指纹。
    final String expected = sha256.convert(fresh.readAsBytesSync()).toString();
    expect(
      await VideoSourceFingerprint.instance.fingerprint(fresh.path),
      expected,
    );
    expect(
      await backend.fetchRemoteVideoFingerprint('video/fresh', wait: false),
      expected,
    );
  });

  test('拍板台 left3657：wait: false 遇到 host 读不了照样 409，不当成「还没算好」', () async {
    final InterconnectSyncBackend backend = await _buildBackend(
      base: base,
      token: token,
    );
    single.deleteSync();
    await expectLater(
      backend.fetchRemoteVideoFingerprint('video/夏目友人帳 第1話', wait: false),
      throwsA(isA<RemoteVideoFingerprintUnavailable>()),
    );
  });

  test('拍板台 left3657：host 起服务后后台预热视频库指纹并落盘到 sync-data 之外', () async {
    final File warm = File('${dir.path}/warm.mkv')
      ..writeAsBytesSync(List<int>.generate(120000, (int i) => i % 233));
    final Directory root = Directory.systemTemp.createTempSync('hbk_vfp_warm');
    addTearDown(() => root.deleteSync(recursive: true));
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: root.path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: _Host(
        <(String, int), File>{('video/warm', 0): warm},
        videos: const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'video/warm', title: 'warm'),
          RemoteVideoInfo(id: 'video/strm', title: 'strm', peerPlayable: false),
        ],
      ),
      videoFingerprintWarmDelay: Duration.zero,
    );
    await server.start();
    addTearDown(server.stop);
    final String expected = sha256.convert(warm.readAsBytesSync()).toString();
    final File store = File('${root.path}/video_fingerprints.json');
    final Stopwatch clock = Stopwatch()..start();
    while (!(store.existsSync() &&
        store.readAsStringSync().contains(expected))) {
      if (clock.elapsed > const Duration(seconds: 30)) {
        fail('后台预热 30 秒内没有落盘');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await VideoSourceFingerprint.instance.known(warm.path), expected);
    expect(
      Directory(server.syncDataDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('video_fingerprints.json')),
      isEmpty,
      reason: '落盘缓存不放进 WebDAV 根，不暴露给对端',
    );
  });

  test('老 host（没有 /fingerprint 端点、兜底 404）→ null，按 bookUid 放行', () async {
    final HttpServer legacy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => legacy.close(force: true));
    legacy.listen((HttpRequest request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });
    final InterconnectSyncBackend backend = await _buildBackend(
      base: 'http://127.0.0.1:${legacy.port}',
      token: token,
    );
    expect(await backend.fetchRemoteVideoFingerprint('video/x'), isNull);
  });

  test('BUG-4782：host 回的指纹不是 64 位小写 hex → 担保不了，不当老 host', () async {
    final HttpServer odd = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => odd.close(force: true));
    odd.listen((HttpRequest request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, String>{'fingerprint': 'ABC'}));
      await request.response.close();
    });
    final InterconnectSyncBackend backend = await _buildBackend(
      base: 'http://127.0.0.1:${odd.port}',
      token: token,
    );
    await expectLater(
      backend.fetchRemoteVideoFingerprint('video/x'),
      throwsA(isA<RemoteVideoFingerprintUnavailable>()),
    );
  });

  test('端点要 Basic 鉴权，且只接 GET', () async {
    final String path =
        '/api/library/videos/${Uri.encodeFull('video/夏目友人帳 第1話')}/fingerprint';
    expect((await _rawRequest(base, path)).status, 401);
    expect(
      (await _rawRequest(base, path, method: 'POST', token: token)).status,
      405,
    );
    final ({int status, String body}) ok = await _rawRequest(
      base,
      path,
      token: token,
    );
    expect(ok.status, 200);
    expect(
      (jsonDecode(ok.body) as Map<String, dynamic>)['fingerprint'],
      sha256.convert(single.readAsBytesSync()).toString(),
    );
  });
}
