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

import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart'
    show mangaOcrPollDelay;
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/host_jobs/file_content_hash_cache.dart';
import 'package:fushi_engine/sync/host_jobs/host_input_matcher.dart'
    show HostInputWanted;
import 'package:fushi_engine/sync/host_jobs/host_job.dart'
    show hostJobInputName, kHostInputChangedError, kHostInputMatchAlgorithm;
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

  /// host 本地复用的输入内容变了（见 [kHostInputChangedError]）：应改为整份上传重来。
  bool get isHostInputChanged =>
      code == 'remote_error' &&
      (detail?.startsWith(kHostInputChangedError) ?? false);

  @override
  String toString() => detail == null
      ? 'HostJobRemoteException($code)'
      : 'HostJobRemoteException($code: $detail)';
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
    FileContentHashCache? hashCache,
  }) : _repo = repo,
       _hashCache = hashCache,
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

  /// 本机输入的内容哈希（带持久缓存）；null = 不做「host 已有就不上传」。
  final FileContentHashCache? _hashCache;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 找到第一台支持 [kind] 的已配对 host。
  Future<HostJobTarget?> probe(String kind) async {
    final List<FushiClientUrl> candidates = await rankInterconnectCandidates(
      (await _repo.getFushiClientUrls())
          .where((FushiClientUrl u) => u.enabled)
          .toList(growable: false),
    );
    final String? fallbackToken = await _repo.getFushiClientToken();
    for (final FushiClientUrl candidate in candidates) {
      final HostJobTarget? target = await _capabilitiesOf(
        candidate,
        fallbackToken,
      );
      if (target != null && target.supports(kind)) return target;
    }
    return null;
  }

  /// 读**某一台** host 的任务能力：[baseUrl] 是互联当前连着的地址（P2P 时是本地
  /// 转发口，按持久地址认回那一条配对记录）。返回的 [HostJobTarget.kinds] 可能不含
  /// 调用方要的 kind（老 host）——由调用方区分「连不上」（null）与「版本不支持」。
  ///
  /// 「在这台 host 的视频上跑任务」必须打到放视频的那台：[probe] 挑的是第一台支持
  /// 该 kind 的 host，多台 host 时可能是另一台，那边根本没有这个视频 id。
  Future<HostJobTarget?> probeHost(String baseUrl) async {
    final String wanted = _normalized(interconnectPersistedUrl(baseUrl));
    final List<FushiClientUrl> matching = <FushiClientUrl>[
      for (final FushiClientUrl u in await _repo.getFushiClientUrls())
        if (u.enabled && _normalized(u.url) == wanted) u,
    ];
    final String? fallbackToken = await _repo.getFushiClientToken();
    for (final FushiClientUrl candidate in await rankInterconnectCandidates(
      matching,
    )) {
      final HostJobTarget? target = await _capabilitiesOf(
        candidate,
        fallbackToken,
      );
      if (target != null) return target;
    }
    return null;
  }

  static String _normalized(String url) {
    try {
      return WebDavOps.normalizeUrl(url);
    } catch (_) {
      return url.trim();
    }
  }

  /// `GET /api/capabilities` 的 `jobs` 段；连不上 / 不认识的应答返回 null。
  Future<HostJobTarget?> _capabilitiesOf(
    FushiClientUrl candidate,
    String? fallbackToken,
  ) async {
    final Uri? uri = _uri(candidate.url, '/api/capabilities');
    if (uri == null) return null;
    final String? token = interconnectTokenFor(candidate, fallbackToken);
    if (token == null) return null;
    final (http.Client client, bool closeAfter) = _clientFor(
      candidate.url,
      fingerprint: candidate.fingerprintSha256,
    );
    try {
      final http.Response response = await client
          .get(uri, headers: _headers(token))
          .timeout(_probeTimeout);
      if (response.statusCode != 200) return null;
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      final Object? jobs = decoded['jobs'];
      final List<String> kinds = jobs is Map
          ? (jobs['kinds'] as List?)?.map((Object? e) => '$e').toList() ??
                const <String>[]
          : const <String>[];
      return HostJobTarget(
        baseUrl: candidate.url,
        deviceName: candidate.deviceName,
        kinds: kinds,
        capability: jobs is Map
            ? Map<String, Object?>.from(jobs)
            : const <String, Object?>{},
        fingerprintSha256: candidate.fingerprintSha256,
      );
    } catch (_) {
      return null;
    } finally {
      if (closeAfter) client.close();
    }
  }

  /// 跑一个任务：上传 [inputs]（上传名见 [hostJobInputNamesFor]），轮询到终态，把
  /// 产物下载到 [outputDir]。取消订阅即远端 DELETE。
  ///
  /// host 宣告了 `jobs.inputMatch`、且本客户端有哈希缓存时，先发 [inputs] 的内容
  /// 哈希清单，host 本地已有**内容相同**文件的那几份不上传（[HostJobUploading] 把它们
  /// 算作已完成）。host 那份文件在任务途中被改 / 删时任务以
  /// [kHostInputChangedError] 失败，这里自动整份上传重跑一次。
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required String kind,
    required Map<String, Object?> params,
    required List<File> inputs,
    required Directory outputDir,
  }) {
    final StreamController<HostJobEvent> controller =
        StreamController<HostJobEvent>();
    bool cancelled = false;
    String? jobId;

    Future<void> cleanupRemote() async {
      final String? id = jobId;
      if (id == null) return;
      jobId = null;
      final (http.Client c, bool close) = _clientFor(
        target.baseUrl,
        fingerprint: target.fingerprintSha256,
      );
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

    /// 一次完整的 create → (match) → upload → start → poll → result。[reuseHostFiles]
    /// = 先发内容哈希清单，host 本地已有的那几份不上传。
    Future<Map<String, File>> attempt(
      http.Client c,
      String token, {
      required bool reuseHostFiles,
    }) async {
      final Map<String, dynamic> created = _json(
        await _send(
          c,
          token,
          'POST',
          target,
          '/api/jobs',
          jsonBody: <String, Object?>{'kind': kind, 'params': params},
        ),
      );
      final String id = created['jobId'].toString();
      jobId = id;
      final List<String> names = hostJobInputNamesFor(inputs);
      controller.add(HostJobUploading(0, inputs.length));
      final Set<String> onHost = reuseHostFiles
          ? await _matchHostInputs(c, token, target, id, inputs, names)
          : const <String>{};
      int done = onHost.length;
      if (done > 0) controller.add(HostJobUploading(done, inputs.length));
      for (int i = 0; i < inputs.length; i++) {
        if (cancelled) throw const HostJobRemoteException('cancelled');
        if (onHost.contains(names[i])) continue;
        await _upload(
          c,
          token,
          target,
          '/api/jobs/$id/input/${Uri.encodeComponent(names[i])}',
          inputs[i],
        );
        controller.add(HostJobUploading(++done, inputs.length));
      }
      if (cancelled) throw const HostJobRemoteException('cancelled');
      await _send(c, token, 'POST', target, '/api/jobs/$id/start');
      int pollAttempt = 0;
      while (true) {
        if (cancelled) throw const HostJobRemoteException('cancelled');
        await Future<void>.delayed(_pollDelay(pollAttempt++));
        final Map<String, dynamic> status = _json(
          await _send(c, token, 'GET', target, '/api/jobs/$id'),
        );
        final String state = status['state'].toString();
        final double progress = (status['progress'] as num?)?.toDouble() ?? 0;
        final String? message = status['message']?.toString();
        if (state == 'done') {
          final List<String> outputNames =
              (status['outputs'] as List?)?.map((Object? e) => '$e').toList() ??
              const <String>[];
          await outputDir.create(recursive: true);
          final Map<String, File> files = <String, File>{};
          for (final String name in outputNames) {
            final http.Response r = await _send(
              c,
              token,
              'GET',
              target,
              '/api/jobs/$id/result/${Uri.encodeComponent(name)}',
            );
            final File out = File(p.join(outputDir.path, p.basename(name)));
            await out.writeAsBytes(r.bodyBytes, flush: true);
            files[name] = out;
          }
          jobId = null;
          await _send(c, token, 'DELETE', target, '/api/jobs/$id');
          return files;
        }
        if (state == 'error') {
          throw HostJobRemoteException(
            'remote_error',
            status['error']?.toString(),
          );
        }
        if (state == 'cancelled') {
          throw const HostJobRemoteException('cancelled');
        }
        controller.add(HostJobRunning(progress, message));
      }
    }

    controller.onListen = () {
      unawaited(() async {
        final (http.Client c, bool close) = _clientFor(
          target.baseUrl,
          fingerprint: target.fingerprintSha256,
        );
        try {
          final String? token = await _tokenForBaseUrl(target.baseUrl);
          if (token == null || token.isEmpty) {
            throw const HostJobRemoteException('no_host');
          }
          bool reuse =
              _hashCache != null &&
              inputs.isNotEmpty &&
              target.capability['inputMatch'] == kHostInputMatchAlgorithm;
          while (true) {
            try {
              final Map<String, File> files = await attempt(
                c,
                token,
                reuseHostFiles: reuse,
              );
              controller.add(HostJobDone(files));
              await controller.close();
              return;
            } on HostJobRemoteException catch (e) {
              // host 上那份文件在排队 / 转录途中被改或删：这次产物作废，整份上传重来，
              // 不再复用 host 文件（不可能悄悄用错内容）。
              if (!reuse || !e.isHostInputChanged || cancelled) rethrow;
              await cleanupRemote();
              reuse = false;
            }
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

  /// 发内容哈希清单，返回 host 本地已有的输入名。host 不认这条路由（老版本）当作
  /// 一个都没有；本机文件正被写（哈希期间变了）的那份不参与匹配、照常上传。
  Future<Set<String>> _matchHostInputs(
    http.Client c,
    String token,
    HostJobTarget target,
    String id,
    List<File> inputs,
    List<String> names,
  ) async {
    final FileContentHashCache cache = _hashCache!;
    final List<Map<String, Object?>> files = <Map<String, Object?>>[];
    for (int i = 0; i < inputs.length; i++) {
      final FileContentFingerprint fp;
      try {
        fp = await cache.fingerprint(inputs[i].path);
      } on FileContentChangedWhileHashing {
        continue;
      }
      files.add(
        HostInputWanted(
          name: names[i],
          sha256: fp.sha256,
          size: fp.size,
        ).toJson(),
      );
    }
    if (files.isEmpty) return const <String>{};
    final http.Response response;
    try {
      response = await _send(
        c,
        token,
        'POST',
        target,
        '/api/jobs/$id/inputs/match',
        jsonBody: <String, Object?>{'files': files},
      );
    } on HostJobRemoteException catch (e) {
      if (e.code == 'http_404' || e.code == 'http_405') return const <String>{};
      rethrow;
    }
    final Object? matched = _json(response)['matched'];
    return <String>{
      if (matched is List)
        for (final Object? name in matched) '$name',
    };
  }

  // ── HTTP 助手（与漫画 OCR 客户端同款） ─────────────────────────────

  Future<String?> _tokenForBaseUrl(String baseUrl) async {
    final String? fallbackToken = await _repo.getFushiClientToken();
    final List<FushiClientUrl> urls = await _repo.getFushiClientUrls();
    for (final FushiClientUrl u in urls) {
      // 走 P2P 时 baseUrl 是本次的本地转发口，换回持久的 p2p:// 再认。
      if (u.url == interconnectPersistedUrl(baseUrl)) {
        return interconnectTokenFor(u, fallbackToken);
      }
    }
    return (fallbackToken != null && fallbackToken.isNotEmpty)
        ? fallbackToken
        : null;
  }

  Map<String, String> _headers(String token) => <String, String>{
    'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
  };

  (http.Client, bool) _clientFor(String baseUrl, {String? fingerprint}) {
    final Uri? base = _parse(baseUrl);
    final bool usePinned =
        base != null &&
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
    final http.Request req = http.Request(method, uri)
      ..headers.addAll(_headers(token));
    if (jsonBody != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(jsonBody);
    }
    final http.Response response = await http.Response.fromStream(
      await client.send(req).timeout(_requestTimeout),
    );
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
    final http.StreamedResponse res = await client
        .send(req)
        .timeout(_uploadTimeout);
    if (res.statusCode >= 400) {
      throw HostJobRemoteException(
        'http_${res.statusCode}',
        await res.stream.bytesToString(),
      );
    }
    await res.stream.drain<void>();
  }

  Map<String, dynamic> _json(http.Response r) {
    final dynamic decoded = jsonDecode(utf8.decode(r.bodyBytes));
    if (decoded is! Map) {
      throw const HostJobRemoteException('http', 'non-object body');
    }
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

/// [inputs] 在 host 上的输入名：`<定宽序号>_<文件名>`。序号保证同名文件（不同目录
/// 下的 `01.mp3`）不互相覆盖，且按名字排序 = 提交顺序（host 的 runner 按此顺序转）。
List<String> hostJobInputNamesFor(List<File> inputs) {
  final int width = max(3, '${inputs.length}'.length);
  return <String>[
    for (int i = 0; i < inputs.length; i++)
      '${'$i'.padLeft(width, '0')}_${hostJobInputName(p.basename(inputs[i].path))}',
  ];
}

/// `progress` 缺省时的退避（复用漫画 OCR 的），加个上限防 int 溢出。
Duration hostJobPollDelay(int attempt) => Duration(
  milliseconds: min(mangaOcrPollDelay(attempt).inMilliseconds, 5000),
);
