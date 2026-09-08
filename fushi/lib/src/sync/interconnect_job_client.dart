/// 互联「通用任务」客户端（`/api/jobs`，设计 §3.4）：在已配对 host 上跑 ASR 这类
/// 重活，上传输入 → 轮询 → 取回产物。
///
/// 与 `interconnect_manga_ocr_client.dart` 同一形状（探测能力位 → 选 host →
/// create/upload/start/poll/result → 取消即 DELETE），鉴权同样是 per-peer token
/// 的 Basic + TLS 指纹钉扎。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart'
    show mangaOcrPollDelay;
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 一台宣告了 `jobs.kinds` 的 host。
class HostJobTarget {
  const HostJobTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.kinds,
    required this.capability,
    this.fingerprintSha256,
  });

  final String baseUrl;
  final String? deviceName;
  final List<String> kinds;

  /// `/api/capabilities` 里的 `jobs` 原样（每种 kind 的就绪信息）。
  final Map<String, Object?> capability;
  final String? fingerprintSha256;

  bool supports(String kind) => kinds.contains(kind);

  /// `asr` 任务：该 host 对某语言的模型是否就绪。
  bool asrModelReady(String languageTag) {
    final Object? asr = capability['asr'];
    if (asr is! Map) return false;
    final Object? languages = asr['languages'];
    if (languages is! Map) return false;
    final Object? entry = languages[languageTag];
    return entry is Map && entry['ready'] == true;
  }

  String get label => deviceName ?? baseUrl;
}

sealed class HostJobEvent {
  const HostJobEvent();
}

class HostJobUploading extends HostJobEvent {
  const HostJobUploading(this.done, this.total);
  final int done;
  final int total;
}

class HostJobRunning extends HostJobEvent {
  const HostJobRunning(this.progress, this.message);
  final double progress;
  final String? message;
}

class HostJobDone extends HostJobEvent {
  const HostJobDone(this.outputs);

  /// 产物名 → 本地文件。
  final Map<String, File> outputs;
}

class HostJobRemoteException implements Exception {
  const HostJobRemoteException(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'HostJobRemoteException($code)' : 'HostJobRemoteException($code: $detail)';
}

class InterconnectJobClient {
  InterconnectJobClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
    Duration uploadTimeout = const Duration(minutes: 30),
    Duration Function(int attempt)? pollDelay,
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _pinnedClientFactory = pinnedClientFactory ?? _defaultPinnedClient,
        _probeTimeout = probeTimeout,
        _requestTimeout = requestTimeout,
        _uploadTimeout = uploadTimeout,
        _pollDelay = pollDelay ?? mangaOcrPollDelay;

