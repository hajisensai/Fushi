/// 漫画 P3：互联 host 代跑 OCR 的服务端任务管理器 + shelf 路由处理。
///
/// 手机端（无内置 OCR 能力）把整卷页图逐页上传给已配对桌面 host，host 用本机
/// [MangaOcrService]（ONNX 流水线）跑整卷 OCR，client 轮询进度后取回 manga.json。
/// 设计 docs/specs/2026-07-24-manga-ocr-design.md §5.3 生产者 C。
///
/// 端点（全部走 FushiSyncServer 的既有 Basic 鉴权，无一豁免）：
/// - `POST   /api/ocr/job`                       → `{jobId, pagesExpected}` 创建任务
/// - `PUT    /api/ocr/job/<id>/page/<i>?name=..` → 逐页上传（body=图片字节）
/// - `POST   /api/ocr/job/<id>/start`            → 开始跑（串行单并发队列）
/// - `GET    /api/ocr/job/<id>`                  → `{state, pagesDone, pagesTotal, ...}`
/// - `GET    /api/ocr/job/<id>/result`           → manga.json 内容
/// - `DELETE /api/ocr/job/<id>`                  → 取消/清理（页边界停；保留
///   `manga_ocr_out/` 逐页断点缓存，同卷重传后续传）
///
/// 独立文件而非写进 `hibiki_sync_server.dart`：server 是共享热点文件，只加
/// 构造参数 + 路由分发 + capabilities 字段三处最小接线（见该文件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

import 'package:fushi/src/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrOutDirName;
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/utils/misc/safe_file_name.dart';
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
  }) : touchedAt = createdAt;

  final String id;

  /// 上传页图落盘目录（同时是 [MangaOcrService.ocrFolder] 的输入目录；产物与
  /// 逐页断点缓存都在其下的 `manga_ocr_out/`）。
  final Directory dir;
  final String? volumeTitle;

  /// client 预告的页数（仅回显/展示；真实总数以枚举为准）。
  final int? pagesExpected;

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

  Map<String, Object?> toStatusJson() => <String, Object?>{
        'jobId': id,
        'state': state.name,
        'pagesUploaded': pagesUploaded,
        'pagesDone': pagesDone,
        'pagesTotal': pagesTotal > 0 ? pagesTotal : (pagesExpected ?? 0),
        if (error != null) 'error': error,
      };
}

/// host 侧任务管理器：任务表 + 串行单并发执行队列 + TTL 清理。
/// [MangaOcrService] 构造注入（生产 = MangaOcrServiceImpl；测试 = fake），
/// 对存储层/DB 零依赖，可独立单测。
class MangaOcrHostJobManager {
  MangaOcrHostJobManager({
    required MangaOcrService service,
    required Directory jobRoot,
    DateTime Function()? now,
    Duration jobTtl = const Duration(hours: 1),
  })  : _service = service,
        _jobRoot = jobRoot,
        _now = now ?? DateTime.now,
        _jobTtl = jobTtl;

  final MangaOcrService _service;
  final Directory _jobRoot;
  final DateTime Function() _now;
  final Duration _jobTtl;

  final Map<String, MangaOcrHostJob> _jobs = <String, MangaOcrHostJob>{};

  /// 串行执行队列尾（对照 FushiSyncServer._davWriteChain 的链式 future 模式）：
  /// 新 start 挂到链尾，前一整卷跑完才轮到下一卷——OCR 是重活，绝不并行两卷。
  Future<void> _queueTail = Future<void>.value();

  /// host 重启遗留的孤儿目录只清一次（首个 API 触达时惰性执行）。
  bool _orphanSweepDone = false;

  /// `/api/capabilities` 的 `mangaOcr` 字段：能力协商（老 host 无此字段 →
  /// client 隐藏远程选项，版本 skew 零破坏）。
  Future<Map<String, Object?>> capability() async {
    final bool supported = _service.isSupportedPlatform;
    bool modelsReady = false;
    if (supported) {
      try {
        modelsReady = (await _service.modelStatus()).allReady;
      } catch (_) {
        modelsReady = false;
      }
    }
    return <String, Object?>{
      'supported': supported,
      'modelsReady': modelsReady
    };
  }

