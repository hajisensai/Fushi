/// 互联「通用任务」客户端（`/api/jobs`，设计 §3.4）：在已配对 host 上跑 ASR 这类
/// 重活，上传输入 → 轮询 → 取回产物。
///
/// 与 `interconnect_manga_ocr_client.dart` 同一形状（探测能力位 → 选 host →
/// create/upload/start/poll/result → 取消即 DELETE）。传输一律走共享
/// [InterconnectHostChannel]（按 host 选路、per-peer 凭据、钉扎闸、整段超时、
/// client 生命周期）：每次 [InterconnectJobClient.probe] / [InterconnectJobClient.probeHost]
/// 与每次 [InterconnectJobClient.run] 各建自己的通道，用完即关，client 本身不持有
/// 任何 `http.Client`。
///
/// 一次 [InterconnectJobClient.run] 是显式的三阶段状态机：提交（create → match →
/// upload → start）、观测（轮询状态）、取回（下载产物）。host 上的任务状态是真相源：
/// 观测 / 取回中的**传输失败**（通道报 unreachable）只说明此刻看不到 host，进断连子
/// 状态继续观测（[RemoteJobLinkWatch]，容忍窗超了才判 `disconnected`）；每次观测都经
/// 通道重新选路，同一台 host 的任一条地址可达即算观测成功。host 判定的失败、协议错、
/// 证书不符 / 凭据被拒、用户取消才 DELETE；任务已不在 host（404）不再 DELETE；取回
/// 成功后的 DELETE 是尽力清理，失败不影响结果（host TTL 兜底）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/interconnect_remote_job_poll.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/host_jobs/file_content_hash_cache.dart';
import 'package:fushi_engine/sync/host_jobs/host_input_matcher.dart'
    show HostInputWanted;