  final SyncRepository _repo;
  final http.Client _httpClient;
  final http.Client Function(String expectedFingerprint) _pinnedClientFactory;
  final Duration _probeTimeout;
  final Duration _requestTimeout;
  final Duration _uploadTimeout;
  final Duration Function(int attempt) _pollDelay;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 找到第一台支持 [kind] 的已配对 host。
  Future<HostJobTarget?> probe(String kind) async {
    final List<FushiClientUrl> candidates = (await _repo.getFushiClientUrls())
        .where((FushiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? fallbackToken = await _repo.getFushiClientToken();
    for (final FushiClientUrl candidate in candidates) {
      final Uri? uri = _uri(candidate.url, '/api/capabilities');
      if (uri == null) continue;
      final String? token = interconnectTokenFor(candidate, fallbackToken);
      if (token == null) continue;
      final (http.Client client, bool closeAfter) =
          _clientFor(candidate.url, fingerprint: candidate.fingerprintSha256);
      try {
        final http.Response response =
            await client.get(uri, headers: _headers(token)).timeout(_probeTimeout);
        if (response.statusCode != 200) continue;
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) continue;
        final Object? jobs = decoded['jobs'];
        if (jobs is! Map) continue;
        final List<String> kinds =
            (jobs['kinds'] as List?)?.map((Object? e) => '$e').toList() ?? const <String>[];
        if (!kinds.contains(kind)) continue;
        return HostJobTarget(
          baseUrl: candidate.url,
          deviceName: candidate.deviceName,
          kinds: kinds,
          capability: Map<String, Object?>.from(jobs),
          fingerprintSha256: candidate.fingerprintSha256,
        );
      } catch (_) {
        continue;
      } finally {
        if (closeAfter) client.close();
      }
    }
    return null;
  }

  /// 跑一个任务：上传 [inputs]（文件名 = 上传名），轮询到终态，把产物下载到
  /// [outputDir]。取消订阅即远端 DELETE。
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required String kind,
    required Map<String, Object?> params,
    required List<File> inputs,
    required Directory outputDir,
  }) {
    final StreamController<HostJobEvent> controller = StreamController<HostJobEvent>();
    bool cancelled = false;
    String? jobId;

    Future<void> cleanupRemote() async {
      final String? id = jobId;
      if (id == null) return;
      jobId = null;
      final (http.Client c, bool close) =
          _clientFor(target.baseUrl, fingerprint: target.fingerprintSha256);
      try {
        final String? token = await _tokenForBaseUrl(target.baseUrl);
        final Uri? uri = _uri(target.baseUrl, '/api/jobs/$id');
        if (token == null || uri == null) return;
        await c.delete(uri, headers: _headers(token)).timeout(_requestTimeout);
      } catch (_) {
        // best-effort
      } finally {
        if (close) c.close();
      }
    }

    controller.onListen = () {
      unawaited(() async {
        final (http.Client c, bool close) =
            _clientFor(target.baseUrl, fingerprint: target.fingerprintSha256);
        try {
          final String? token = await _tokenForBaseUrl(target.baseUrl);
          if (token == null || token.isEmpty) throw const HostJobRemoteException('no_host');
          final Map<String, dynamic> created = _json(
            await _send(c, token, 'POST', target, '/api/jobs',
                jsonBody: <String, Object?>{'kind': kind, 'params': params}),
          );
          final String id = created['jobId'].toString();
          jobId = id;
          controller.add(HostJobUploading(0, inputs.length));
          for (int i = 0; i < inputs.length; i++) {
            if (cancelled) throw const HostJobRemoteException('cancelled');
            final File f = inputs[i];
            await _upload(c, token, target, '/api/jobs/$id/input/${Uri.encodeComponent(p.basename(f.path))}', f);
            controller.add(HostJobUploading(i + 1, inputs.length));
          }
          if (cancelled) throw const HostJobRemoteException('cancelled');
          await _send(c, token, 'POST', target, '/api/jobs/$id/start');
          int attempt = 0;
          while (true) {
            if (cancelled) throw const HostJobRemoteException('cancelled');
            await Future<void>.delayed(_pollDelay(attempt++));
            final Map<String, dynamic> status =
                _json(await _send(c, token, 'GET', target, '/api/jobs/$id'));
            final String state = status['state'].toString();
            final double progress = (status['progress'] as num?)?.toDouble() ?? 0;
            final String? message = status['message']?.toString();
            if (state == 'done') {
              final List<String> names = (status['outputs'] as List?)
                      ?.map((Object? e) => '$e')
                      .toList() ??
                  const <String>[];
              await outputDir.create(recursive: true);
              final Map<String, File> files = <String, File>{};
              for (final String name in names) {
                final http.Response r = await _send(c, token, 'GET', target,
                    '/api/jobs/$id/result/${Uri.encodeComponent(name)}');
                final File out = File(p.join(outputDir.path, p.basename(name)));
                await out.writeAsBytes(r.bodyBytes, flush: true);
                files[name] = out;
              }
              jobId = null;
              await _send(c, token, 'DELETE', target, '/api/jobs/$id');
              controller.add(HostJobDone(files));
              await controller.close();
              return;
            }
            if (state == 'error') {
              throw HostJobRemoteException('remote_error', status['error']?.toString());
            }
            if (state == 'cancelled') throw const HostJobRemoteException('cancelled');
            controller.add(HostJobRunning(progress, message));
          }
        } catch (e, stack) {
          if (!controller.isClosed) {
            controller.addError(e, stack);
            await controller.close();
          }
          await cleanupRemote();
        } finally {
          if (close) c.close();
        }
      }());
    };
    controller.onCancel = () {
      cancelled = true;
      unawaited(cleanupRemote());
    };
    return controller.stream;
  }

  // ── HTTP 助手（与漫画 OCR 客户端同款） ─────────────────────────────

  Future<String?> _tokenForBaseUrl(String baseUrl) async {
    final String? fallbackToken = await _repo.getFushiClientToken();
    final List<FushiClientUrl> urls = await _repo.getFushiClientUrls();
    for (final FushiClientUrl u in urls) {
      if (u.url == baseUrl) return interconnectTokenFor(u, fallbackToken);
    }
    return (fallbackToken != null && fallbackToken.isNotEmpty) ? fallbackToken : null;
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      };

  (http.Client, bool) _clientFor(String baseUrl, {String? fingerprint}) {
    final Uri? base = _parse(baseUrl);
    final bool usePinned = base != null &&
        base.isScheme('https') &&
        fingerprint != null &&
        fingerprint.isNotEmpty;
    if (usePinned) return (_pinnedClientFactory(fingerprint), true);
    return (_httpClient, false);
  }

  Future<http.Response> _send(
    http.Client client,
    String token,
    String method,
    HostJobTarget target,
    String path, {
    Map<String, Object?>? jsonBody,
  }) async {
    final Uri? uri = _uri(target.baseUrl, path);
    if (uri == null) throw const HostJobRemoteException('http', 'bad host url');
    final http.Request req = http.Request(method, uri)..headers.addAll(_headers(token));
    if (jsonBody != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(jsonBody);
    }
    final http.Response response =
        await http.Response.fromStream(await client.send(req).timeout(_requestTimeout));
    if (response.statusCode >= 400) {
      throw HostJobRemoteException(
        'http_${response.statusCode}',
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    }
    return response;
  }

  Future<void> _upload(
    http.Client client,
    String token,
    HostJobTarget target,
    String path,
    File file,
  ) async {
    final Uri? uri = _uri(target.baseUrl, path);
    if (uri == null) throw const HostJobRemoteException('http', 'bad host url');
    final int length = await file.length();
    final http.StreamedRequest req = http.StreamedRequest('PUT', uri)
      ..headers.addAll(_headers(token))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = length;
    unawaited(file.openRead().pipe(req.sink));
    final http.StreamedResponse res = await client.send(req).timeout(_uploadTimeout);
    if (res.statusCode >= 400) {
      throw HostJobRemoteException('http_${res.statusCode}', await res.stream.bytesToString());
    }
    await res.stream.drain<void>();
  }

  Map<String, dynamic> _json(http.Response r) {
    final dynamic decoded = jsonDecode(utf8.decode(r.bodyBytes));
    if (decoded is! Map) throw const HostJobRemoteException('http', 'non-object body');
    return Map<String, dynamic>.from(decoded);
  }

  static Uri? _parse(String baseUrl) {
    try {
      return Uri.parse(WebDavOps.normalizeUrl(baseUrl));
    } catch (_) {
      return null;
    }
  }

  Uri? _uri(String baseUrl, String path) {
    final Uri? base = _parse(baseUrl);
    if (base == null) return null;
    return base.replace(path: path, queryParameters: const <String, String>{});
  }
}

/// `progress` 缺省时的退避（复用漫画 OCR 的），加个上限防 int 溢出。
Duration hostJobPollDelay(int attempt) =>
    Duration(milliseconds: min(mangaOcrPollDelay(attempt).inMilliseconds, 5000));