  /// 测试钩子：当前驻留任务数（验证 TTL prune 行为）。
  @visibleForTesting
  int get jobCount => _jobs.length;

  /// server 停机：中止全部在跑任务的订阅（页边界停，断点缓存保留），任务表清空。
  /// 磁盘目录留给下次启动的孤儿清扫（TTL 内的还能续传）。
  Future<void> disposeAll() async {
    for (final MangaOcrHostJob job in _jobs.values) {
      await job.subscription?.cancel();
      job.subscription = null;
      // 同 cancelAndCleanup：补完成信号，防串行队列卡死（管理器可能仍被引用）。
      final Completer<void>? running = job.runCompleted;
      if (running != null && !running.isCompleted) {
        running.complete();
      }
      job.runCompleted = null;
    }
    _jobs.clear();
  }

  // ── 任务生命周期 ────────────────────────────────────────────────

  MangaOcrHostJob createJob({String? volumeTitle, int? pageCount}) {
    _housekeep();
    final String id = _generateJobId();
    // 目录名从卷名确定性派生（哈希，文件系统安全）：同卷取消后再建新 job 落回同
    // 一目录，`manga_ocr_out/_pages/` 逐页断点缓存仍在 → 重传后续传（缓存按页名
    // 键控，见 MangaOcrFilePageCache）。无卷名回退 jobId（无续传语义）。
    String dirName = volumeTitle == null || volumeTitle.trim().isEmpty
        ? 'job_$id'
        : 'vol_${_stableSlug(volumeTitle.trim())}';
    // 同名卷已有未完结任务在用该目录：本任务另开独立目录，互不踩踏。
    final bool dirBusy = _jobs.values.any((MangaOcrHostJob j) =>
        !j.state.isTerminal && p.basename(j.dir.path) == dirName);
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
  Future<String?> uploadPage(
    MangaOcrHostJob job, {
    required String name,
    required List<int> bytes,
  }) async {
    if (job.state.isTerminal || job.state == MangaOcrHostJobState.running) {
      return 'bad_state';
    }
    final List<String>? segments = _sanitizePageName(name);
    if (segments == null) return 'bad_name';
    final File dest = File(p.joinAll(<String>[job.dir.path, ...segments]));
    dest.parent.createSync(recursive: true);
    await dest.writeAsBytes(bytes, flush: true);
    job.pagesUploaded += 1;
    job.state = MangaOcrHostJobState.uploading;
    job.touchedAt = _now();
    return null;
  }

  /// 开始跑（串行队列）。返回 null = 已受理；非 null = `(statusCode, errorCode)`。
  Future<(int, String)?> start(MangaOcrHostJob job) async {
    if (job.state == MangaOcrHostJobState.running) return null; // 幂等。
    if (job.state.isTerminal) return (409, 'bad_state');
    if (job.pagesUploaded <= 0) return (400, 'no_pages');
    if (!_service.isSupportedPlatform) return (503, 'not_supported');
    final MangaOcrModelStatus status;
    try {
      status = await _service.modelStatus();
    } catch (_) {
      return (503, 'models_not_ready');
    }
    if (!status.allReady) return (503, 'models_not_ready');
    job.state = MangaOcrHostJobState.running;
    job.touchedAt = _now();
    _queueTail = _queueTail.then((_) => _runJob(job));
    return null;
  }

  Future<void> _runJob(MangaOcrHostJob job) async {
    // 排队期间被取消/清理：不再启动。
    if (job.state != MangaOcrHostJobState.running) return;
    final Completer<void> completed = Completer<void>();
    job.runCompleted = completed;
    void finish() {
      if (!completed.isCompleted) completed.complete();
    }

    job.subscription = _service
        .ocrFolder(imageDirPath: job.dir.path, volumeTitle: job.volumeTitle)
        .listen(
      (MangaOcrVolumeEvent event) {
        job.touchedAt = _now();
        if (event.finished) {
          job.resultPath = event.mangaJsonPath;
          job.pagesDone = event.pagesTotal;
          job.pagesTotal = event.pagesTotal;
          job.state = MangaOcrHostJobState.done;
        } else {
          job.pagesDone = event.pagesDone;
          job.pagesTotal = event.pagesTotal;
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
  }

  /// 取消/清理：订阅取消（[MangaOcrService.ocrFolder] 契约 = 页边界中止）、删除
  /// 已上传页图，但**保留** `manga_ocr_out/`（逐页断点缓存）使同卷重传后续传。
  /// 任务从表中移除（幂等，重复 DELETE 也成功）。
  Future<void> cancelAndCleanup(MangaOcrHostJob job) async {
    await job.subscription?.cancel();
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
    _jobs.remove(job.id);
    try {
      if (job.dir.existsSync()) {
        for (final FileSystemEntity entity
            in job.dir.listSync(followLinks: false)) {
          if (p.basename(entity.path) == kMangaOcrOutDirName) continue;
          entity.deleteSync(recursive: true);
        }
      }
    } catch (_) {
      // 清理失败不致命：TTL 孤儿清扫兜底。
    }
  }

  /// 读产物 manga.json 内容；未完成/文件缺失返回 null。
  Future<String?> resultJson(MangaOcrHostJob job) async {
    final String? path = job.resultPath;
    if (job.state != MangaOcrHostJobState.done || path == null) return null;
    final File file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsString();
  }

  // ── TTL / 孤儿清理 ─────────────────────────────────────────────

  /// 每次 API 触达时执行：过期任务（含终态与从未 start 的半截上传）出表删目录；
  /// 首次触达顺带清 host 重启遗留的孤儿目录。在跑中的任务不清。
  void _housekeep() {
    final DateTime cutoff = _now().subtract(_jobTtl);
    final List<MangaOcrHostJob> expired = _jobs.values
        .where((MangaOcrHostJob j) =>
            j.state != MangaOcrHostJobState.running &&
            j.touchedAt.isBefore(cutoff))
        .toList(growable: false);
    for (final MangaOcrHostJob job in expired) {
      _jobs.remove(job.id);
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
      for (final FileSystemEntity entity
          in _jobRoot.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
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

  // ── 工具 ───────────────────────────────────────────────────────

  static String _generateJobId() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// 卷名 → 文件系统安全的确定性目录 slug（FNV-1a 64 位十六进制，委托
  /// hibiki_core 单一真相源；输出与历史手写副本逐字节一致——含负哈希带 `-`
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
      final dynamic decoded = jsonDecode(await request.readAsString());
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // 空 body 也允许（volumeTitle/pageCount 均可选）。
    }
    final MangaOcrHostJob job = manager.createJob(
      volumeTitle: body['volumeTitle']?.toString(),
      pageCount: (body['pageCount'] as num?)?.toInt(),
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
    final List<int> bytes = <int>[
      for (final List<int> chunk in await request.read().toList()) ...chunk,
    ];
    if (bytes.isEmpty) return _ocrError(400, 'empty_body');
    final String? refusal =
        await manager.uploadPage(job, name: name, bytes: bytes);
    if (refusal != null) return _ocrError(400, refusal);
    return _ocrJson(<String, Object?>{'ok': true, 'index': index});
  }

  return shelf.Response.notFound('Not found');
}

shelf.Response _ocrJson(Map<String, Object?> body) => shelf.Response.ok(
      jsonEncode(body),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );

/// 机器可读错误：`{error: <code>}`，client 按 code 映射本地化文案。
shelf.Response _ocrError(int status, String code) => shelf.Response(
      status,
      body: jsonEncode(<String, String>{'error': code}),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );
