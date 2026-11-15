/// 漫画 P3：互联「已配对主机代跑 OCR」的客户端。
///
/// 手机端（无内置 OCR 能力）把整卷页图交给已配对桌面 host：能力探测
/// （`GET /api/capabilities` 的 `mangaOcr` 字段）→ 创建任务 → 有限并发逐页上传
/// → start → 轮询（间隔递增有上限）→ 取回 manga.json 写到本地
/// `<所选文件夹>/manga_ocr_out/manga.json`（图片本就在本地，不回传）。
///
/// 传输一律走共享 [InterconnectHostChannel]（按 host 选路、per-peer 凭据、钉扎闸、
/// 整段超时、client 生命周期）：每次 [InterconnectMangaOcrClient.probe] 与每次
/// [InterconnectMangaOcrClient.run] 各建自己的通道，用完即关，client 本身不持有任何
/// `http.Client`。老 host 的 capabilities 无 `mangaOcr` 字段 → [probe] 返回 null →
/// UI 隐藏远程选项（版本 skew 零破坏）。
///
/// 一次 [InterconnectMangaOcrClient.run] 与通用任务 client 同一张状态机：提交
/// （create → 上传 → start）任何失败都清理 host 任务；观测 / 取回中的**传输失败**
/// （[MangaOcrRemoteException.transport]，即通道报 unreachable 或网关 502/503/504）
/// 只说明此刻看不到 host，进断连子状态继续观测（[RemoteJobLinkWatch]，容忍窗超了才
/// 判断连；每次观测都经通道重新选路）；host 判定的失败、协议错、用户取消才 DELETE；
/// 任务已不在 host（`unknown_job`）不再 DELETE；取回成功后先交付结果再尽力清理。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show
        MangaOcrPageFile,
        enumerateMangaPages,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName;
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_remote_job_poll.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 轮询退避：与通用远端任务共用 [remoteJobPollDelay]（500ms 起 ×1.5，封顶 5s）。
Duration mangaOcrPollDelay(int attempt) => remoteJobPollDelay(attempt);

/// host 上一个可点名的 OCR 模型（capabilities `mangaOcr.models` 的一项）。
class MangaOcrRemoteModel {
  const MangaOcrRemoteModel({required this.key, required this.ready});

  /// `MangaOcrLocalModel.key`。
  final String key;
  final bool ready;
}

