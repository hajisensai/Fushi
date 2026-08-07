/// 漫画 P3：互联「已配对主机代跑 OCR」的客户端。
///
/// 手机端（无内置 OCR 能力）把整卷页图交给已配对桌面 host：能力探测
/// （`GET /api/capabilities` 的 `mangaOcr` 字段）→ 创建任务 → 有限并发逐页上传
/// → start → 轮询（间隔递增有上限）→ 取回 manga.json 写到本地
/// `<所选文件夹>/manga_ocr_out/manga.json`（图片本就在本地，不回传）。
///
/// 传输契约与 [FushiRemoteMiningClient] 同构：候选地址来自
/// [SyncRepository.getFushiClientUrls]、`Basic base64(hibiki:token)` 鉴权、
/// https 带指纹走钉扎 client。老 host 的 capabilities 无 `mangaOcr` 字段 →
/// [probe] 返回 null → UI 隐藏远程选项（版本 skew 零破坏）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/tls/fushi_pinning_http.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

/// 轮询退避：500ms 起步 ×1.5 递增，封顶 5s。纯函数便于单测单调性与上限。
Duration mangaOcrPollDelay(int attempt) {
  const int baseMs = 500;
  const int maxMs = 5000;
  final num scaled = baseMs * pow(1.5, attempt);
  return Duration(milliseconds: min(scaled.round(), maxMs));
}

/// host 能力协商结果（capabilities 响应的 `mangaOcr` 字段）。
class MangaOcrRemoteCapability {
  const MangaOcrRemoteCapability({
    required this.supported,
    required this.modelsReady,
  });

  final bool supported;

  /// 三态：`true` 已下载 / `false` 明确未下载 / `null` 对端没报这个字段。
  ///
  /// `null` 只可能来自「报了 `mangaOcr` 却不含 `modelsReady`」的对端。现网不存在
  /// 这种版本（两个字段是同一个 commit `de5103250` 一起进的协议），所以这一态纯属
  /// wire 卫生：**按「未知即可用」处理**，保持修复前的行为，由 start 阶段的
  /// `models_not_ready` 兜底。反过来把缺字段当 not ready，会让这类对端上本可用的
  /// 主机凭空消失——为一个不存在的版本付真实的功能倒退，不划算。
  final bool? modelsReady;

  /// 可选为 OCR 主机：支持，且没有**明确**报模型未下载。
  bool get usable => supported && modelsReady != false;

  /// 支持 OCR 但明确报了模型未下载——UI 据此置灰并说明原因，而不是隐藏。
  bool get modelsMissing => supported && modelsReady == false;

  /// 从 capabilities 响应 JSON 解析；老 host 无 `mangaOcr` 字段返回 null。
  static MangaOcrRemoteCapability? fromCapabilitiesJson(
    Map<String, dynamic> json,
  ) {
    final Object? raw = json['mangaOcr'];
    if (raw is! Map) return null;
    // 缺 `modelsReady` 与 `modelsReady: false` 必须可区分，所以先查键在不在，
    // 不能直接 `raw['modelsReady'] == true` 把两者压成同一个 false。
    final bool? modelsReady =
        raw.containsKey('modelsReady') ? raw['modelsReady'] == true : null;
    return MangaOcrRemoteCapability(
      supported: raw['supported'] == true,
      modelsReady: modelsReady,
    );
  }
}

/// 一台可代跑 OCR 的已配对主机（探测命中的候选地址 + 能力）。
class MangaOcrRemoteTarget {
  const MangaOcrRemoteTarget({
    required this.baseUrl,
    required this.capability,
    this.fingerprintSha256,
    this.deviceName,
  });

  final String baseUrl;
  final MangaOcrRemoteCapability capability;

  /// https 端点的证书指纹（TOFU 钉扎）；http 老路径为 null。
  final String? fingerprintSha256;
  final String? deviceName;
}

/// 远程 OCR 进度事件（与 [MangaOcrVolumeEvent] 同款「进度流 + finished 收尾」，
/// 多一个上传阶段）。取消订阅即请求中止（host 侧任务被 DELETE）。
class MangaOcrRemoteEvent {
  const MangaOcrRemoteEvent.uploading({required this.done, required this.total})
      : uploading = true,
        finished = false,
        mangaJsonPath = null;

