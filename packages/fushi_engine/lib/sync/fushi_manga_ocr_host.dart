/// 漫画 P3：互联 host 代跑 OCR 的服务端任务管理器 + shelf 路由处理。
///
/// 手机端（无内置 OCR 能力）把整卷页图逐页上传给已配对桌面 host，host 用本机
/// [MangaOcrService]（ONNX 流水线）跑整卷 OCR，client 轮询进度后取回 manga.json。
/// 设计 docs/specs/2026-07-24-manga-ocr-design.md §5.3 生产者 C。
///
/// 端点（全部走 FushiSyncServer 的既有 Basic 鉴权，无一豁免）：
/// - `POST   /api/ocr/job`                       → `{jobId, pagesExpected}` 创建任务
///   （body 可带 `model` 点名 capabilities `mangaOcr.models` 里的某个模型）
/// - `POST   /api/ocr/job/<id>/manifest`         → 内容去重（可选，capabilities
///   `mangaOcr.contentDedup` 为真才发）：body `{pages:[{name, sha256?}]}` 按页序列出
///   整卷，host 回 `{known:[name…]}` = 按「引擎签名 + 页图 SHA-256」已有识别结果、
///   不必上传的页（[MangaOcrContentCache]）。发了清单的任务，结果按清单页序组装。
/// - `PUT    /api/ocr/job/<id>/page/<i>?name=..[&mtime=<epoch ms>]` → 逐页上传
///   （body=图片字节；`mtime` 可选 = 源文件修改时间，host 落盘后把页图的修改时间
///   设成它，逐页断点缓存按「页名 + 大小 + 修改时间」校验，同卷重传才对得上）
/// - `POST   /api/ocr/job/<id>/start`            → 开始跑（串行单并发队列）
/// - `GET    /api/ocr/job/<id>`                  → `{state, pagesDone, pagesTotal, ...}`
/// - `GET    /api/ocr/job/<id>/result`           → manga.json 内容
/// - `DELETE /api/ocr/job/<id>`                  → 取消/清理（页边界停；保留
///   `manga_ocr_out/` 逐页断点缓存，同卷重传后续传）
///
/// 独立文件而非写进 `fushi_sync_server.dart`：server 是共享热点文件，只加
/// 构造参数 + 路由分发 + capabilities 字段三处最小接线（见该文件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrOutDirName, kMangaOcrOutputFileName;
import 'package:fushi_engine/ocr/manga_ocr_selected_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/sync/manga_ocr_content_cache.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart'
    show readBoundedBodyString;
import 'package:fushi_engine/utils/misc/atomic_text_file.dart'
    show readAtomicallyWrittenTextFile, writeTextFileAtomically;
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:fushi_engine/utils/net/bounded_read.dart';
import 'package:fushi_core/fushi_core.dart' show fnv1a64Hex;

/// 任务状态机（wire 值即枚举名）。pending → uploading → running →
/// done | error | cancelled；running 覆盖「排队等前一任务」与「真在跑」两态
/// （对 client 无区别：都只能轮询等）。
enum MangaOcrHostJobState {
  pending,
  uploading,
  running,
  done,
  error,
  cancelled;

  bool get isTerminal =>
      this == MangaOcrHostJobState.done ||
      this == MangaOcrHostJobState.error ||
      this == MangaOcrHostJobState.cancelled;
}

/// 一个 host 侧 OCR 任务（内存记录 + 磁盘上传目录）。
class MangaOcrHostJob {
  MangaOcrHostJob({
    required this.id,
    required this.dir,
    required this.createdAt,
    this.volumeTitle,
    this.pagesExpected,
    this.model,
  }) : touchedAt = createdAt;

  final String id;

  /// 上传页图落盘目录（同时是 [MangaOcrService.ocrFolder] 的输入目录；产物与
  /// 逐页断点缓存都在其下的 `manga_ocr_out/`）。
  final Directory dir;
  final String? volumeTitle;

  /// client 预告的页数（仅回显/展示；真实总数以枚举为准）。
  final int? pagesExpected;

  /// client 点名的模型 key（`MangaOcrLocalModel.key`）；null = 用 host 自己的
  /// 当前选择。已在建任务时按 [MangaOcrHostJobManager.modelKeys] 校验过。
  final String? model;

  final DateTime createdAt;
  DateTime touchedAt;

  MangaOcrHostJobState state = MangaOcrHostJobState.pending;
  int pagesUploaded = 0;
  int pagesDone = 0;
  int pagesTotal = 0;
  String? error;
  String? resultPath;

  /// 运行中的 OCR 事件流订阅（取消 = 请求页边界中止）。生命周期由
  /// [MangaOcrHostJobManager] 管理（cancelAndCleanup / disposeAll / _runJob
  /// 收尾必 cancel），lint 跨类看不到故显式豁免。
  // ignore: cancel_subscriptions
  StreamSubscription<MangaOcrVolumeEvent>? subscription;

  /// 本任务在串行队列里的完成信号。订阅被外部取消后 onDone/onError 不再触发，
  /// 取消方必须补 complete，否则队列被永久卡死（后续 start 全部饿死）。
  Completer<void>? runCompleted;

  /// 识别跑完后的收尾（写内容缓存、按清单组装结果）；在途时流的 onDone 不能把
  /// 任务判成「没出结果就结束」。
  Future<void>? publishing;

  /// 整卷任务用的引擎签名（内容缓存的分区）；服务报不出签名时为 null，本任务不做
  /// 内容去重、也不写内容缓存。
  String? engineSignature;

  /// 对端发来的清单（按页序的页名）；null = 老客户端没发，结果就是识别产物本身。
  List<String>? manifest;

  /// 清单里内容缓存命中、不必上传的页（页名 → 缓存结果）。建清单时就读进内存，
  /// 跑完前缓存被淘汰也不缺页。
  Map<String, MangaOcrContentCacheEntry> knownPages =
      <String, MangaOcrContentCacheEntry>{};

  /// 本任务实际上传过的页名（与清单同一套规范化写法）。
  final Set<String> uploadedNames = <String>{};

  /// 上传页的内容哈希（页名 → SHA-256），识别完按它写内容缓存。
  final Map<String, String> pageHashes = <String, String>{};

  /// 清单里命中缓存、又没有上传的页数：进度里算作已完成。
  int get pagesSkipped => manifest == null
      ? 0
      : manifest!
            .where(
              (String name) =>
                  knownPages.containsKey(name) && !uploadedNames.contains(name),
            )
            .length;

  Map<String, Object?> toStatusJson() => <String, Object?>{
    'jobId': id,
    'state': state.name,
    'pagesUploaded': pagesUploaded,
    'pagesDone': pagesDone,
    'pagesTotal': pagesTotal > 0 ? pagesTotal : (pagesExpected ?? 0),
    if (manifest != null) 'pagesSkipped': pagesSkipped,
    if (model != null) 'model': model,
    if (error != null) 'error': error,
  };
}

/// host 侧任务管理器：任务表 + 串行单并发执行队列 + TTL 清理。
/// [MangaOcrService] 构造注入（生产 = MangaOcrServiceImpl；测试 = fake），
/// 对存储层/DB 零依赖，可独立单测。
class MangaOcrHostJobManager {
  /// [runAfter]：串行队列的起点。app 每次开互联新建一个管理器，关了立刻再开时
  /// 旧管理器取消掉的执行体可能还没停（整卷 isolate 还占着整套模型）；把它设成旧
  /// 管理器的 [whenExecutorsStopped]，新管理器的第一个任务就排在旧执行体停下之后，
  /// 不会两套模型同时在内存。缺省 = 立即可跑。它出错同样放行（只是个次序信号）。
  ///
  /// 它同时并进本管理器的 [whenExecutorsStopped]，所以这条链可以传递：连着开关
  /// 互联好几次、中间的管理器任务还在排队没起执行体时，再下一个管理器照样等到
  /// 最早那个还没停下的执行体。原生推理卡死时整条链都不完成，新任务一直排队——
  /// 宁可排队也不让第二套模型进内存（已知局限，见 BUG-4800）。
  MangaOcrHostJobManager({
    required MangaOcrService service,
    required Directory jobRoot,
    Map<String, MangaOcrService> modelServices =
        const <String, MangaOcrService>{},
    DateTime Function()? now,
    Duration jobTtl = const Duration(hours: 1),
    Future<void>? runAfter,
    Future<String> Function(String path)? contentHasher,
    int contentCacheMaxEntries = 20000,
  }) : _service = service,
       _modelServices = modelServices,
       _jobRoot = jobRoot,
       _contentHasher = contentHasher ?? ffcSha256File,
       _contentCache = MangaOcrContentCache(
         root: Directory(p.join(jobRoot.path, kMangaOcrContentCacheDirName)),
         maxEntries: contentCacheMaxEntries,
       ),
       _now = now ?? DateTime.now,
       _jobTtl = jobTtl,
       _predecessorStopped = runAfter == null
           ? Future<void>.value()
           : runAfter.catchError((Object _) {}) {
    _queueTail = _predecessorStopped;
  }

  /// 构造参数 `runAfter`（出错已吞成完成）：上一个管理器的执行体全部停下。
  final Future<void> _predecessorStopped;

  /// host 自己当前选择的模型（client 不点名时用它）。
  final MangaOcrService _service;

  /// client 可点名的模型（key → 该模型的服务）。空 = 老形态，只跑 [_service]。
  final Map<String, MangaOcrService> _modelServices;
  final Directory _jobRoot;
  final DateTime Function() _now;
  final Duration _jobTtl;

  /// 上传页的内容哈希（缺省 = 原生流式 SHA-256，测试注入）。
  final Future<String> Function(String path) _contentHasher;

  /// 按「引擎签名 + 页图内容」的识别结果缓存（任务根下，不随卷目录清理）。
  final MangaOcrContentCache _contentCache;

  final Map<String, MangaOcrHostJob> _jobs = <String, MangaOcrHostJob>{};

  /// 串行执行队列尾（对照 FushiSyncServer._davWriteChain 的链式 future 模式）：
  /// 新 start 挂到链尾，前一整卷跑完才轮到下一卷——OCR 是重活，绝不并行两卷。
  /// 起点见构造参数 `runAfter`。
  late Future<void> _queueTail;

  /// host 重启遗留的孤儿目录只清一次（首个 API 触达时惰性执行）。
  bool _orphanSweepDone = false;

  /// `/api/capabilities` 的 `mangaOcr` 字段：能力协商（老 host 无此字段 →
  /// client 隐藏远程选项，版本 skew 零破坏）。
  Future<Map<String, Object?>> capability() async {
    final bool supported = _service.isSupportedPlatform;
    bool modelsReady = false;
    if (supported) {
      try {
        modelsReady = (await _service.modelStatus()).canRun;
      } catch (_) {
        modelsReady = false;
      }
    }
    // 可点名的模型逐个报就绪态（client 的引擎下拉据此列出「服务端 · <模型>」）。
    // 老 client 不认这个字段，照旧只看 modelsReady。
    final List<Map<String, Object?>> models = <Map<String, Object?>>[];
    for (final MapEntry<String, MangaOcrService> entry
        in _modelServices.entries) {
      if (!entry.value.isSupportedPlatform) continue;
      bool ready = false;
      try {
        ready = (await entry.value.modelStatus()).canRun;
      } catch (_) {
        ready = false;
      }
      models.add(<String, Object?>{'key': entry.key, 'ready': ready});
    }
    return <String, Object?>{
      'supported': supported,
      'modelsReady': modelsReady,
      if (models.isNotEmpty) 'models': models,
      // 对端据此先发内容清单、跳过 host 已识别过的页图。只在 host 的服务报得出
      // 引擎签名时开：签名是内容缓存的分区，报不出就没法保证结果出自同一套模型。
      if (_signsResults(_service)) 'contentDedup': true,
    };
  }

  /// client 可点名的模型 key。
  Iterable<String> get modelKeys => _modelServices.keys;

  MangaOcrService _serviceFor(MangaOcrHostJob job) {
    final String? model = job.model;
    return model == null ? _service : (_modelServices[model] ?? _service);
  }

  /// [service] 报得出整卷引擎签名（可做内容去重）。
  static bool _signsResults(MangaOcrService service) =>
      service is MangaOcrEngineSignatureSource ||
      service is SelectedMangaOcrService;