/// host 能力协商结果（capabilities 响应的 `mangaOcr` 字段）。
class MangaOcrRemoteCapability {
  const MangaOcrRemoteCapability({
    required this.supported,
    required this.modelsReady,
    this.models = const <MangaOcrRemoteModel>[],
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

  /// host 允许对端点名的模型；老 host 不报 = 空（只能用 host 自己的选择）。
  final List<MangaOcrRemoteModel> models;

  /// 点名 [model] 时的能力：就绪态换成该模型自己的。host 报了模型表却没有这个
  /// 模型（对端版本不同）按「明确未就绪」处理——UI 置灰说明原因，而不是悄悄换成
  /// host 默认模型跑出另一套结果。老 host 不报模型表：它也不认 `model` 字段，
  /// 保持原样。
  MangaOcrRemoteCapability forModel(String? model) {
    if (model == null || models.isEmpty) return this;
    bool ready = false;
    for (final MangaOcrRemoteModel m in models) {
      if (m.key == model) ready = m.ready;
    }
    return MangaOcrRemoteCapability(
      supported: supported,
      modelsReady: ready,
      models: models,
    );
  }

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
    final bool? modelsReady = raw.containsKey('modelsReady')
        ? raw['modelsReady'] == true
        : null;
    final List<MangaOcrRemoteModel> models = <MangaOcrRemoteModel>[
      if (raw['models'] is List)
        for (final Object? item in raw['models'] as List)
          if (item is Map && item['key'] is String)
            MangaOcrRemoteModel(
              key: item['key'] as String,
              ready: item['ready'] == true,
            ),
    ];
    return MangaOcrRemoteCapability(
      supported: raw['supported'] == true,
      modelsReady: modelsReady,
      models: models,
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
    this.model,
    this.host,
  });

  /// 这台 host 的持久地址（探测得到的 target 是组的锚地址，不是本次的 P2P 转发口）。
  final String baseUrl;

  /// 这台 host 的身份（探测得到的 target 都带）。null 时
  /// [InterconnectMangaOcrClient.run] 按 [baseUrl] 在配对清单里认回那台 host。
  final InterconnectHostRef? host;

  /// 已按 [model] 换算过的能力（见 [MangaOcrRemoteCapability.forModel]）。
  final MangaOcrRemoteCapability capability;

  /// 点名 host 跑的模型；null = 用 host 自己当前的选择。只在 host 报了模型表时
  /// 才会非 null（老 host 不认这个字段）。
  final String? model;

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
      reconnecting = false,
      mangaJsonPath = null;

  const MangaOcrRemoteEvent.running({
    required this.done,
    required this.total,
    this.reconnecting = false,
  }) : uploading = false,
       finished = false,
       mangaJsonPath = null;

  const MangaOcrRemoteEvent.finished({required String this.mangaJsonPath})
    : uploading = false,
      finished = true,
      reconnecting = false,
      done = 0,
      total = 0;

  /// true = 上传阶段进度；false = host 侧 OCR 阶段进度。
  final bool uploading;
  final bool finished;

  /// 观测链路暂时断了、正在容忍窗内等 host 回来（进度停在最后看到的值）。
  final bool reconnecting;
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
/// `cancelled`（host 侧任务被取消）/ `http`（网络/协议错误）/
/// `unknown_job`（任务已不在 host）。
class MangaOcrRemoteException implements Exception {
  const MangaOcrRemoteException(this.code, [this.detail]) : transport = false;

  /// 传输层失败（超时、断连、网关 502/503/504）：此刻看不到 host，不代表任务失败。
  const MangaOcrRemoteException.transport(this.code, [this.detail])
    : transport = true;

  final String code;
  final String? detail;

  /// true = 观测失败（传输层），观测 / 取回阶段据此进断连子状态而不是判任务失败。
  final bool transport;

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
    http.Client Function()? plainClientFactory,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
    int uploadConcurrency = 2,
    Duration Function(int attempt)? pollDelay,
    String? Function()? preferredModel,
    Duration linkLossTolerance = kRemoteJobLinkLossTolerance,
    DateTime Function()? now,
  }) : _repo = repo,
       _preferredModel = preferredModel,
       _plainClientFactory = plainClientFactory,
       _pinnedClientFactory = pinnedClientFactory,
       _probeTimeout = probeTimeout,
       _requestTimeout = requestTimeout,
       _uploadConcurrency = uploadConcurrency,
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
  final int _uploadConcurrency;
  final Duration Function(int attempt) _pollDelay;
  final Duration _linkLossTolerance;
  final DateTime Function() _now;

  /// 用户在引擎下拉里点名的服务端模型（null / 空 = 服务端默认）。每次 probe 现读。
  final String? Function()? _preferredModel;

  InterconnectHostChannel _channelFor(
    InterconnectHostRef host,
    http.Client? plain,
  ) => InterconnectHostChannel(
    repo: _repo,
    host: host,
    plainClient: plain,
    pinnedClientFactory: _pinnedClientFactory,
  );