  const MangaOcrRemoteEvent.running({required this.done, required this.total})
      : uploading = false,
        finished = false,
        mangaJsonPath = null;

  const MangaOcrRemoteEvent.finished({required String this.mangaJsonPath})
      : uploading = false,
        finished = true,
        done = 0,
        total = 0;

  /// true = 上传阶段进度；false = host 侧 OCR 阶段进度。
  final bool uploading;
  final bool finished;
  final int done;
  final int total;

  /// finished 事件携带写到本地的 manga.json 绝对路径。
  final String? mangaJsonPath;
}

/// 远程 OCR 失败：机器可读 [code]（UI 映射本地化文案）+ 可选人类可读 [detail]。
///
/// code 取值：`no_host`（无可用主机）/ `no_pages`（本地目录无页图）/
/// `models_not_ready`（host 模型未就绪）/ `not_supported`（host 不支持）/
/// `auth`（token 被拒）/ `remote_failed`（host 侧 OCR 失败）/
/// `cancelled`（host 侧任务被取消）/ `http`（网络/协议错误）。
class MangaOcrRemoteException implements Exception {
  const MangaOcrRemoteException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null || detail!.isEmpty
      ? 'MangaOcrRemoteException($code)'
      : 'MangaOcrRemoteException($code: $detail)';
}

/// 远程 OCR 执行器的窄接口（向导/导入入口依赖此接口，测试注 fake）。
abstract class MangaOcrRemoteRunner {
  /// 探测具备漫画 OCR 能力（`mangaOcr.supported == true`）的已配对主机。
  ///
  /// **优先返回模型就绪的主机**；一台都没就绪时才回退到「支持但模型未下载」的那台，
  /// 好让 UI 能置灰并说清原因（而不是等整卷传完才在 start 阶段报
  /// `models_not_ready`，TODO-2635）。无候选/无 token/全不支持返回 null
  /// （UI 据此隐藏远程选项）。
  Future<MangaOcrRemoteTarget?> probe();

  /// 对 [target] 跑整卷远程 OCR。事件序列：uploading* → running* →
  /// finished（携带写到本地的 manga.json 路径）。错误以
  /// [MangaOcrRemoteException] 收尾；取消订阅即中止并清理 host 侧任务。
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  });
}

/// 生产实现。
class InterconnectMangaOcrClient implements MangaOcrRemoteRunner {
  InterconnectMangaOcrClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
    int uploadConcurrency = 2,
    Duration Function(int attempt)? pollDelay,
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _pinnedClientFactory = pinnedClientFactory ?? _defaultPinnedClient,
        _probeTimeout = probeTimeout,
        _requestTimeout = requestTimeout,
        _uploadConcurrency = uploadConcurrency,
        _pollDelay = pollDelay ?? mangaOcrPollDelay;