import 'package:fushi_engine/sync/host_jobs/host_job.dart'
    show hostJobInputName, kHostInputChangedError, kHostInputMatchAlgorithm;
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
    this.host,
  });

  /// 这台 host 的持久地址（探测得到的 target 是组的锚地址，不是本次的 P2P 转发口）。
  final String baseUrl;
  final String? deviceName;
  final List<String> kinds;

  /// `/api/capabilities` 里的 `jobs` 原样（每种 kind 的就绪信息）。
  final Map<String, Object?> capability;
  final String? fingerprintSha256;

  /// 这台 host 的身份（探测得到的 target 都带）。null 时 [InterconnectJobClient.run]
  /// 按 [baseUrl] 在配对清单里认回那台 host。
  final InterconnectHostRef? host;

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
  const HostJobRunning(
    this.progress,
    this.message, {
    this.reconnecting = false,
  });
  final double progress;
  final String? message;

  /// 观测链路暂时断了、正在容忍窗内等 host 回来（进度停在最后看到的值）。
  final bool reconnecting;
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
    http.Client Function()? plainClientFactory,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
    Duration uploadTimeout = const Duration(minutes: 30),
    Duration Function(int attempt)? pollDelay,
    FileContentHashCache? hashCache,
    Duration linkLossTolerance = kRemoteJobLinkLossTolerance,
    DateTime Function()? now,
  }) : _repo = repo,
       _hashCache = hashCache,
       _plainClientFactory = plainClientFactory,
       _pinnedClientFactory = pinnedClientFactory,
       _probeTimeout = probeTimeout,
       _requestTimeout = requestTimeout,
       _uploadTimeout = uploadTimeout,
       _pollDelay = pollDelay ?? remoteJobPollDelay,
       _linkLossTolerance = linkLossTolerance,
       _now = now ?? DateTime.now;

  final SyncRepository _repo;

  /// 每次 probe / run 调一次，建出的明文 client 归那一次所有、用完即关。null →
  /// 通道自建（带建连超时）并在关闭时一并关掉。
  final http.Client Function()? _plainClientFactory;

  /// 透传给通道；建出的钉扎 client 归通道所有。null → 通道默认钉扎 client。
  final http.Client Function(String expectedFingerprint)? _pinnedClientFactory;
  final Duration _probeTimeout;
  final Duration _requestTimeout;
  final Duration _uploadTimeout;
  final Duration Function(int attempt) _pollDelay;
  final Duration _linkLossTolerance;
  final DateTime Function() _now;

  /// 本机输入的内容哈希（带持久缓存）；null = 不做「host 已有就不上传」。
  final FileContentHashCache? _hashCache;

  InterconnectHostChannel _channelFor(
    InterconnectHostRef host,
    http.Client? plain,
  ) => InterconnectHostChannel(
    repo: _repo,
    host: host,
    plainClient: plain,
    pinnedClientFactory: _pinnedClientFactory,
  );

  /// 找到第一台支持 [kind] 的已配对 host（按配对清单的组序逐台探测）。
  Future<HostJobTarget?> probe(String kind) async {
    final List<FushiClientUrl> rows = await _repo.getFushiClientUrls();
    final http.Client? plain = _plainClientFactory?.call();
    final List<InterconnectHostChannel> channels = <InterconnectHostChannel>[];
    try {
      for (final InterconnectHostRef host in interconnectPairedHostRefs(rows)) {
        final InterconnectHostChannel channel = _channelFor(host, plain);
        channels.add(channel);
        final HostJobTarget? target = await _capabilitiesOf(channel, rows);
        if (target != null && target.supports(kind)) return target;
      }
      return null;
    } finally {
      for (final InterconnectHostChannel channel in channels) {
        channel.close();
      }
      plain?.close();
    }
  }

  /// 读**某一台** host 的任务能力：[baseUrl] 是互联当前连着的地址（P2P 时是本地
  /// 转发口，按持久地址认回那台 host）。返回的 [HostJobTarget.kinds] 可能不含
  /// 调用方要的 kind（老 host）——由调用方区分「连不上」（null）与「版本不支持」。
  ///
  /// 「在这台 host 的视频上跑任务」必须打到放视频的那台：[probe] 挑的是第一台支持
  /// 该 kind 的 host，多台 host 时可能是另一台，那边根本没有这个视频 id。认的是
  /// 「那台 host」而不是那一条地址：由通道在组内选路。
  Future<HostJobTarget?> probeHost(String baseUrl) async {
    final List<FushiClientUrl> rows = await _repo.getFushiClientUrls();
    final InterconnectHostRef? host = _hostForUrl(rows, baseUrl);
    if (host == null) return null;
    final http.Client? plain = _plainClientFactory?.call();
    final InterconnectHostChannel channel = _channelFor(host, plain);
    try {
      return await _capabilitiesOf(channel, rows);
    } finally {
      channel.close();
      plain?.close();
    }
  }

  /// [url]（可能是本次的 P2P 转发口、可能带结尾斜杠）所属的那台已配对 host；不在
  /// 配对清单里 → null。
  static InterconnectHostRef? _hostForUrl(
    List<FushiClientUrl> rows,
    String url,
  ) {
    final String wanted = _normalized(interconnectPersistedUrl(url));
    for (final FushiClientUrl u in rows) {
      if (_normalized(u.url) == wanted) {
        return interconnectHostRefForUrl(rows, u.url);
      }
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

  /// `GET /api/capabilities` 的 `jobs` 段；连不上 / 不认识的应答返回 null。老 host
  /// （没有 `jobs`）返回 kinds 为空的 target。
  Future<HostJobTarget?> _capabilitiesOf(
    InterconnectHostChannel channel,
    List<FushiClientUrl> rows,
  ) async {
    final InterconnectHostRef host = channel.host;
    String? groupName;
    for (final FushiClientUrl u in rows) {
      final String? name = u.deviceName;
      if (host.matches(u) && name != null && name.isNotEmpty) {
        groupName = name;
        break;
      }
    }
    final InterconnectCapabilityOutcome<HostJobTarget> outcome =
        await probeInterconnectCapability<HostJobTarget>(
          channel,
          label: interconnectHostLabel(rows, host),
          timeout: _probeTimeout,
          parse: (Map<String, dynamic> caps, FushiClientUrl via) {
            final Object? jobs = caps['jobs'];
            final Object? rawKinds = jobs is Map ? jobs['kinds'] : null;
            return HostJobTarget(
              baseUrl: host.anchorUrl,
              deviceName: via.deviceName ?? groupName,
              kinds: rawKinds is List
                  ? <String>[for (final Object? e in rawKinds) '$e']
                  : const <String>[],
              capability: jobs is Map
                  ? Map<String, Object?>.from(jobs)
                  : const <String, Object?>{},
              fingerprintSha256: via.fingerprintSha256,
              host: host,
            );
          },
        );
    return outcome is InterconnectCapabilityAvailable<HostJobTarget>
        ? outcome.target
        : null;
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

    /// 本次 run 的通道与工厂建出的明文 client：主循环结束且全部清理落地后才关。
    InterconnectHostChannel? channel;
    http.Client? plain;

    /// 已发起的全部清理（含 onCancel 触发的）；主循环收尾时等它们落地再关通道。
    Future<void> cleanupDone = Future<void>.value();

    /// 尽力清理 host 上的任务（幂等：jobId 同步置空，重复调用返回同一批清理）。
    Future<void> cleanupRemote() {
      final String? id = jobId;
      final InterconnectHostChannel? c = channel;
      if (id == null || c == null) return cleanupDone;
      jobId = null;
      final Future<void> delete = () async {
        try {
          await _send(c, 'DELETE', '/api/jobs/$id', idempotent: true);
        } catch (e, stack) {
          // 尽力清理：失败不影响任务结论，遗留记录由 host 的 TTL 回收。
          engineLog.log('InterconnectJobClient.cleanupRemote', e, stack);
        }
      }();
      return cleanupDone = Future.wait(<Future<void>>[
        cleanupDone,
        delete,
      ]).then((_) {});
    }

    final RemoteJobLinkWatch watch = RemoteJobLinkWatch(
      tolerance: _linkLossTolerance,
      now: _now,
    );

    /// 提交阶段：create → (match) → upload → start，返回 host 上的任务 id。
    /// [reuseHostFiles] = 先发内容哈希清单，host 本地已有的那几份不上传。
    Future<String> submit(
      InterconnectHostChannel c, {
      required bool reuseHostFiles,
    }) async {
      final Map<String, dynamic> created = _json(
        await _send(
          c,
          'POST',
          '/api/jobs',
          jsonBody: <String, Object?>{'kind': kind, 'params': params},
        ),
      );
      final String id = created['jobId'].toString();
      jobId = id;
      final List<String> names = hostJobInputNamesFor(inputs);
      controller.add(HostJobUploading(0, inputs.length));
      final Set<String> onHost = reuseHostFiles
          ? await _matchHostInputs(
              c,
              id,
              inputs,
              names,
              isCancelled: () => cancelled,
            )
          : const <String>{};
      int done = onHost.length;
      if (done > 0) controller.add(HostJobUploading(done, inputs.length));
      for (int i = 0; i < inputs.length; i++) {
        if (cancelled) throw const HostJobRemoteException('cancelled');
        if (onHost.contains(names[i])) continue;
        await _upload(
          c,
          '/api/jobs/$id/input/${Uri.encodeComponent(names[i])}',
          inputs[i],
        );
        controller.add(HostJobUploading(++done, inputs.length));
      }
      if (cancelled) throw const HostJobRemoteException('cancelled');
      await _send(c, 'POST', '/api/jobs/$id/start');
      return id;
    }

    /// 观测 + 取回阶段。返回下载好的产物；任务仍留在 host 上（[jobId] 不清），
    /// 由调用方在交付结果之后尽力清理。
    Future<Map<String, File>> observeAndCollect(
      InterconnectHostChannel c,
      String id,
    ) async {
      double lastProgress = 0;
      String? lastMessage;
      bool announcedReconnect = false;

      /// 一次观测 / 取回交换。传输失败且仍在容忍窗内返回 null（调用方按退避再来），
      /// 超窗抛 `disconnected`；其余异常原样抛（由外层 DELETE + 报错）。
      Future<T?> exchange<T extends Object>(Future<T> Function() send) async {
        try {
          final T value = await send();
          watch.observed();
          announcedReconnect = false;
          return value;
        } catch (e) {
          if (!_isTransportFailure(e)) rethrow;
          if (!watch.lost()) {
            throw HostJobRemoteException(
              'disconnected',
              t.interconnect_remote_job_disconnected(
                minutes: '${_linkLossTolerance.inMinutes}',
              ),
            );
          }
          // 同一断连期只报一次「重连中」。
          if (!announcedReconnect) {
            announcedReconnect = true;
            controller.add(
              HostJobRunning(lastProgress, lastMessage, reconnecting: true),
            );
          }
          return null;
        }
      }

      List<String>? outputNames;
      final Map<String, File> files = <String, File>{};
      int pollAttempt = 0;
      while (true) {
        if (cancelled) throw const HostJobRemoteException('cancelled');
        await Future<void>.delayed(_pollDelay(pollAttempt++));
        if (outputNames == null) {
          final Map<String, dynamic>? status;
          try {
            status = await exchange(
              () async => _json(await _send(c, 'GET', '/api/jobs/$id')),
            );
          } on HostJobRemoteException catch (e) {
            if (e.code != 'http_404') rethrow;
            // 任务已不在 host（被删 / host 重启后丢了）：没有可清理的，不再 DELETE。
            jobId = null;
            throw HostJobRemoteException(
              'job_lost',
              t.interconnect_remote_job_lost,
            );
          }
          if (status == null) continue;
          final String state = status['state'].toString();
          if (state == 'error') {
            throw HostJobRemoteException(
              'remote_error',
              status['error']?.toString(),
            );
          }
          if (state == 'cancelled') {
            throw const HostJobRemoteException('cancelled');
          }
          if (state != 'done') {
            lastProgress = (status['progress'] as num?)?.toDouble() ?? 0;
            lastMessage = status['message']?.toString();
            controller.add(HostJobRunning(lastProgress, lastMessage));
            continue;
          }
          outputNames =
              (status['outputs'] as List?)?.map((Object? e) => '$e').toList() ??
              const <String>[];
          await outputDir.create(recursive: true);
        }
        // 取回：已下载的保留，断连恢复后从还没拿到的那一份接着下。
        bool interrupted = false;
        for (final String name in outputNames) {
          if (files.containsKey(name)) continue;
          if (cancelled) throw const HostJobRemoteException('cancelled');
          final InterconnectChannelResponse? r = await exchange(
            () => _send(
              c,
              'GET',
              '/api/jobs/$id/result/${Uri.encodeComponent(name)}',
            ),
          );
          if (r == null) {
            interrupted = true;
            break;
          }
          final File out = File(p.join(outputDir.path, p.basename(name)));
          await out.writeAsBytes(r.bodyBytes, flush: true);
          files[name] = out;
        }
        if (!interrupted) return files;
      }
    }

    controller.onListen = () {
      unawaited(() async {
        try {
          final InterconnectHostRef? host =
              target.host ??
              _hostForUrl(await _repo.getFushiClientUrls(), target.baseUrl);
          if (host == null) throw const HostJobRemoteException('no_host');
          plain = _plainClientFactory?.call();
          final InterconnectHostChannel c = channel = _channelFor(host, plain);
          bool reuse =
              _hashCache != null &&
              inputs.isNotEmpty &&
              target.capability['inputMatch'] == kHostInputMatchAlgorithm;
          while (true) {
            try {
              final String id = await submit(c, reuseHostFiles: reuse);
              final Map<String, File> files = await observeAndCollect(c, id);
              controller.add(HostJobDone(files));
              await controller.close();
              // 结果已交付；清理失败只记日志、不改结论（host TTL 兜底）。
              await cleanupRemote();
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
          // 通道归本次 run：等全部清理（含 onCancel 发起的 DELETE）落地后再关，
          // 不让关通道把在途的清理请求一并掐掉。
          await cleanupDone;
          channel?.close();
          plain?.close();
        }
      }());
    };
    controller.onCancel = () {
      cancelled = true;
      unawaited(cleanupRemote());
    };
    return controller.stream;
  }

  /// 发内容哈希清单，返回 host 本地已有的输入名。本机文件正被写（哈希期间变了）
  /// 的那份不参与匹配、照常上传。
  ///
  /// 匹配是**可选优化**：host 不认这条路由（老版本）、应答出错、超时、连接断了，
  /// 一律当「一个都没有」照旧全部上传，绝不让整个任务因此失败。host 报
  /// `pending`（还在后台给冷文件算哈希）时按轮询节奏再问，直到它给出终局答复。
  Future<Set<String>> _matchHostInputs(
    InterconnectHostChannel c,
    String id,
    List<File> inputs,
    List<String> names, {
    required bool Function() isCancelled,
  }) async {
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
    int attempt = 0;
    while (true) {
      if (isCancelled()) throw const HostJobRemoteException('cancelled');
      final Map<String, dynamic> body;
      try {
        body = _json(
          await _send(
            c,
            'POST',
            '/api/jobs/$id/inputs/match',
            jsonBody: <String, Object?>{'files': files},
          ),
        );
      } on Object catch (e, stack) {
        if (!_isOptionalStepFailure(e)) rethrow;
        // 老 host（404/405）是常态，不记日志；其余是真故障，记下再退回上传。
        if (e is! HostJobRemoteException ||
            (e.code != 'http_404' && e.code != 'http_405')) {
          engineLog.log('InterconnectJobClient.matchHostInputs', e, stack);
        }
        return const <String>{};
      }
      final Object? matched = body['matched'];
      final Set<String> onHost = <String>{
        if (matched is List)
          for (final Object? name in matched) '$name',
      };
      if (body['pending'] != true) return onHost;
      await Future<void>.delayed(_pollDelay(attempt++));
    }
  }

  /// 可选步骤（输入匹配）里「问不到答案」的失败：host 应答错误 / 应答不是 JSON
  /// 对象（[HostJobRemoteException]）、通道判不可达（超时、网络断开）。这些都只
  /// 意味着这次没法复用 host 文件。
  static bool _isOptionalStepFailure(Object e) =>
      e is HostJobRemoteException ||
      (e is InterconnectChannelException &&
          e.kind == InterconnectChannelFailure.unreachable);

  /// 传输层失败：对端此刻看不到，不代表任务失败。通道的 unreachable（这台 host 的
  /// 每条地址都没给出 HTTP 回答，含整段超时），或网关 502/503/504。证书不符、凭据
  /// 被拒、未配对不算（换地址、等下去都不会好）。
  static bool _isTransportFailure(Object e) =>
      (e is InterconnectChannelException &&
          e.kind == InterconnectChannelFailure.unreachable) ||
      (e is HostJobRemoteException &&
          (e.code == 'http_502' ||
              e.code == 'http_503' ||
              e.code == 'http_504'));

  // ── 交换（传输走 [InterconnectHostChannel]；退避与断连判定与漫画 OCR 客户端
  // 共用 `interconnect_remote_job_poll.dart`） ─────────────────────────────

  /// 通道失败 → 本 client 的错误形状。unreachable 原样抛：它是传输失败，观测 /
  /// 取回阶段据此进断连子状态（[_isTransportFailure]）。
  static Exception _channelFailure(InterconnectChannelException e) =>
      switch (e.kind) {
        InterconnectChannelFailure.unreachable => e,
        InterconnectChannelFailure.authRejected => const HostJobRemoteException(
          'auth_rejected',
        ),
        InterconnectChannelFailure.certificateMismatch =>
          const HostJobRemoteException('certificate_mismatch'),
        InterconnectChannelFailure.notPaired => const HostJobRemoteException(
          'no_host',
        ),
        InterconnectChannelFailure.cancelled => const HostJobRemoteException(
          'cancelled',
        ),
      };

  /// 一次 JSON / 无体交换；超时覆盖整段（含响应体），由通道保证。[idempotent]
  /// 缺省按 method（GET 幂等）；create / start 的 POST 非幂等，写出后不换地址重发。
  Future<InterconnectChannelResponse> _send(
    InterconnectHostChannel channel,
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    bool? idempotent,
  }) async {
    final InterconnectChannelResponse response;
    try {
      response = await channel.send(
        method,
        path,
        body: jsonBody == null ? null : InterconnectRequestBody.json(jsonBody),
        timeout: _requestTimeout,
        idempotent: idempotent,
      );
    } on InterconnectChannelException catch (e) {
      throw _channelFailure(e);
    }
    if (response.statusCode >= 400) {
      throw HostJobRemoteException(
        'http_${response.statusCode}',
        response.text,
      );
    }
    return response;
  }

  /// 流式上传一份输入：流在请求体真正写出时才打开，打开后通道不再换地址重放。
  Future<void> _upload(
    InterconnectHostChannel channel,
    String path,
    File file,
  ) async {
    final int length = await file.length();
    final InterconnectChannelResponse response;
    try {
      response = await channel.send(
        'PUT',
        path,
        body: InterconnectRequestBody.stream(
          () => file.openRead(),
          contentLength: length,
        ),
        timeout: _uploadTimeout,
        idempotent: true,
      );
    } on InterconnectChannelException catch (e) {
      throw _channelFailure(e);
    }
    if (response.statusCode >= 400) {
      throw HostJobRemoteException(
        'http_${response.statusCode}',
        response.text,
      );
    }
  }

  Map<String, dynamic> _json(InterconnectChannelResponse r) {
    final Map<String, dynamic>? decoded = r.jsonObject;
    if (decoded == null) {
      throw const HostJobRemoteException('http', 'non-object body');
    }
    return decoded;
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