  @override
  Future<MangaOcrRemoteTarget?> probe() async {
    final List<FushiClientUrl> rows = await _repo.getFushiClientUrls();
    final List<InterconnectHostRef> hosts = interconnectPairedHostRefs(rows);
    if (hosts.isEmpty) return null;
    final String? preferred = _preferredModel?.call();
    final String? preferredModel = preferred == null || preferred.isEmpty
        ? null
        : preferred;

    final http.Client? plain = _plainClientFactory?.call();
    final List<InterconnectHostChannel> channels = <InterconnectHostChannel>[];
    try {
      // 「支持但模型明确未下载」的第一台：所有 host 都不可用时才拿它回填，让 UI 有
      // 具体原因可讲。一台可用的都不能被它挡住，所以只记不返。
      MangaOcrRemoteTarget? modelsMissingFallback;
      for (final InterconnectHostRef host in hosts) {
        final InterconnectHostChannel channel = _channelFor(host, plain);
        channels.add(channel);
        final InterconnectCapabilityOutcome<MangaOcrRemoteTarget> outcome =
            await probeInterconnectCapability<MangaOcrRemoteTarget>(
              channel,
              label: interconnectHostLabel(rows, host),
              timeout: _probeTimeout,
              parse: (Map<String, dynamic> caps, FushiClientUrl via) {
                final MangaOcrRemoteCapability? hostCapability =
                    MangaOcrRemoteCapability.fromCapabilitiesJson(caps);
                // 老 host（无字段）或明确不支持 → 换下一台。
                if (hostCapability == null || !hostCapability.supported) {
                  return null;
                }
                return MangaOcrRemoteTarget(
                  baseUrl: host.anchorUrl,
                  capability: hostCapability.forModel(preferredModel),
                  fingerprintSha256: via.fingerprintSha256,
                  deviceName: via.deviceName,
                  model: hostCapability.models.isEmpty ? null : preferredModel,
                  host: host,
                );
              },
            );
        if (outcome is! InterconnectCapabilityAvailable<MangaOcrRemoteTarget>) {
          continue;
        }
        final MangaOcrRemoteTarget target = outcome.target;
        if (target.capability.usable) return target;
        modelsMissingFallback ??= target;
      }
      return modelsMissingFallback;
    } finally {
      for (final InterconnectHostChannel channel in channels) {
        channel.close();
      }
      plain?.close();
    }
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
          await _send(c, 'DELETE', '/api/ocr/job/$id', idempotent: true);
        } catch (_) {
          // host 侧 TTL 清理兜底。
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

    /// 用户取消后的收尾：create 在途时 [controller.onCancel] 拿不到 jobId，
    /// 所以每个取消检查点都要自己补一次（[cleanupRemote] 幂等）。
    Future<bool> stopIfCancelled() async {
      if (!cancelled) return false;
      await cleanupRemote();
      return true;
    }

    /// 提交阶段：create → 有限并发上传 → start。返回 host 任务 id；用户取消返回 null。
    Future<String?> submit(
      InterconnectHostChannel c,
      List<MangaOcrPageFile> pages,
    ) async {
      final Map<String, dynamic> created = _expectJson(
        await _send(
          c,
          'POST',
          '/api/ocr/job',
          jsonBody: <String, Object?>{
            if (volumeTitle != null && volumeTitle.trim().isNotEmpty)
              'volumeTitle': volumeTitle.trim(),
            'pageCount': pages.length,
            if (target.model != null) 'model': target.model,
          },
        ),
      );
      final String id = created['jobId']?.toString() ?? '';
      if (id.isEmpty) {
        throw const MangaOcrRemoteException('http', 'missing jobId');
      }
      jobId = id;
      if (await stopIfCancelled()) return null;

      int nextIndex = 0;
      int uploaded = 0;
      Future<void> worker() async {
        while (!cancelled) {
          final int i = nextIndex;
          if (i >= pages.length) return;
          nextIndex += 1;
          final MangaOcrPageFile page = pages[i];
          final Uint8List bytes = await page.file.readAsBytes();
          _expectJson(
            await _send(
              c,
              'PUT',
              '/api/ocr/job/$id/page/$i',
              query: <String, String>{'name': page.relativeUrl},
              bytes: bytes,
              // 整页字节可重放：写出后断开也可以换同一台 host 的另一条地址重传。
              idempotent: true,
            ),
          );
          uploaded += 1;
          if (!controller.isClosed && !cancelled) {
            controller.add(
              MangaOcrRemoteEvent.uploading(
                done: uploaded,
                total: pages.length,
              ),
            );
          }
        }
      }

      await Future.wait(<Future<void>>[
        for (int w = 0; w < max(1, _uploadConcurrency); w++) worker(),
      ]);
      if (await stopIfCancelled()) return null;

      // start（host 模型未就绪等在此转成可读错误码）。
      _expectJson(await _send(c, 'POST', '/api/ocr/job/$id/start'));
      if (await stopIfCancelled()) return null;
      return id;
    }

    /// 观测 + 取回阶段：轮询到 done 后取回 manga.json 写到本地，返回该文件；
    /// 用户取消返回 null。任务仍留在 host（[jobId] 不清），由调用方交付后尽力清理。
    Future<File?> observeAndCollect(
      InterconnectHostChannel c,
      String id,
      int pageCount,
    ) async {
      int lastDone = 0;
      int lastTotal = pageCount;
      bool announcedReconnect = false;

      /// 一次观测 / 取回交换。传输失败且仍在容忍窗内返回 null（按退避再来），
      /// 超窗抛断连；其余异常原样抛（由外层清理 + 报错）。
      Future<T?> exchange<T extends Object>(Future<T> Function() send) async {
        try {
          final T value = await send();
          watch.observed();
          announcedReconnect = false;
          return value;
        } on MangaOcrRemoteException catch (e) {
          if (!e.transport) rethrow;
          if (!watch.lost()) {
            throw MangaOcrRemoteException.transport(
              'http',
              t.interconnect_remote_job_disconnected(
                minutes: '${_linkLossTolerance.inMinutes}',
              ),
            );
          }
          // 同一断连期只报一次「重连中」。
          if (!announcedReconnect && !controller.isClosed && !cancelled) {
            announcedReconnect = true;
            controller.add(
              MangaOcrRemoteEvent.running(
                done: lastDone,
                total: lastTotal,
                reconnecting: true,
              ),
            );
          }
          return null;
        }
      }

      bool hostDone = false;
      int attempt = 0;
      while (true) {
        await Future<void>.delayed(_pollDelay(attempt));
        attempt += 1;
        if (await stopIfCancelled()) return null;
        if (!hostDone) {
          final Map<String, dynamic>? status;
          try {
            status = await exchange(
              () async =>
                  _expectJson(await _send(c, 'GET', '/api/ocr/job/$id')),
            );
          } on MangaOcrRemoteException catch (e) {
            if (e.code != 'unknown_job') rethrow;
            // 任务已不在 host（被删 / host 重启后丢了）：没有可清理的，不再 DELETE。
            jobId = null;
            rethrow;
          }
          if (await stopIfCancelled()) return null;
          if (status == null) continue;
          final String state = status['state']?.toString() ?? '';
          if (state == 'error') {
            throw MangaOcrRemoteException(
              'remote_failed',
              status['error']?.toString(),
            );
          }
          if (state == 'cancelled') {
            throw const MangaOcrRemoteException('cancelled');
          }
          if (state != 'done') {
            lastDone = (status['pagesDone'] as num?)?.toInt() ?? 0;
            lastTotal = (status['pagesTotal'] as num?)?.toInt() ?? pageCount;
            controller.add(
              MangaOcrRemoteEvent.running(done: lastDone, total: lastTotal),
            );
            continue;
          }
          hostDone = true;
        }

        // 取回 manga.json，写到本地 <所选文件夹>/manga_ocr_out/manga.json。
        final InterconnectChannelResponse? result = await exchange(
          () => _send(c, 'GET', '/api/ocr/job/$id/result'),
        );
        if (await stopIfCancelled()) return null;
        if (result == null) continue;
        final String json = utf8.decode(result.bodyBytes);
        final Directory outDir = Directory(
          p.join(imageDirPath, kMangaOcrOutDirName),
        );
        await outDir.create(recursive: true);
        final File output = File(p.join(outDir.path, kMangaOcrOutputFileName));
        await output.writeAsString(json, flush: true);
        return output;
      }
    }

    controller.onListen = () {
      unawaited(() async {
        try {
          final InterconnectHostRef? host =
              target.host ??
              interconnectHostRefForUrl(
                await _repo.getFushiClientUrls(),
                target.baseUrl,
              );
          if (host == null) throw const MangaOcrRemoteException('no_host');
          final List<MangaOcrPageFile> pages = enumerateMangaPages(
            Directory(imageDirPath),
          );
          if (pages.isEmpty) {
            throw const MangaOcrRemoteException('no_pages');
          }
          plain = _plainClientFactory?.call();
          final InterconnectHostChannel c = channel = _channelFor(host, plain);

          final String? id = await submit(c, pages);
          if (id == null) return;
          final File? output = await observeAndCollect(c, id, pages.length);
          if (output == null) return;
          if (!controller.isClosed && !cancelled) {
            controller.add(
              MangaOcrRemoteEvent.finished(mangaJsonPath: output.path),
            );
            await controller.close();
          }
          // 结果已交付；host 侧清理是尽力而为（幂等，失败靠 host TTL 兜底）。
          await cleanupRemote();
        } catch (e, stack) {
          // 提交阶段任何失败、host 判定的失败、协议错、断连超窗：先报错，再尽力清理
          // host 任务（任务已不在 host 时 jobId 已清，这里是空操作）。
          if (!controller.isClosed && !cancelled) {
            controller.addError(e, stack);
          }
          await cleanupRemote();
        } finally {
          // 通道归本次 run：等全部清理（含 onCancel 发起的 DELETE）落地后再关，
          // 不让关通道把在途的清理请求一并掐掉。
          await cleanupDone;
          channel?.close();
          plain?.close();
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

  // ── 交换（传输走 [InterconnectHostChannel]） ─────────────────────────

  /// 通道失败 → 本 client 的错误形状（对外 code 语义不变）。unreachable 是传输
  /// 失败（观测 / 取回阶段据此进断连子状态）；证书不符、凭据被拒、未配对不是。
  static MangaOcrRemoteException _channelFailure(
    InterconnectChannelException e,
  ) => switch (e.kind) {
    InterconnectChannelFailure.unreachable => MangaOcrRemoteException.transport(
      'http',
      '$e',
    ),
    InterconnectChannelFailure.authRejected => const MangaOcrRemoteException(
      'auth',
    ),
    InterconnectChannelFailure.certificateMismatch =>
      const MangaOcrRemoteException('http', 'certificate mismatch'),
    InterconnectChannelFailure.notPaired => const MangaOcrRemoteException(
      'no_host',
    ),
    InterconnectChannelFailure.cancelled => const MangaOcrRemoteException(
      'cancelled',
    ),
  };

  /// 一次交换；超时覆盖整段（含响应体），由通道保证。[idempotent] 缺省按 method
  /// （GET 幂等）；create / start 的 POST 非幂等，写出后不换地址重发。
  Future<InterconnectChannelResponse> _send(
    InterconnectHostChannel channel,
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Uint8List? bytes,
    Map<String, Object?>? jsonBody,
    bool? idempotent,
  }) async {
    final InterconnectChannelResponse response;
    try {
      response = await channel.send(
        method,
        path,
        query: query,
        body: jsonBody != null
            ? InterconnectRequestBody.json(jsonBody)
            : bytes != null
            ? InterconnectRequestBody.bytes(bytes)
            : null,
        timeout: _requestTimeout,
        idempotent: idempotent,
      );
    } on InterconnectChannelException catch (e) {
      throw _channelFailure(e);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // host 返回机器可读 {error: <code>}：透传已知 code，其余归 http。
      String code = 'http';
      String? detail = 'HTTP ${response.statusCode}';
      final Object? error = response.jsonObject?['error'];
      if (error is String) {
        const Set<String> known = <String>{
          'models_not_ready',
          'not_supported',
          'unknown_job',
          'no_pages',
          'bad_state',
          'not_done',
          'unknown_model',
        };
        if (known.contains(error)) {
          code = error;
          detail = null;
        } else {
          detail = error;
        }
      }
      // 网关 / 反代的 502/503/504（非 host 的机器可读码）：此刻到不了 host，按传输失败。
      // 503 带 `models_not_ready` 等已知码时 code 已换成该码，不算传输失败。
      if (code == 'http' &&
          (response.statusCode == 502 ||
              response.statusCode == 503 ||
              response.statusCode == 504)) {
        throw MangaOcrRemoteException.transport(code, detail);
      }
      throw MangaOcrRemoteException(code, detail);
    }
    return response;
  }

  Map<String, dynamic> _expectJson(InterconnectChannelResponse response) =>
      response.jsonObject ??
      (throw const MangaOcrRemoteException('http', 'invalid JSON response'));
}