  final SyncRepository _repo;
  final http.Client _httpClient;
  final http.Client Function(String expectedFingerprint) _pinnedClientFactory;
  final Duration _probeTimeout;
  final Duration _requestTimeout;
  final int _uploadConcurrency;
  final Duration Function(int attempt) _pollDelay;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  @override
  Future<MangaOcrRemoteTarget?> probe() async {
    final List<FushiClientUrl> candidates = (await _repo.getFushiClientUrls())
        .where((FushiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getFushiClientToken();
    if (candidates.isEmpty || token == null || token.isEmpty) return null;

    // 「支持但模型明确未下载」的第一台：所有候选都不可用时才拿它回填，让 UI 有
    // 具体原因可讲。一台可用的都不能被它挡住，所以只记不返。
    MangaOcrRemoteTarget? modelsMissingFallback;
    for (final FushiClientUrl candidate in candidates) {
      final Uri? uri = _uri(candidate.url, '/api/capabilities');
      if (uri == null) continue;
      final (http.Client client, bool closeAfter) =
          _clientFor(candidate.url, fingerprint: candidate.fingerprintSha256);
      try {
        final http.Response response = await client
            .get(uri, headers: _headers(token))
            .timeout(_probeTimeout);
        if (response.statusCode != 200) continue;
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) continue;
        final MangaOcrRemoteCapability? capability =
            MangaOcrRemoteCapability.fromCapabilitiesJson(
                Map<String, dynamic>.from(decoded));
        // 老 host（无字段）或明确不支持 → 换下一个候选。
        if (capability == null || !capability.supported) continue;
        final MangaOcrRemoteTarget target = MangaOcrRemoteTarget(
          baseUrl: candidate.url,
          capability: capability,
          fingerprintSha256: candidate.fingerprintSha256,
          deviceName: candidate.deviceName,
        );
        if (capability.usable) return target;
        modelsMissingFallback ??= target;
      } catch (_) {
        continue;
      } finally {
        if (closeAfter) client.close();
      }
    }
    return modelsMissingFallback;
  }

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) {
    final StreamController<MangaOcrRemoteEvent> controller =
        StreamController<MangaOcrRemoteEvent>();
    bool cancelled = false;
    String? jobId;
    http.Client? client;
    bool closeAfter = false;

    Future<void> cleanupRemote() async {
      final String? id = jobId;
      if (id == null) return;
      jobId = null;
      // 取消/收尾的 best-effort 清理：独立短命 client（run 的主 client 可能已关）。
      final (http.Client c, bool close) =
          _clientFor(target.baseUrl, fingerprint: target.fingerprintSha256);
      try {
        final String? token = await _repo.getFushiClientToken();
        if (token == null) return;
        final Uri? uri = _uri(target.baseUrl, '/api/ocr/job/$id');
        if (uri == null) return;
        await c.delete(uri, headers: _headers(token)).timeout(_requestTimeout);
      } catch (_) {
        // host 侧 TTL 清理兜底。
      } finally {
        if (close) c.close();
      }
    }

    controller.onListen = () {
      unawaited(() async {
        try {
          final String? token = await _repo.getFushiClientToken();
          if (token == null || token.isEmpty) {
            throw const MangaOcrRemoteException('no_host');
          }
          final List<MangaOcrPageFile> pages =
              enumerateMangaPages(Directory(imageDirPath));
          if (pages.isEmpty) {
            throw const MangaOcrRemoteException('no_pages');
          }
          final (http.Client c, bool close) =
              _clientFor(target.baseUrl, fingerprint: target.fingerprintSha256);
          client = c;
          closeAfter = close;

          // 1. 创建任务。
          final Map<String, dynamic> created = _expectJson(
            await _send(c, token, 'POST', target, '/api/ocr/job',
                jsonBody: <String, Object?>{
                  if (volumeTitle != null && volumeTitle.trim().isNotEmpty)
                    'volumeTitle': volumeTitle.trim(),
                  'pageCount': pages.length,
                }),
          );
          final String id = created['jobId']?.toString() ?? '';
          if (id.isEmpty) {
            throw const MangaOcrRemoteException('http', 'missing jobId');
          }
          jobId = id;
          if (cancelled) return;

          // 2. 有限并发逐页上传（进度回调）。
          int nextIndex = 0;
          int uploaded = 0;
          Future<void> worker() async {
            while (!cancelled) {
              final int i = nextIndex;
              if (i >= pages.length) return;
              nextIndex += 1;
              final MangaOcrPageFile page = pages[i];
              final List<int> bytes = await page.file.readAsBytes();
              _expectJson(await _send(
                c,
                token,
                'PUT',
                target,
                '/api/ocr/job/$id/page/$i',
                query: <String, String>{'name': page.relativeUrl},
                bodyBytes: bytes,
              ));
              uploaded += 1;
              if (!controller.isClosed && !cancelled) {
                controller.add(MangaOcrRemoteEvent.uploading(
                    done: uploaded, total: pages.length));
              }
            }
          }

          await Future.wait(<Future<void>>[
            for (int w = 0; w < max(1, _uploadConcurrency); w++) worker(),
          ]);
          if (cancelled) return;

          // 3. start（host 模型未就绪等在此转成可读错误码）。
          _expectJson(
              await _send(c, token, 'POST', target, '/api/ocr/job/$id/start'));
          if (cancelled) return;

          // 4. 轮询（间隔递增上限）。
          int attempt = 0;
          while (true) {
            await Future<void>.delayed(_pollDelay(attempt));
            attempt += 1;
            if (cancelled) return;
            final Map<String, dynamic> status = _expectJson(
                await _send(c, token, 'GET', target, '/api/ocr/job/$id'));
            if (cancelled) return;
            final String state = status['state']?.toString() ?? '';
            if (state == 'done') break;
            if (state == 'error') {
              throw MangaOcrRemoteException(
                  'remote_failed', status['error']?.toString());
            }
            if (state == 'cancelled') {
              throw const MangaOcrRemoteException('cancelled');
            }
            controller.add(MangaOcrRemoteEvent.running(
              done: (status['pagesDone'] as num?)?.toInt() ?? 0,
              total: (status['pagesTotal'] as num?)?.toInt() ?? pages.length,
            ));
          }

          // 5. 取回 manga.json，写到本地 <所选文件夹>/manga_ocr_out/manga.json。
          final http.Response result =
              await _send(c, token, 'GET', target, '/api/ocr/job/$id/result');
          final String json = utf8.decode(result.bodyBytes);
          final Directory outDir =
              Directory(p.join(imageDirPath, kMangaOcrOutDirName));
          await outDir.create(recursive: true);
          final File output =
              File(p.join(outDir.path, kMangaOcrOutputFileName));
          await output.writeAsString(json, flush: true);

          // 任务已完成：host 侧清掉（幂等；失败靠 TTL 兜底）。
          await cleanupRemote();
          if (!controller.isClosed && !cancelled) {
            controller
                .add(MangaOcrRemoteEvent.finished(mangaJsonPath: output.path));
          }
        } catch (e, stack) {
          if (!controller.isClosed && !cancelled) {
            controller.addError(e, stack);
          }
        } finally {
          if (closeAfter) client?.close();
          if (!controller.isClosed) {
            await controller.close();
          }
        }
      }());
    };
    controller.onCancel = () {
      cancelled = true;
      unawaited(cleanupRemote());
    };
    return controller.stream;
  }