  /// [job] 此刻的引擎签名；报不出 / 解析失败 / 不能当目录名时为 null。
  Future<String?> _resolveSignature(MangaOcrHostJob job) async {
    final MangaOcrService service = _serviceFor(job);
    if (!_signsResults(service)) return null;
    try {
      final String? signature = await resolveMangaOcrEngineSignature(service);
      if (signature == null ||
          !MangaOcrContentCache.usableSignature(signature)) {
        return null;
      }
      return signature;
    } on Object catch (error, stack) {
      engineLog.log('MangaOcrHostJobManager.resolveSignature', error, stack);
      return null;
    }
  }

  /// 测试钩子：当前驻留任务数（验证 TTL prune 行为）。
  @visibleForTesting
  int get jobCount => _jobs.length;

  /// server 停机：向全部在跑任务发出取消（页边界停，断点缓存保留），任务表清空。
  /// 磁盘目录留给下次启动的孤儿清扫（TTL 内的还能续传）。
  ///
  /// **不等执行体停下就返回**：取消订阅的 Future 要到执行体真正停下（本地模型 =
  /// 整卷 isolate 跑完当前页、关掉推理会话、退出）才完成，原生推理卡住时永远不
  /// 完成。`FushiSyncServer.stop()` 顺序 await 这里，其后才释放别的 host 资源，
  /// 不能被它挂住（BUG-4800）。
  ///
  /// 先取任务快照、清表，再逐个发取消，中间没有 await：别的路径同时增删任务
  /// 不会撞上这里的遍历。还没轮到的排队任务标成已取消，轮到时不再启动。
  ///
  /// 各任务的收尾仍排在自己的执行体停下之后（[_finishWhenStopped]）：串行队列的
  /// 完成信号到那时才补，管理器若仍被引用，后面的任务不会在旧执行体还占着模型时
  /// 起跑；正在途中的 [cancelAndCleanup] 等的是同一个取消 Future，回来发现任务
  /// 已被这里摘出表就不再删页图。全部停下的时刻见 [whenExecutorsStopped]。
  Future<void> disposeAll() async {
    final List<MangaOcrHostJob> jobs = _jobs.values.toList(growable: false);
    _jobs.clear();
    for (final MangaOcrHostJob job in jobs) {
      if (!job.state.isTerminal) {
        job.state = MangaOcrHostJobState.cancelled;
      }
      final StreamSubscription<MangaOcrVolumeEvent>? subscription =
          job.subscription;
      job.subscription = null;
      final Completer<void>? running = job.runCompleted;
      job.runCompleted = null;
      if (subscription == null) {
        // 没有执行体在跑（未 start / 还在排队 / 已收尾）：没有可等的东西。
        if (running != null && !running.isCompleted) running.complete();
        continue;
      }
      _trackStopping(_finishWhenStopped(subscription.cancel(), running));
    }
  }

  /// [disposeAll] 发出取消后还没停下的执行体（各自收尾的 Future）。
  final Set<Future<void>> _stopping = <Future<void>>{};

  /// [disposeAll] 取消掉的执行体全部真正停下（各自的收尾也做完）时完成；没有
  /// 在停的立即完成。要动任务根目录（删除 / 搬走）的调用方先等它——执行体停下
  /// 之前还会往自己的卷目录里写逐页缓存。原生推理卡住时它不完成。
  ///
  /// 也包含上一个管理器的执行体（构造参数 `runAfter`）：本管理器的任务若还在排队
  /// 等它，本管理器自己的 [_stopping] 是空的，只看自己会把还没停下的更早执行体漏掉。
  Future<void> get whenExecutorsStopped =>
      Future.wait<void>(<Future<void>>[_predecessorStopped, ..._stopping]);

  void _trackStopping(Future<void> stopped) {
    _stopping.add(stopped);
    unawaited(stopped.whenComplete(() => _stopping.remove(stopped)));
  }

  /// 等执行体真正停下（[stopped] = 取消订阅的 Future），再补串行队列的完成信号。
  /// 执行体收尾抛的错没有调用方可交（停机已经返回），记日志；完成信号照补，
  /// 否则队列卡死。
  Future<void> _finishWhenStopped(
    Future<void> stopped,
    Completer<void>? running,
  ) async {
    try {
      await stopped;
    } on Object catch (error, stack) {
      engineLog.log('MangaOcrHostJobManager.disposeAll', error, stack);
    } finally {
      if (running != null && !running.isCompleted) running.complete();
    }
  }

  // ── 任务生命周期 ────────────────────────────────────────────────

  /// [model] 必须是 [modelKeys] 之一或 null，调用方负责校验（路由层回 400）。
  MangaOcrHostJob createJob({
    String? volumeTitle,
    int? pageCount,
    String? model,
  }) {
    _housekeep();
    final String id = _generateJobId();
    // 目录名从卷名确定性派生（哈希，文件系统安全）：同卷取消后再建新 job 落回同
    // 一目录，`manga_ocr_out/_pages/` 逐页断点缓存仍在 → 重传后续传（缓存按页名
    // 键控，见 MangaOcrFilePageCache）。无卷名回退 jobId（无续传语义）。
    String dirName = volumeTitle == null || volumeTitle.trim().isEmpty
        ? 'job_$id'
        : 'vol_${_stableSlug(volumeTitle.trim())}';
    // 同名卷已有未完结任务在用该目录：本任务另开独立目录，互不踩踏。
    final bool dirBusy = _jobs.values.any(
      (MangaOcrHostJob j) =>
          !j.state.isTerminal && p.basename(j.dir.path) == dirName,
    );
    if (dirBusy) {
      dirName = '${dirName}_$id';
    }
    final MangaOcrHostJob job = MangaOcrHostJob(
      id: id,
      dir: Directory(p.join(_jobRoot.path, dirName)),
      createdAt: _now(),
      volumeTitle: (volumeTitle == null || volumeTitle.trim().isEmpty)
          ? null
          : volumeTitle.trim(),
      pagesExpected: pageCount,
      model: model,
    );
    job.dir.createSync(recursive: true);
    _jobs[id] = job;
    return job;
  }

  MangaOcrHostJob? job(String id) {
    _housekeep();
    final MangaOcrHostJob? job = _jobs[id];
    if (job != null) job.touchedAt = _now();
    return job;
  }

  /// 逐页上传：`name` 为相对路径（可含一层子目录），拒绝任何穿越/绝对路径写法。
  /// 返回 null = 成功；非 null = 拒绝原因（调用方转 400）。
  ///
  /// [sourceModified] 是对端源文件的修改时间：落盘后把页图的修改时间设成它。
  /// 逐页断点缓存（`MangaOcrFilePageCache`）按「页名 + 大小 + 修改时间」认页，而
  /// 取消会删页图、重传又是新写——不带回源时间，修改时间永远是 host 落盘那一刻，
  /// 保留下来的缓存一页也命中不了（BUG-4817）。老客户端不带则保持落盘时间。
  ///
  /// 设修改时间只为续传，页图本身已经写好：文件系统不收这个时间（FAT / exFAT 的
  /// 可表示范围比 NTFS / POSIX 窄）或页图在两步之间被取消删掉时，这一页只是不能
  /// 续传，上传照常算成功——不能让一个省重复识别的步骤把整卷代跑变成 500。
  ///
  /// 写盘先落本任务专属的暂存名（`<页名>.<jobId>.part`，扩展名不是页图，枚举不收），
  /// 写完再**同步**复核任务仍收上传、改名到位并记账，复核与改名之间没有 await。
  /// 写盘那段 await 期间任务可能已被取消（[cancelAndCleanup] 删光页图、出表）或停机
  /// 清表：旧实现回来照样把页图留在卷目录、把状态写回 `uploading`——那张页图会被同卷
  /// 下一个任务（落回同一个 `vol_<slug>`）当成自己的页一起识别。现在只删自己的
  /// 暂存文件并回 `bad_state`，不碰别的任务可能已经写进同一目录的同名页。
  Future<String?> uploadPage(
    MangaOcrHostJob job, {
    required String name,
    required List<int> bytes,
    DateTime? sourceModified,
  }) async {
    if (!_acceptsUpload(job)) return 'bad_state';
    final List<String>? segments = _sanitizePageName(name);
    if (segments == null) return 'bad_name';
    final File dest = File(p.joinAll(<String>[job.dir.path, ...segments]));
    final File staging = File('${dest.path}.${job.id}.part');
    try {
      dest.parent.createSync(recursive: true);
      await staging.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      // 取消清理在写盘途中删掉了子目录 / 暂存文件：任务已经不收这页。
      if (!_acceptsUpload(job)) {
        _deleteQuietly(staging);
        return 'bad_state';
      }
      rethrow;
    }
    if (sourceModified != null) {
      try {
        // 改名不动修改时间，在暂存文件上设即可。
        await staging.setLastModified(sourceModified);
      } on FileSystemException {
        // 见方法注释：这页保持落盘时间（不续传），不算上传失败。
      }
    }
    // 内容哈希只为识别完写内容缓存：服务报不出签名就用不上，不算。算失败只是这一页
    // 不进内容缓存，上传照常成功。
    String? sha256;
    if (_signsResults(_serviceFor(job))) {
      try {
        final String digest = (await _contentHasher(
          staging.path,
        )).toLowerCase();
        if (isMangaOcrContentSha256(digest)) sha256 = digest;
      } on Object catch (error, stack) {
        engineLog.log('MangaOcrHostJobManager.uploadPage hash', error, stack);
      }
    }
    if (!_acceptsUpload(job)) {
      _deleteQuietly(staging);
      return 'bad_state';
    }
    try {
      staging.renameSync(dest.path);
    } on FileSystemException {
      if (!_acceptsUpload(job)) return 'bad_state';
      _deleteQuietly(staging);
      rethrow;
    }
    final String pageName = segments.join('/');
    job.uploadedNames.add(pageName);
    if (sha256 != null) {
      job.pageHashes[pageName] = sha256;
    } else {
      job.pageHashes.remove(pageName);
    }
    job.pagesUploaded += 1;
    job.state = MangaOcrHostJobState.uploading;
    job.touchedAt = _now();
    return null;
  }

  /// 收对端的内容清单：[entries] 按页序，每项 `{name, sha256?}`。返回 `(拒绝码, 命中
  /// 的页名)`：拒绝码非 null 时调用方转 400 / 409。
  ///
  /// 只在还没有任何上传时收（清单决定哪些页不传，传了一半再改清单说不清）；同一任务
  /// 重发清单（应答丢了的重试）整份替换。命中的页按「本任务的引擎签名 + 页图内容」
  /// 从 [MangaOcrContentCache] 读出、留在任务里，结果按清单页序组装。服务报不出签名
  /// 时照收清单（结果照样按清单页序组装），只是一页也不命中。
  Future<(String?, List<String>)> acceptManifest(
    MangaOcrHostJob job,
    List<Object?> entries,
  ) async {
    if (!_acceptsUpload(job) || job.pagesUploaded > 0) {
      return ('bad_state', const <String>[]);
    }
    if (entries.isEmpty || entries.length > kMangaOcrManifestMaxPages) {
      return ('bad_manifest', const <String>[]);
    }
    final List<String> names = <String>[];
    final Map<String, String> hashes = <String, String>{};
    for (final Object? entry in entries) {
      if (entry is! Map) return ('bad_manifest', const <String>[]);
      final Object? rawName = entry['name'];
      final List<String>? segments = rawName is String
          ? _sanitizePageName(rawName)
          : null;
      if (segments == null) return ('bad_name', const <String>[]);
      final String name = segments.join('/');
      if (hashes.containsKey(name) || names.contains(name)) {
        return ('bad_manifest', const <String>[]);
      }
      names.add(name);
      final Object? rawSha = entry['sha256'];
      if (rawSha is String && isMangaOcrContentSha256(rawSha.toLowerCase())) {
        hashes[name] = rawSha.toLowerCase();
      }
    }
    final String? signature = await _resolveSignature(job);
    final Map<String, MangaOcrContentCacheEntry> known =
        <String, MangaOcrContentCacheEntry>{};
    if (signature != null) {
      for (final MapEntry<String, String> hash in hashes.entries) {
        final MangaOcrContentCacheEntry? hit = await _contentCache.read(
          signature,
          hash.value,
        );
        if (hit != null) known[hash.key] = hit;
      }
    }
    // 读缓存那段 await 期间任务可能被取消 / 已开始收上传。
    if (!_acceptsUpload(job) || job.pagesUploaded > 0) {
      return ('bad_state', const <String>[]);
    }
    job.manifest = names;
    job.knownPages = known;
    job.engineSignature = signature;
    job.touchedAt = _now();
    return (
      null,
      <String>[
        for (final String name in names)
          if (known.containsKey(name)) name,
      ],
    );
  }

