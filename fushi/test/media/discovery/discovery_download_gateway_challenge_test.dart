// BUG-4347：下载网关回 `403 {"code":"pow_required"}` 时，下载队列必须进入解题
// 流程（交给注入的解题器），带着放行凭据重开资源；解不了时以「需要人机验证」
// 失败收尾（带挑战 URL 供「在浏览器中打开」），而不是只报一个 403。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/discovery/download_gateway_challenge.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';

const String _gateway =
    'https://gate.example.net/worker/P/file.rar?sign=abc:1794402936';

DiscoveryResourceItem _item() => const DiscoveryResourceItem(
  sourceId: 'alist-test',
  title: 'file.rar',
  id: '/file.rar',
  kind: DiscoveryMediaKind.game,
  payloadKind: DiscoveryPayloadKind.httpFile,
  payload: DiscoveryHttpPayload(url: _gateway, fileName: 'file.rar'),
);

Future<DiscoveryPayload> _resolver(DiscoveryResourceItem item) async =>
    item.payload!;

Future<void> _waitFor(bool Function() condition) async {
  for (int i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

ResumableDownloadResponse _powRequired() => ResumableDownloadResponse.bytes(
  statusCode: 403,
  body: utf8.encode('{"code":"pow_required"}'),
  headers: const <String, String>{'content-type': 'application/json'},
);

ResumableDownloadResponse _ok(List<int> body) =>
    ResumableDownloadResponse.bytes(
      statusCode: 200,
      body: body,
      headers: <String, String>{'content-length': '${body.length}'},
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gateway_challenge_test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放。
    }
  });

  group('downloadGatewayChallengeCodeOf', () {
    test('403 + {"code":"pow_required"} 判为挑战', () {
      expect(
        downloadGatewayChallengeCodeOf(
          403,
          utf8.encode('{"code":"pow_required"}'),
        ),
        'pow_required',
      );
    });

    test('普通 403 / 非 JSON / 未知 code / 2xx 都不是挑战', () {
      expect(downloadGatewayChallengeCodeOf(403, const <int>[]), isNull);
      expect(
        downloadGatewayChallengeCodeOf(403, utf8.encode('Forbidden')),
        isNull,
      );
      expect(
        downloadGatewayChallengeCodeOf(
          403,
          utf8.encode('{"code":"forbidden"}'),
        ),
        isNull,
      );
      expect(
        downloadGatewayChallengeCodeOf(403, utf8.encode('{"code":403}')),
        isNull,
      );
      expect(
        downloadGatewayChallengeCodeOf(
          200,
          utf8.encode('{"code":"pow_required"}'),
        ),
        isNull,
      );
    });
  });

  test('遇 403 pow_required → 调解题器 → 带放行凭据重开 → done', () async {
    final List<Uri> solved = <Uri>[];
    final List<(Uri, Map<String, String>)> opened =
        <(Uri, Map<String, String>)>[];
    final Uri clearanceUrl = Uri.parse('$_gateway&__ct=consume-token');
    final List<int> body = utf8.encode('rar-bytes');
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(importedCount: 1),
      challengeSolver: (Uri challengeUrl) async {
        solved.add(challengeUrl);
        return DownloadGatewayClearance(
          url: clearanceUrl,
          headers: const <String, String>{
            'Cookie': '__Secure-pow_a=1|c||consume-token',
            'User-Agent': 'TestBrowser/1.0',
          },
        );
      },
      openOverride: (Uri uri, Map<String, String> headers) async {
        opened.add((uri, Map<String, String>.of(headers)));
        return uri == clearanceUrl ? _ok(body) : _powRequired();
      },
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.done);
    expect(task.challengeUrl, isNull);
    expect(solved, <Uri>[Uri.parse(_gateway)]);
    expect(opened.map(((Uri, Map<String, String>) o) => o.$1), <Uri>[
      Uri.parse(_gateway),
      clearanceUrl,
    ]);
    expect(await File(task.filePath!).readAsBytes(), body);
  });

  test('真实 HTTP 栈：raw_url 302 → 网关挑战；挑战 URL 取重定向终点，放行请求带 Cookie/UA', () async {
    // 网关：没带放行 cookie 回 403 pow_required；带了回文件，并记下收到的头。
    final Map<String, String?> received = <String, String?>{};
    final HttpServer gateway = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => gateway.close(force: true));
    unawaited(() async {
      await for (final HttpRequest request in gateway) {
        final String? cookie = request.headers.value(HttpHeaders.cookieHeader);
        if (cookie == null || !cookie.contains('__Secure-pow_a=')) {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"code":"pow_required"}');
        } else {
          received['cookie'] = cookie;
          received['user-agent'] = request.headers.value(
            HttpHeaders.userAgentHeader,
          );
          received['query-ct'] = request.uri.queryParameters['__ct'];
          request.response.write('rar-bytes');
        }
        await request.response.close();
      }
    }());
    final String gatewayUrl =
        'http://127.0.0.1:${gateway.port}/worker/P/file.rar?sign=s:1';

    // AList 站：raw_url 302 到网关（与线上同形）。
    final HttpServer origin = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => origin.close(force: true));
    unawaited(() async {
      await for (final HttpRequest request in origin) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, gatewayUrl);
        await request.response.close();
      }
    }());

    final List<Uri> solved = <Uri>[];
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) async =>
          DiscoveryHttpPayload(
            url: 'http://127.0.0.1:${origin.port}/d/file.rar?sign=x',
            fileName: 'file.rar',
          ),
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
      challengeSolver: (Uri challengeUrl) async {
        solved.add(challengeUrl);
        return DownloadGatewayClearance(
          url: challengeUrl.replace(
            queryParameters: <String, String>{
              ...challengeUrl.queryParameters,
              '__ct': 'consume-token',
            },
          ),
          headers: const <String, String>{
            'Cookie': '__Secure-pow_a=1|c||consume-token',
            'User-Agent': 'TestBrowser/1.0',
          },
        );
      },
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.done, reason: task.error);
    // 挑战 URL 是网关那一跳，不是最初的 raw_url。
    expect(solved, <Uri>[Uri.parse(gatewayUrl)]);
    expect(received['cookie'], contains('__Secure-pow_a=1|c||consume-token'));
    expect(received['user-agent'], 'TestBrowser/1.0');
    expect(received['query-ct'], 'consume-token');
    expect(await File(task.filePath!).readAsString(), 'rar-bytes');
  });

  test('解题器返回 null（用户关掉验证页）→ failed，带挑战 URL，不自动重试', () async {
    int opens = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
      challengeSolver: (Uri challengeUrl) async => null,
      openOverride: (Uri uri, Map<String, String> headers) async {
        opens++;
        return _powRequired();
      },
      retryBackoffOverride: const <Duration>[Duration(milliseconds: 1)],
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.failed);
    expect(task.challengeUrl, Uri.parse(_gateway));
    expect(task.autoRetries, 0);
    expect(opens, 1);
  });

  test('没装解题器 → 同样以挑战失败收尾', () async {
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async =>
          _powRequired(),
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.failed);
    expect(task.challengeUrl, Uri.parse(_gateway));
  });

  test('放行后仍被挡 → 只解一次，failed 带挑战 URL（不循环弹页）', () async {
    int solves = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
      challengeSolver: (Uri challengeUrl) async {
        solves++;
        return DownloadGatewayClearance(url: Uri.parse('$_gateway&__ct=stale'));
      },
      openOverride: (Uri uri, Map<String, String> headers) async =>
          _powRequired(),
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.failed);
    expect(solves, 1);
    expect(task.challengeUrl, isNotNull);
  });

  test('普通 403（无挑战 code）不进解题流程，challengeUrl 为空', () async {
    int solves = 0;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
      challengeSolver: (Uri challengeUrl) async {
        solves++;
        return null;
      },
      openOverride: (Uri uri, Map<String, String> headers) async =>
          ResumableDownloadResponse.bytes(
            statusCode: 403,
            body: utf8.encode('Forbidden'),
          ),
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);

    final DiscoveryDownloadTask task = queue.tasks.single;
    expect(task.status, DiscoveryDownloadStatus.failed);
    expect(task.challengeUrl, isNull);
    expect(task.error, contains('403'));
    expect(solves, 0);
  });

  test('手动重试清掉 challengeUrl', () async {
    bool pass = false;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: _resolver,
      importer: (DiscoveryDownloadTask task, File file) async =>
          const DiscoveryImportOutcome(),
      openOverride: (Uri uri, Map<String, String> headers) async =>
          pass ? _ok(utf8.encode('x')) : _powRequired(),
    );
    addTearDown(queue.dispose);

    queue.enqueue(_item(), destinationDir: tempDir.path);
    await _waitFor(() => queue.tasks.single.isFinished);
    expect(queue.tasks.single.challengeUrl, isNotNull);

    pass = true;
    queue.retry(queue.tasks.single);
    await _waitFor(
      () => queue.tasks.single.status == DiscoveryDownloadStatus.done,
    );
    expect(queue.tasks.single.challengeUrl, isNull);
  });
}