  // ── HTTP 内部 ─────────────────────────────────────────────────

  Map<String, String> _headers(String token) => <String, String>{
        'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      };

  /// https + 指纹 → 新建钉扎 client（调用方负责 close）；否则复用共享明文 client。
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
    MangaOcrRemoteTarget target,
    String path, {
    Map<String, String>? query,
    List<int>? bodyBytes,
    Map<String, Object?>? jsonBody,
  }) async {
    final Uri? uri = _uri(target.baseUrl, path, query: query);
    if (uri == null) {
      throw const MangaOcrRemoteException('http', 'bad host url');
    }
    final http.Request request = http.Request(method, uri);
    request.headers.addAll(_headers(token));
    if (jsonBody != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(jsonBody);
    } else if (bodyBytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bodyBytes;
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
          await client.send(request).timeout(_requestTimeout));
    } on MangaOcrRemoteException {
      rethrow;
    } on TimeoutException {
      throw const MangaOcrRemoteException('http', 'request timed out');
    } catch (e) {
      throw MangaOcrRemoteException('http', '$e');
    }
    if (response.statusCode == 401) {
      throw const MangaOcrRemoteException('auth');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // host 返回机器可读 {error: <code>}：透传已知 code，其余归 http。
      String code = 'http';
      String? detail = 'HTTP ${response.statusCode}';
      try {
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map && decoded['error'] is String) {
          const Set<String> known = <String>{
            'models_not_ready',
            'not_supported',
            'unknown_job',
            'no_pages',
            'bad_state',
            'not_done',
          };
          final String raw = decoded['error'] as String;
          if (known.contains(raw)) {
            code = raw;
            detail = null;
          } else {
            detail = raw;
          }
        }
      } catch (_) {
        // 错误体解析失败就用默认错误码——本 catch 只服务于错误信息提取。
      }
      throw MangaOcrRemoteException(code, detail);
    }
    return response;
  }

  Map<String, dynamic> _expectJson(http.Response response) {
    try {
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 解析失败统一走下面的 invalid JSON 异常，无需区分原因。
    }
    throw const MangaOcrRemoteException('http', 'invalid JSON response');
  }

  Uri? _parse(String baseUrl) {
    try {
      return Uri.parse(WebDavOps.normalizeUrl(baseUrl));
    } catch (_) {
      return null;
    }
  }

  Uri? _uri(String baseUrl, String path, {Map<String, String>? query}) {
    final Uri? base = _parse(baseUrl);
    if (base == null) return null;
    return base.replace(
      path: path,
      queryParameters: query ?? const <String, String>{},
    );
  }
}