  /// [job] 此刻还收逐页上传：未终态、没在跑、仍是表里那一个（没被取消出表或停机清表）。
  bool _acceptsUpload(MangaOcrHostJob job) =>
      !job.state.isTerminal &&
      job.state != MangaOcrHostJobState.running &&
      identical(_jobs[job.id], job);

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 尽力删：留下的暂存文件扩展名不是页图，不会被枚举，交给 TTL / 孤儿清扫。
    }
  }

  /// 开始跑（串行队列）。返回 null = 已受理；非 null = `(statusCode, errorCode)`。
  Future<(int, String)?> start(MangaOcrHostJob job) async {
    if (job.state == MangaOcrHostJobState.running) return null; // 幂等。
    if (job.state.isTerminal) return (409, 'bad_state');
    final List<String>? manifest = job.manifest;
    if (manifest == null) {
      if (job.pagesUploaded <= 0) return (400, 'no_pages');
    } else {
      // 发了清单：每一页要么命中内容缓存，要么已经传上来。
      for (final String name in manifest) {
        if (!job.uploadedNames.contains(name) &&
            !job.knownPages.containsKey(name)) {
          return (400, 'missing_pages');
        }
      }
      if (job.uploadedNames.isEmpty) return _publishFromCache(job);
    }
    final MangaOcrService service = _serviceFor(job);
    if (!service.isSupportedPlatform) return (503, 'not_supported');
    final MangaOcrModelStatus status;
    try {
      status = await service.modelStatus();
    } catch (_) {
      return (503, 'models_not_ready');
    }
    if (!status.canRun) return (503, 'models_not_ready');
    // 等模型状态的那段时间里任务可能已经变了：被取消 / 停机清表（不能再把它
    // 改回 running 排进队列——出了表的任务起跑之后没人能取消），或者另一个
    // start 已经把它排上了（再排一次就是同一个任务起两个执行体）。
    if (job.state.isTerminal || !identical(_jobs[job.id], job)) {
      return (409, 'bad_state');
    }
    if (job.state == MangaOcrHostJobState.running) return null;
    // 老客户端没发清单：签名在这里取，识别完照样给上传的页写内容缓存。
    if (job.manifest == null && job.engineSignature == null) {
      job.engineSignature = await _resolveSignature(job);
      if (job.state.isTerminal || !identical(_jobs[job.id], job)) {
        return (409, 'bad_state');
      }
      if (job.state == MangaOcrHostJobState.running) return null;
    }
    job.state = MangaOcrHostJobState.running;
    job.touchedAt = _now();
    _queueTail = _queueTail.then((_) => _runJob(job));
    return null;
  }

  /// 清单里每一页都命中内容缓存：不跑识别，直接按清单页序组装结果。
  Future<(int, String)?> _publishFromCache(MangaOcrHostJob job) async {
    job.state = MangaOcrHostJobState.running;
    job.touchedAt = _now();
    final File output = File(
      p.join(job.dir.path, kMangaOcrOutDirName, kMangaOcrOutputFileName),
    );
    try {
      await output.parent.create(recursive: true);
      await writeTextFileAtomically(
        output,
        jsonEncode(_composeResult(job, const <String, dynamic>{})),
      );
    } on Object catch (error) {
      if (job.state == MangaOcrHostJobState.running) {
        job.state = MangaOcrHostJobState.error;
        job.error = '$error';
      }
      return null;
    }
    // 写盘期间被取消：保持取消态。
    if (job.state != MangaOcrHostJobState.running) return null;
    final int total = job.manifest!.length;
    job.resultPath = output.path;
    job.pagesDone = total;
    job.pagesTotal = total;
    job.state = MangaOcrHostJobState.done;
    job.touchedAt = _now();
    return null;
  }

  /// 识别跑完的收尾：给上传的页写内容缓存；发了清单的任务再把命中缓存的页并进去、
  /// 按清单页序重写产物。返回最终 manga.json 路径。
  Future<String> _publishResult(
    MangaOcrHostJob job,
    String producedPath,
  ) async {
    final File produced = File(producedPath);
    final Object? decoded = jsonDecode(
      await readAtomicallyWrittenTextFile(produced),
    );
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('manga.json is not an object');
    }
    final Object? rawOcr = decoded['ocr'];
    final Map<String, Object?>? ocr = rawOcr is Map<String, dynamic>
        ? Map<String, Object?>.of(rawOcr)
        : null;
    final Object? producedSignature = ocr?['engine_signature'];
    // 产物自报的签名优先（它就是实际跑的那套模型）；产物不带时用起跑前取的签名。
    final String? signature =
        producedSignature is String &&
            MangaOcrContentCache.usableSignature(producedSignature)
        ? producedSignature
        : job.engineSignature;
    final Object? rawPages = decoded['pages'];
    final List<Object?> pages = rawPages is List ? rawPages : const <Object?>[];
    final Map<String, dynamic> fresh = <String, dynamic>{};
    for (final Object? page in pages) {
      if (page is! Map<String, dynamic>) continue;
      final Object? url = page['url'];
      if (url is! String) continue;
      fresh[url] = page;
      final String? sha256 = job.pageHashes[url];
      if (signature != null && sha256 != null) {
        try {
          await _contentCache.write(signature, sha256, page, ocr: ocr);
        } on Object catch (error, stack) {
          // 内容缓存只是下次省上传，写不进去不影响本次结果。
          engineLog.log('MangaOcrHostJobManager.cacheWrite', error, stack);
        }
      }
    }
    unawaited(_contentCache.prune());
    if (job.manifest == null) return producedPath;
    // 命中的页出自起跑前的签名：模型 / 识别选项在这之间变了，两套结果不能混进一卷。
    if (job.knownPages.isNotEmpty &&
        producedSignature is String &&
        producedSignature != job.engineSignature) {
      throw StateError('engine_changed');
    }
    final Map<String, Object?> composed = _composeResult(job, fresh);
    await writeTextFileAtomically(
      produced,
      jsonEncode(<String, Object?>{...decoded, ...composed}),
    );
    return producedPath;
  }

  /// 按清单页序组装结果页：本任务上传过的页用识别产物（[fresh]，页名 → 页），其余
  /// 用命中的缓存页。缺页抛 [StateError]（[start] 已校验过，不该发生）。
  Map<String, Object?> _composeResult(
    MangaOcrHostJob job,
    Map<String, dynamic> fresh,
  ) {
    Map<String, Object?>? ocr;
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (final String name in job.manifest!) {
      // 只有本任务上传过的页才取识别产物：卷目录 `vol_<slug>` 会留着同卷上一个
      // 已完结任务的页图，同名旧页图也会被识别进产物，但它不是清单里那份内容。
      if (job.uploadedNames.contains(name)) {
        final Object? page = fresh[name];
        if (page is! Map<String, dynamic>) {
          throw StateError('missing page $name');
        }
        pages.add(page);
        continue;
      }
      final MangaOcrContentCacheEntry? hit = job.knownPages[name];
      if (hit == null) throw StateError('missing page $name');
      ocr ??= hit.ocr;
      pages.add(<String, Object?>{'url': name, ...hit.page});
    }
    return <String, Object?>{if (ocr != null) 'ocr': ocr, 'pages': pages};
  }

  Future<void> _runJob(MangaOcrHostJob job) async {
    // 排队期间被取消/清理：不再启动。
    if (job.state != MangaOcrHostJobState.running) return;
    final Completer<void> completed = Completer<void>();
    job.runCompleted = completed;
    void finish() {
      if (!completed.isCompleted) completed.complete();
    }

    job.subscription = _serviceFor(job)
        .ocrFolder(imageDirPath: job.dir.path, volumeTitle: job.volumeTitle)
        .listen(
          (MangaOcrVolumeEvent event) {
            job.touchedAt = _now();
            // 命中内容缓存、没上传的页不在识别范围里，进度里算作已完成。
            final int skipped = job.pagesSkipped;
            if (event.finished) {
              // 发了清单的任务按清单计页：卷目录里同卷旧任务留下的页图也会被
              // 识别，但不属于本卷结果。
              final int total =
                  job.manifest?.length ?? event.pagesTotal + skipped;
              job.pagesDone = total;
              job.pagesTotal = total;
              final String? produced = event.mangaJsonPath;
              if (produced == null) {
                job.state = MangaOcrHostJobState.error;
                job.error = 'OCR finished without manga.json';
                return;
              }
              job.publishing = () async {
                try {
                  final String path = await _publishResult(job, produced);
                  if (job.state != MangaOcrHostJobState.running) return;
                  job.resultPath = path;
                  job.state = MangaOcrHostJobState.done;
                } on Object catch (error) {
                  if (job.state == MangaOcrHostJobState.running) {
                    job.state = MangaOcrHostJobState.error;
                    job.error = '$error';
                  }
                } finally {
                  job.touchedAt = _now();
                }
              }();
            } else {
              job.pagesDone = event.pagesDone + skipped;
              job.pagesTotal = event.pagesTotal + skipped;
            }
          },
          onError: (Object e) {
            job.touchedAt = _now();
            if (job.state == MangaOcrHostJobState.running) {
              job.state = MangaOcrHostJobState.error;
              job.error = '$e';
            }
            finish();
          },
          onDone: () {
            // 收尾在途：等它写完结果再放行串行队列。
            final Future<void>? publishing = job.publishing;
            if (publishing != null) {
              unawaited(publishing.whenComplete(finish));
              return;
            }
            // 流收尾但没发 finished（服务侧静默取消等罕见路径）：不留永久 running。
            if (job.state == MangaOcrHostJobState.running) {
              job.state = MangaOcrHostJobState.error;
              job.error = 'OCR stream ended without result';
            }
            finish();
          },
          cancelOnError: true,
        );
    await completed.future;
    job.subscription = null;
    job.runCompleted = null;
    job.publishing = null;
  }

  /// 取消/清理：订阅取消（[MangaOcrService.ocrFolder] 契约 = 页边界中止）、删除
  /// 已上传页图，但**保留** `manga_ocr_out/`（逐页断点缓存）使同卷重传后续传。
  /// 任务从表中移除（幂等，重复 DELETE 也成功）。
  ///
  /// 卷目录 `vol_<slug>` 可被同卷的新任务共用（旧任务终态后 [createJob] 落回
  /// 同一目录）：表里还有**非终态**任务用着这个目录时页图归它，一个文件也不删。
  ///
  /// 等执行体停下的那段时间里任务被 [disposeAll] 摘出表（server 停机）的，回来
  /// 之后也不删页图：停机之后这个目录归谁，本管理器已经不知道了——app 每次开
  /// 互联都新建一个管理器，同卷的新任务会落回同一个 `vol_<slug>` 并重新上传，
  /// 这里再删就删到新任务头上。留下的页图与停机时别的任务一样交给孤儿清扫。
  Future<void> cancelAndCleanup(MangaOcrHostJob job) async {
    await job.subscription?.cancel();
    final bool detached = !identical(_jobs[job.id], job);
    job.subscription = null;
    if (!job.state.isTerminal) {
      job.state = MangaOcrHostJobState.cancelled;
    }
    // 订阅已取消，onDone/onError 不会再来——必须在此补完成信号，否则串行队列
    // 在 `await completed.future` 上永久卡死、后续任务全部饿死。
    final Completer<void>? running = job.runCompleted;
    if (running != null && !running.isCompleted) {
      running.complete();
    }
    job.runCompleted = null;
    if (detached) return;
    _jobs.remove(job.id);
    if (_dirSharedWithOtherJob(job, liveOnly: true)) return;
    final List<FileSystemEntity> entries;
    try {
      if (!job.dir.existsSync()) return;
      entries = job.dir.listSync(followLinks: false);
    } on FileSystemException {
      return; // 清理失败不致命：TTL 孤儿清扫兜底。
    }
    // 逐个删、互不连坐：Windows 上某一项还被打开着（在飞的上传正往子目录里写）时
    // 删它会抛错，旧实现整个循环跟着中止，排在它后面的页图全留在卷目录里，同卷
    // 下一个任务落回这个目录就会把它们当成自己的页。删不掉的那一项交给 TTL 孤儿
    // 清扫（在飞的上传回来发现任务已不收会删掉自己的暂存文件）。
    for (final FileSystemEntity entity in entries) {
      if (p.basename(entity.path) == kMangaOcrOutDirName) continue;
      try {
        entity.deleteSync(recursive: true);
      } on FileSystemException {
        // 见上。
      }
    }
  }

  /// 读产物 manga.json 内容；未完成/文件缺失返回 null。
  Future<String?> resultJson(MangaOcrHostJob job) async {
    final String? path = job.resultPath;
    if (job.state != MangaOcrHostJobState.done || path == null) return null;
    final File file = File(path);
    if (!file.existsSync()) return null;
    // 产物由 writeTextFileAtomically 写：同卷新任务落回同一目录、正往这个文件上
    // rename 时，Windows 上开着读会让那次替换以「拒绝访问」失败（BUG-4801）。
    return readAtomicallyWrittenTextFile(file);
  }

  // ── TTL / 孤儿清理 ─────────────────────────────────────────────

  /// 每次 API 触达时执行：过期任务（含终态与从未 start 的半截上传）出表删目录；
  /// 首次触达顺带清 host 重启遗留的孤儿目录。在跑中的任务不清。
  ///
  /// 目录按引用回收：过期任务出表后，表里仍有任何任务落在同一目录（同卷新任务
  /// 共用 `vol_<slug>`）就不碰它，目录归仍在表里的任务；同一轮里共享目录的任务
  /// 都过期时，最后一个出表的才删。
  void _housekeep() {
    final DateTime cutoff = _now().subtract(_jobTtl);
    final List<MangaOcrHostJob> expired = _jobs.values
        .where(
          (MangaOcrHostJob j) =>
              j.state != MangaOcrHostJobState.running &&
              j.touchedAt.isBefore(cutoff),
        )
        .toList(growable: false);
    for (final MangaOcrHostJob job in expired) {
      _jobs.remove(job.id);
      if (_dirSharedWithOtherJob(job, liveOnly: false)) continue;
      try {
        if (job.dir.existsSync()) job.dir.deleteSync(recursive: true);
      } catch (_) {
        // 尽力清理：删除失败（文件被占用等）留给下次 TTL 扫描重试。
      }
    }
    if (_orphanSweepDone) return;
    _orphanSweepDone = true;
    try {
      if (!_jobRoot.existsSync()) return;
      final Set<String> live = _jobs.values
          .map((MangaOcrHostJob j) => p.canonicalize(j.dir.path))
          .toSet();
      for (final FileSystemEntity entity in _jobRoot.listSync(
        followLinks: false,
      )) {
        if (entity is! Directory) continue;
        // 内容缓存不是卷目录，自己按条目淘汰（[MangaOcrContentCache.prune]）。
        if (p.basename(entity.path) == kMangaOcrContentCacheDirName) continue;
        if (live.contains(p.canonicalize(entity.path))) continue;
        final DateTime mtime = entity.statSync().modified;
        if (mtime.isBefore(cutoff)) {
          try {
            entity.deleteSync(recursive: true);
          } catch (_) {
            // 尽力清理孤儿目录：失败留给下次扫描。
          }
        }
      }
    } catch (_) {
      // 孤儿扫描整体尽力而为：IO 异常不得影响正常请求处理。
    }
  }

  /// 表里（[job] 之外）还有任务落在同一目录。[liveOnly] = 只算非终态任务。
  bool _dirSharedWithOtherJob(MangaOcrHostJob job, {required bool liveOnly}) {
    final String dir = p.canonicalize(job.dir.path);
    return _jobs.values.any(
      (MangaOcrHostJob other) =>
          !identical(other, job) &&
          (!liveOnly || !other.state.isTerminal) &&
          p.canonicalize(other.dir.path) == dir,
    );
  }

  // ── 工具 ───────────────────────────────────────────────────────

  static String _generateJobId() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// 卷名 → 文件系统安全的确定性目录 slug（FNV-1a 64 位十六进制，委托
  /// fushi_core 单一真相源；输出与历史手写副本逐字节一致——含负哈希带 `-`
  /// 号的历史形态，slug 已固化进 `vol_<slug>` 断点缓存目录名，不得漂移）。
  static String _stableSlug(String title) => fnv1a64Hex(utf8.encode(title));

  /// 页名校验：拆成路径段，拒绝空段、`.`/`..`、绝对路径、盘符、非法文件名字符。
  /// 返回 null = 非法。
  static List<String>? _sanitizePageName(String raw) {
    if (raw.isEmpty || raw.length > 512) return null;
    if (raw.startsWith('/') || raw.startsWith('\\')) return null;
    final List<String> segments = raw.split(RegExp(r'[\\/]+'));
    if (segments.isEmpty || segments.length > 4) return null;
    // G1 收敛：校验字符集共享 [windowsUnsafeFileNameChars]（段内不可能再含
    // `\ /`——已按其切分，判定与旧手写 `[<>:"|?*\x00-\x1F]` 逐段等价）。
    final RegExp invalid = windowsUnsafeFileNameChars;
    for (final String segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') return null;
      if (invalid.hasMatch(segment)) return null;
    }
    // 保护产物目录：页图绝不允许写进 manga_ocr_out/（会污染断点缓存/产物）。
    if (segments.first == kMangaOcrOutDirName) return null;
    return segments;
  }
}

/// `POST /api/ocr/job` 建任务的请求体上限：只有 volumeTitle / pageCount / model。
const int kMangaOcrJobBodyMaxBytes = 64 * 1024;

/// `PUT /api/ocr/job/<id>/page/<index>` 单页图片的上限（扫描页通常几 MB）。
const int kMangaOcrPageBodyMaxBytes = 64 * 1024 * 1024;

/// `POST /api/ocr/job/<id>/manifest` 的请求体上限（每页一个页名 + 一个哈希）。
const int kMangaOcrManifestBodyMaxBytes = 4 * 1024 * 1024;

/// 一份清单最多列的页数。
const int kMangaOcrManifestMaxPages = 10000;

/// 逐页上传的可选 query：源文件修改时间（Unix 毫秒）。
const String kMangaOcrSourceModifiedQuery = 'mtime';

/// 解析 [kMangaOcrSourceModifiedQuery]：缺省、非整数或落在
/// `(0, 9999-12-31]` 之外（文件系统存不下）一律当没带，返回 null。
DateTime? parseMangaOcrSourceModified(String? raw) {
  if (raw == null) return null;
  final int? ms = int.tryParse(raw);
  if (ms == null || ms <= 0 || ms > _kMangaOcrSourceModifiedMaxMs) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

/// 9999-12-31T23:59:59.999Z。
const int _kMangaOcrSourceModifiedMaxMs = 253402300799999;

/// `/api/ocr/*` 的 shelf 路由处理（由 [FushiSyncServer._handleRequest] 分发进来，
/// 鉴权已在其 middleware 完成）。[reqPath] 是已解码、带前导 `/` 的路径。
Future<shelf.Response> handleMangaOcrRequest(
  MangaOcrHostJobManager manager,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  if (reqPath == '/api/ocr/job') {
    if (method != 'POST') return shelf.Response(405);
    Map<String, dynamic> body = const <String, dynamic>{};
    try {
      final dynamic decoded = jsonDecode(
        await readBoundedBodyString(
          request,
          maxBytes: kMangaOcrJobBodyMaxBytes,
        ),
      );
      if (decoded is Map<String, dynamic>) body = decoded;
    } on BodyTooLargeException {
      rethrow;
    } catch (_) {
      // 空 body 也允许（volumeTitle/pageCount 均可选）。
    }
    final String? model = body['model']?.toString();
    // 点名了 host 不认识的模型（对端版本不同 / 已被删掉的模型）：明确拒绝，
    // 不偷偷换成 host 默认——用户选的是那个模型，悄悄换掉结果就对不上号了。
    if (model != null && !manager.modelKeys.contains(model)) {
      return _ocrError(400, 'unknown_model');
    }
    final MangaOcrHostJob job = manager.createJob(
      volumeTitle: body['volumeTitle']?.toString(),
      pageCount: (body['pageCount'] as num?)?.toInt(),
      model: model,
    );
    return _ocrJson(<String, Object?>{
      'jobId': job.id,
      if (job.pagesExpected != null) 'pagesExpected': job.pagesExpected,
    });
  }

  const String prefix = '/api/ocr/job/';
  if (!reqPath.startsWith(prefix)) {
    return shelf.Response.notFound('Not found');
  }
  final String rest = reqPath.substring(prefix.length);
  final List<String> parts = rest.split('/');
  final String jobId = parts.first;
  if (jobId.isEmpty) return shelf.Response.notFound('Not found');
  final MangaOcrHostJob? job = manager.job(jobId);
  if (job == null) {
    return _ocrError(404, 'unknown_job');
  }

  // GET/DELETE /api/ocr/job/<id>
  if (parts.length == 1) {
    if (method == 'GET') {
      return _ocrJson(job.toStatusJson());
    }
    if (method == 'DELETE') {
      await manager.cancelAndCleanup(job);
      return _ocrJson(<String, Object?>{'ok': true});
    }
    return shelf.Response(405);
  }

  // POST /api/ocr/job/<id>/start
  if (parts.length == 2 && parts[1] == 'start') {
    if (method != 'POST') return shelf.Response(405);
    final (int, String)? refusal = await manager.start(job);
    if (refusal != null) {
      return _ocrError(refusal.$1, refusal.$2);
    }
    return _ocrJson(job.toStatusJson());
  }

  // POST /api/ocr/job/<id>/manifest
  if (parts.length == 2 && parts[1] == 'manifest') {
    if (method != 'POST') return shelf.Response(405);
    final Object? decoded;
    try {
      decoded = jsonDecode(
        await readBoundedBodyString(
          request,
          maxBytes: kMangaOcrManifestBodyMaxBytes,
        ),
      );
    } on BodyTooLargeException {
      rethrow;
    } on FormatException {
      return _ocrError(400, 'bad_manifest');
    }
    final Object? pages = decoded is Map ? decoded['pages'] : null;
    if (pages is! List) return _ocrError(400, 'bad_manifest');
    final (String? refusal, List<String> known) = await manager.acceptManifest(
      job,
      pages,
    );
    if (refusal != null) {
      return _ocrError(refusal == 'bad_state' ? 409 : 400, refusal);
    }
    return _ocrJson(<String, Object?>{'known': known});
  }

  // GET /api/ocr/job/<id>/result
  if (parts.length == 2 && parts[1] == 'result') {
    if (method != 'GET') return shelf.Response(405);
    final String? json = await manager.resultJson(job);
    if (json == null) return _ocrError(409, 'not_done');
    return shelf.Response.ok(
      json,
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );
  }

  // PUT /api/ocr/job/<id>/page/<index>?name=<相对路径>
  if (parts.length == 3 && parts[1] == 'page') {
    if (method != 'PUT') return shelf.Response(405);
    final int? index = int.tryParse(parts[2]);
    if (index == null || index < 0) return _ocrError(400, 'bad_index');
    final String name = request.url.queryParameters['name'] ?? '';
    // 整页图片（MB 级）按块累计、超 [kMangaOcrPageBodyMaxBytes] 立即抛（host
    // pipeline 回 413），不展开成逐字节装箱的 List<int>。
    final Uint8List bytes = await readBoundedRequestBody(
      request.read(),
      declaredLength: request.contentLength,
      maxBytes: kMangaOcrPageBodyMaxBytes,
    );
    if (bytes.isEmpty) return _ocrError(400, 'empty_body');
    final String? refusal = await manager.uploadPage(
      job,
      name: name,
      bytes: bytes,
      sourceModified: parseMangaOcrSourceModified(
        request.url.queryParameters[kMangaOcrSourceModifiedQuery],
      ),
    );
    if (refusal != null) return _ocrError(400, refusal);
    return _ocrJson(<String, Object?>{'ok': true, 'index': index});
  }

  return shelf.Response.notFound('Not found');
}

shelf.Response _ocrJson(Map<String, Object?> body) => shelf.Response.ok(
  jsonEncode(body),
  headers: <String, String>{'Content-Type': 'application/json; charset=utf-8'},
);

/// 机器可读错误：`{error: <code>}`，client 按 code 映射本地化文案。
shelf.Response _ocrError(int status, String code) => shelf.Response(
  status,
  body: jsonEncode(<String, String>{'error': code}),
  headers: <String, String>{'Content-Type': 'application/json; charset=utf-8'},
);
