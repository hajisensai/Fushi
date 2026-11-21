/// 在线漫画章节下载服务（设计稿 2026-09-12 §4，app 级、挂 `AppModel`）。
///
/// 下载是在线直读之外的离线入口（2026-09-26 起点章即在线直读，设计稿 §1 补记）：
/// 单 worker 串行取 `manga_download_jobs`
/// 里最早的 `queued` 任务，任务内 4 并发取页落到章目录，全部齐后写章 `manga.json`
/// → `done`。失败按 2s / 8s / 20s 退避重试三次，再失败留 `failed` + `last_error`；
/// 「再试也一样」的失败（前置条件不满足、要过 Cloudflare 验证、源已停用，见
/// [isPermanentMangaDownloadFailure]）不退避，直接 `failed`。
/// 取消真中止并删半成品目录；暂停（`paused`）同样中止，但半成品原样留着，恢复后
/// 按磁盘现状续跑，暂停态跨进程重启保持。暂停 / 取消立即生效：在飞的请求与退避
/// 都与中止信号赛跑，不等它们自己走完（manga-12）。进程重启后 `running` 行复位为 `queued`
/// 续跑，已落地的页按磁盘现状跳过。
///
/// 完成钩子 [onChapterDownloaded]：`auto_ocr` 为真时由装配方（AppModel）解析引擎
/// 并经 `MangaOcrJobRegistry.enqueue` 起整卷 OCR。钩子抛错只记日志，不影响任务
/// 状态——下载已经成功，OCR 失败是另一件事。
///
/// **mokuro.moe 整卷**（阶段 C，设计稿 §4）：`kind = mokuro_volume` 的任务由同一个
/// worker 调既有 [MokuroMoeVolumeDownloader]（`.part` 续传 / 原子 rename / 解包 /
/// `importFromMokuroPath` 落库语义原样）。`pages_done / pages_total` **只记页**
/// （导入阶段）；CBZ 阶段的字节进度是瞬态，只存在内存 [MangaDownloadService]
/// 的传输进度里，由 [MangaDownloadService.progressOf] 统一成带单位的
/// [MangaDownloadProgress]（BUG：字节曾被塞进页列，UI 显示「第 4718782 /
/// 31302239 页」）。原内存队列 `MokuroMoeDownloadQueue` 已删除：
/// 任务落表后关目录页、重启 app 都不丢，重试仍是**同一行**复位成 `queued`
/// （BUG-1433 的「就地重试不新建行」语义）。
///
/// **合规**：本服务**不**挂 `StoreRestrictedCapability.downloads`——互联对端漫画
/// 在 iOS 是保留的在线源，改成必须下载后读，若下载被门挡住就是死路。Mihon
/// 入口继续受 `onlineMangaSource` 门控（iOS 无入口）。Kavita 按运行时问用户自配
/// 服务器能力（直读与下载 iOS 都保留，2026-10-27 用户拍板），判据收在
/// `online_manga_download_gate.dart`，[MangaDownloadService.enqueueChapter] 再判
/// 一次兜住所有入队路径（作品页 / 阅读器 / 订阅自动下载 / 下载中心）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart'
    show ValueNotifier, mapEquals, visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/download/manga_download_sidecar.dart';
import 'package:fushi/src/media/manga/download/online_manga_download_gate.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_files.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart'
    show MihonCloudflareChallengeException;
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/mokuro_sidecar.dart';

/// 页图字节 → 真实宽高（解不出返回 null）。
typedef MangaPageDimensions =
    Future<({int width, int height})?> Function(Uint8List bytes);

/// mokuro.moe 卷任务的 `runtime` 列值。
const String kMokuroMoeDownloadRuntime = 'mokuro_moe';

/// mokuro.moe 卷任务的 `book_key` 前缀（`mokuro:<seriesName>`，设计稿 §2.2）。
const String kMokuroMoeBookKeyPrefix = 'mokuro:';

/// mokuro.moe 系列 → 任务表 `book_key`。
String mokuroMoeBookKey(String seriesName) =>
    '$kMokuroMoeBookKeyPrefix$seriesName';

/// 任务表 `book_key` → mokuro.moe 系列名；不是 mokuro 任务返回 null。
String? mokuroMoeSeriesNameOf(String bookKey) =>
    bookKey.startsWith(kMokuroMoeBookKeyPrefix)
    ? bookKey.substring(kMokuroMoeBookKeyPrefix.length)
    : null;

/// 生产用 [MokuroMoeVolumeDownloader] 的构造口（一个下载器只跑一次 run）；
/// 测试注入假下载器。
typedef MokuroMoeVolumeDownloaderFactory = MokuroMoeVolumeDownloader Function();

/// 一个任务当前的进度，带单位：页（章节取页 / 卷导入）或字节（mokuro CBZ 下载）。
///
/// 任务表的 `pages_done / pages_total` 只承载页；字节进度不落库（瞬态，进程重启
/// 后从 `.part` 续传重新计），两者经 [MangaDownloadService.progressOf] 合成本类型，
/// UI 据子类型选文案，不再把任意两个整数当页数显示。
sealed class MangaDownloadProgress {
  const MangaDownloadProgress();

  /// 0..1；总量未知时 null（不定进度）。
  double? get fraction;
}

/// 页进度（总量为 0 = 还不知道有几页）。
final class MangaDownloadPageProgress extends MangaDownloadProgress {
  const MangaDownloadPageProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;
}

/// 字节进度（[total] 为 null = 服务端没给 Content-Length）。
final class MangaDownloadByteProgress extends MangaDownloadProgress {
  const MangaDownloadByteProgress({required this.received, this.total});

  final int received;
  final int? total;

  @override
  double? get fraction {
    final int? all = total;
    return all != null && all > 0 ? (received / all).clamp(0.0, 1.0) : null;
  }
}

/// 一章下载完成后交给钩子的上下文。
class MangaDownloadedChapter {
  const MangaDownloadedChapter({
    required this.job,
    required this.bookKey,
    required this.chapterKey,
    required this.title,
    required this.chapterTitle,
    required this.chapterDirectory,
    required this.mangaJsonPath,
  });

  final MangaDownloadJobRow job;
  final String bookKey;
  final String chapterKey;
  final String title;
  final String chapterTitle;

  /// 章目录（含 `manga.json` + `images/`）。
  final Directory chapterDirectory;
  final String mangaJsonPath;
}

/// `auto_ocr` 为真的任务完成后调用；装配方负责解析引擎并起任务。
typedef MangaDownloadOcrHook =
    Future<void> Function(MangaDownloadedChapter chapter);

/// 章节任务内同时在飞的取页数（[MangaDownloadService.pageConcurrency] 的默认值）。
///
/// Android 运行时的取图线程池按「在线直读并发 + 本值」开宽度
/// （`MihonChannelHandler.kt` 的 `DOWNLOAD_PAGE_CONCURRENCY`），改这里要同步改那边，
/// `mihon_image_pool_width_guard_test.dart` 钉着两边。
const int kMangaDownloadPageConcurrency = 4;

/// 任务进度（`pages_done`）写库的最小间隔（manga-4）。
///
/// 每下完一页写一次库，任务表的每次写都是一个 `watchJobs` 信号：作品页、下载中心、
/// 阅读器「本章未下载」态都跟着重读。节流只合并中间值：首个值、页齐那一刻、任务因
/// 暂停 / 取消 / 失败停下时都立即落库（[_ProgressWriter.flush]）。进度仍落库、不改成
/// 只放内存（所有者定，manga-d8）。
const Duration kMangaDownloadProgressWriteInterval = Duration(
  milliseconds: 500,
);

/// 三次自动重试之间的退避（与 mokuro 队列既有语义一致）。
const List<Duration> kMangaDownloadRetryBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

/// 未结束的任务状态：排队 / 下载中 / 暂停。可取消，不能「清除」。
const Set<String> kMangaDownloadUnfinishedStatuses = <String>{
  MangaDownloadJobStatus.queued,
  MangaDownloadJobStatus.running,
  MangaDownloadJobStatus.paused,
};

/// [status] 是不是未结束（见 [kMangaDownloadUnfinishedStatuses]）。
bool isMangaDownloadJobUnfinished(String status) =>
    kMangaDownloadUnfinishedStatuses.contains(status);

/// [status] 是不是「在飞」：排队或下载中，worker 会自己推进（暂停的不算）。
bool isMangaDownloadJobInFlight(String status) =>
    status == MangaDownloadJobStatus.queued ||
    status == MangaDownloadJobStatus.running;

/// 一个任务最多尝试的次数：失败后 `attempt_count < 3` 才退避重跑，否则 `failed`。
const int kMangaDownloadMaxAttempts = 3;

/// 分隔身份串的 NUL（写成转义而不是裸字节：裸 NUL 会让 git 把源码判成 binary）。
final String _identitySeparator = String.fromCharCode(0);

/// 任务 id：`sha256(kind NUL bookKey NUL chapterKey)[:32]`。
String mangaDownloadJobId({
  required String kind,
  required String bookKey,
  required String chapterKey,
}) {
  final String identity = <String>[
    kind,
    bookKey,
    chapterKey,
  ].join(_identitySeparator);
  return sha256.convert(utf8.encode(identity)).toString().substring(0, 32);
}

/// 前置条件不满足：书已出库、条目没有在线描述、章已从源的章节表里下架、运行时
/// 未知等。这类失败**重试也不会变**，不走退避，直接落 `failed`（manga-12）。
class MangaDownloadPreconditionFailed implements Exception {
  const MangaDownloadPreconditionFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 这次失败是不是「再试也一样」：前置条件不满足、源要用户亲自过 Cloudflare 验证
/// （按类型认，见 [mihonCloudflareChallenge]）、源已停用 / 本平台没有该运行时、
/// 页超过单页上限（`PAGE_TOO_LARGE`：同一页再取还是那么大，每次重试都要白下
/// 100 MiB 以上；空页 `PAGE_EMPTY` 可能是站点一时抽风，不算）。
/// 是的话任务直接 `failed`，不再按 [kMangaDownloadRetryBackoff] 白等——一串要验证
/// 或已下架的章节以前每章都要空等 2s + 8s 才失败。其余（网络、站点抽风、运行时
/// 的一般失败）分不出是不是瞬时的，照旧退避重试。
bool isPermanentMangaDownloadFailure(Object error) {
  if (error is MangaDownloadPreconditionFailed) return true;
  if (error is MangaPageBytesRejected && error.code == kMangaPageTooLargeCode) {
    return true;
  }
  if (mihonCloudflareChallenge(error) != null) return true;
  if (error is OnlineMangaUnavailable &&
      error.reason != OnlineMangaUnavailableReason.runtimeFailure) {
    return true;
  }
  return false;
}

/// 中止信号。用户取消（[cancelled]）、用户暂停（[paused]）与服务停止（[stopped]）
/// 三者必须分开：取消把行改成 `cancelled` 并删半成品；暂停把行改成 `paused`、半成品
/// 留着续跑；停止只是进程要退出，行保持 `running` 留给下次启动续跑。
///
/// 除了三个标志，还带一个**可等待的**完成信号 [tripped]（manga-12）：在途的页表
/// 解析、取页、sidecar 与退避等待都和它赛跑，暂停 / 取消立即生效，而不是等在飞的
/// 请求（运行时侧最长 2 分钟）或退避（最长 20 秒）自己走完。
class _CancelToken {
  bool cancelled = false;
  bool paused = false;
  bool stopped = false;

  final Completer<void> _tripped = Completer<void>();

  /// 任一中止标志被置位时完成（只完成一次）。
  Future<void> get tripped => _tripped.future;

  bool get isTripped => cancelled || paused || stopped;

  void cancel() {
    cancelled = true;
    _trip();
  }

  void pause() {
    paused = true;
    _trip();
  }

  void stop() {
    stopped = true;
    _trip();
  }

  /// 置位时要同步回调的监听（[MangaDownloadService._untilTripped] 用）。
  ///
  /// 不能直接在 [tripped] 上挂 `then`：Future 的监听摘不掉，令牌活满整个任务，
  /// 每页挂一个就把每页的结果（页字节）一直攥到任务结束——一章几百页的高清图
  /// 全留在内存里。这里的监听在等的那一步结束时就摘掉。
  final Set<void Function()> _listeners = <void Function()>{};

  /// 挂一个置位监听，返回摘除函数（已置位时不会再回调，调用方自己查 [isTripped]）。
  void Function() onTrip(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// 当前挂着的置位监听数（测试核「等完即摘」用）。
  int get listenerCount => _listeners.length;

  void _trip() {
    if (_tripped.isCompleted) return;
    _tripped.complete();
    final List<void Function()> listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final void Function() listener in listeners) {
      listener();
    }
  }
}

class _ActiveJob {
  _ActiveJob(this.job);

  final MangaDownloadJobRow job;
  String get jobId => job.jobId;
  final _CancelToken token = _CancelToken();
  final Completer<void> done = Completer<void>();

  /// 释放执行体占着的外部资源的钩子：mokuro 卷任务挂 downloader.cancel；章节
  /// 任务挂「把在飞的取页交给运行时取消」（[OnlineMangaPageCancellable]，Android
  /// 取图线程有限，暂停 / 取消后旧请求不该继续占着）。取消 / 暂停 / 停止时在 token
  /// 置位之后同步调用。
  void Function()? abort;
}

/// 一个任务的进度写库节流器，见 [kMangaDownloadProgressWriteInterval]。
class _ProgressWriter {
  _ProgressWriter({
    required FushiDatabase database,
    required String jobId,
    required int Function() now,
  }) : _database = database,
       _jobId = jobId,
       _now = now;

  final FushiDatabase _database;
  final String _jobId;
  final int Function() _now;

  int? _lastWriteAt;
  ({int done, int total})? _written;
  ({int done, int total})? _latest;

  /// 记一个新进度；距上次写库不足间隔且还没到页齐时只记在内存。
  Future<void> report({required int done, required int total}) async {
    _latest = (done: done, total: total);
    final int now = _now();
    final int? last = _lastWriteAt;
    if (last != null &&
        done < total &&
        now - last < kMangaDownloadProgressWriteInterval.inMilliseconds) {
      return;
    }
    await flush();
  }

  /// 把还没落库的最新进度写下去（任务停下时调）。
  Future<void> flush() async {
    final ({int done, int total})? latest = _latest;
    if (latest == null || latest == _written) return;
    final int now = _now();
    _lastWriteAt = now;
    _written = latest;
    await _database.updateMangaDownloadJobProgress(
      _jobId,
      pagesDone: latest.done,
      pagesTotal: latest.total,
      updatedAt: now,
    );
  }
}

class _PageFile {
  const _PageFile({required this.relativeUrl, required this.file});

  final String relativeUrl;
  final File file;
}

/// 一条因 Cloudflare 挑战失败的任务留下的解题材料：挑战本身（URL / User-Agent）
/// 与解它的运行时。只在内存：重启后挑战多半已过期，行上照旧只有「重试」，重试
/// 再撞上挑战时会重新留一份。
typedef MangaDownloadCloudflareChallenge = ({
  Object runtime,
  MihonCloudflareChallengeException challenge,
});

class MangaDownloadService {
  MangaDownloadService({
    required FushiDatabase database,
    required OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
    serviceFor,
    MangaDownloadOcrHook? onChapterDownloaded,
    MangaDownloadSidecarFetcher? sidecarFetcher,
    MokuroMoeVolumeDownloaderFactory? mokuroDownloader,
    DateTime Function()? clock,
    Future<void> Function(Duration duration)? wait,
    DownloadKeepAlive? keepAlive,
    MangaPageDimensions pageDimensions = mangaImageDimensions,
    this.pageConcurrency = kMangaDownloadPageConcurrency,
  }) : _database = database,
       _pageDimensions = pageDimensions,
       _serviceFor = serviceFor,
       _onChapterDownloaded = onChapterDownloaded,
       _sidecarFetcher = sidecarFetcher,
       _mokuroDownloader = mokuroDownloader,
       _clock = clock ?? DateTime.now,
       _wait = wait ?? ((Duration duration) => Future<void>.delayed(duration)),
       _keepAlive = keepAlive ?? downloadKeepAliveHub.lease('manga');

  final FushiDatabase _database;
  final OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
  _serviceFor;
  final MangaDownloadOcrHook? _onChapterDownloaded;
  final MangaDownloadSidecarFetcher? _sidecarFetcher;
  final MokuroMoeVolumeDownloaderFactory? _mokuroDownloader;
  final DateTime Function() _clock;
  final Future<void> Function(Duration duration) _wait;

  /// 页图真实尺寸（全章页齐后写 manga.json 用）；测试注入以卡住全章校验。
  final MangaPageDimensions _pageDimensions;

  /// BUG-2714：worker 有任务在跑就挂下载保活（Android 前台服务），队列排空 /
  /// 服务停止时撤。与其它下载来源经 [downloadKeepAliveHub] 汇总，互不撤对方。
  final DownloadKeepAlive _keepAlive;
  bool _keepAliveActive = false;

  /// 任务内同时在飞的取页数。
  final int pageConcurrency;

  /// mokuro.moe 卷**真正新建书行**的累计数（书架据增量失效 provider 刷新列表；
  /// 已在库被 `DuplicatePolicy.skip()` 跳过的不计）。替代旧内存队列的
  /// `importedCount`。
  final ValueNotifier<int> mokuroImportedCount = ValueNotifier<int>(0);

  bool _started = false;
  bool _disposed = false;
  bool _draining = false;
  bool _wakeRequested = false;
  _ActiveJob? _active;

  /// 当前任务令牌上挂着的置位监听数（没有在跑的任务时为 0）。测试用：在飞的
  /// 等待之外不该有残留监听（manga-12 复审：残留监听会攥住每页字节）。
  @visibleForTesting
  int get debugActiveTripListenerCount => _active?.token.listenerCount ?? 0;

  /// 已要求暂停、但 worker 刚领走还没挂上 [_active] 的任务（领取的 DB 提交与
  /// `_active` 赋值之间隔着一个 await）。worker 挂上时据此立即按暂停收尾。
  final Set<String> _pauseRequested = <String>{};
  Completer<void>? _idle;

  /// 因 Cloudflare 挑战落 `failed` 的任务 → 解题材料（键 = jobId）。任务重新
  /// 开跑 / 重试 / 删除时清掉；读的时候还要求行确实是 `failed`。
  final Map<String, MangaDownloadCloudflareChallenge> _cloudflare =
      <String, MangaDownloadCloudflareChallenge>{};

  /// 正在解的挑战（键 = 挑战 host）：同站的验证单飞，按钮据此显示忙碌。
  final Map<String, Future<bool>> _verifying = <String, Future<bool>>{};

  /// 当前任务的瞬态字节进度（只有 mokuro CBZ 下载阶段非空）；键 = jobId。
  ({String jobId, MangaDownloadByteProgress progress})? _transfer;

  /// 瞬态进度变化的信号；并入 [watchJobs]，消费方无需另外订阅。
  final StreamController<void> _transferChanges =
      StreamController<void>.broadcast(sync: true);

  void _setTransfer(String jobId, MangaDownloadByteProgress? progress) {
    final ({String jobId, MangaDownloadByteProgress progress})? previous =
        _transfer;
    if (progress == null) {
      if (previous == null || previous.jobId != jobId) return;
      _transfer = null;
    } else {
      _transfer = (jobId: jobId, progress: progress);
    }
    if (!_transferChanges.isClosed) _transferChanges.add(null);
  }

  /// 任务当前进度（带单位）：正在下载 CBZ 的任务给字节，其余给表里的页数。
  MangaDownloadProgress progressOf(MangaDownloadJobRow job) {
    final ({String jobId, MangaDownloadByteProgress progress})? transfer =
        _transfer;
    if (transfer != null &&
        transfer.jobId == job.jobId &&
        job.status == MangaDownloadJobStatus.running) {
      return transfer.progress;
    }
    return MangaDownloadPageProgress(
      done: job.pagesDone,
      total: job.pagesTotal,
    );
  }

  int get _now => _clock().millisecondsSinceEpoch;

  /// 上一条新排任务的 `created_at`。worker 按 `(created_at, job_id)` 领取，同一
  /// 毫秒内批量入队（「下载全部」几十章）若共用同一时刻，领取序会退化成哈希序、
  /// 章序丢失；这里保证每条新任务的 `created_at` 严格递增。
  int _lastCreatedAt = 0;

  int _nextCreatedAt() {
    final int now = _now;
    _lastCreatedAt = now > _lastCreatedAt ? now : _lastCreatedAt + 1;
    return _lastCreatedAt;
  }

  /// worker 是否空闲（测试用；生产不需要等它）。
  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();

  /// 启动：把上次进程死亡留下的 `running` 复位并开始消费队列。幂等。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _database.resetRunningMangaDownloadJobs(updatedAt: _now);
    _kick();
  }

  /// 停止消费（正在飞的任务中止；行保持 `running`，下次 [start] 复位续跑）。
  void dispose() {
    _disposed = true;
    final _ActiveJob? active = _active;
    if (active != null) {
      active.token.stop();
      active.abort?.call();
    }
    _stopKeepAlive();
    unawaited(_transferChanges.close());
  }

  /// 任务表变了（或当前任务的瞬态字节进度变了）的信号流（不带行，消费方自己
  /// [listJobs]，进度经 [progressOf] 取）。
  Stream<void> watchJobs() {
    StreamSubscription<void>? table;
    StreamSubscription<void>? transfer;
    late final StreamController<void> merged;
    merged = StreamController<void>(
      onListen: () {
        table = _database.watchMangaDownloadJobs().listen(
          merged.add,
          onError: merged.addError,
        );
        transfer = _transferChanges.stream.listen(merged.add);
      },
      onCancel: () async {
        await transfer?.cancel();
        await table?.cancel();
      },
    );
    return merged.stream;
  }

  /// [job] 若因 Cloudflare 挑战失败且运行时能解，给出解题材料（= 下载中心这一
  /// 行给不给「验证」，判据同作品页的验证按钮 [canSolveMihonCloudflare]）。
  MangaDownloadCloudflareChallenge? cloudflareChallengeOf(
    MangaDownloadJobRow job,
  ) {
    if (job.status != MangaDownloadJobStatus.failed) return null;
    return _cloudflare[job.jobId];
  }

  /// [job] 的挑战是否正在验证（同站任一行在验证都算）。
  bool isVerifyingCloudflare(MangaDownloadJobRow job) {
    final MangaDownloadCloudflareChallenge? record = _cloudflare[job.jobId];
    return record != null && _verifying.containsKey(record.challenge.url.host);
  }

  /// 弹验证页解 [jobId] 这一行的挑战；通过后重试这一行，以及**同站**（挑战
  /// host 相同、同一个运行时）其它因 Cloudflare 失败的行——`cf_clearance` 按站
  /// 生效，一次验证对它们同样有效。
  ///
  /// 返回 true = 验证通过并已重新排队；false = 这一行没有可解的挑战，或用户关掉
  /// 了验证页。验证本身的失败照抛给按钮展示。同站并发的验证共享同一次。
  Future<bool> verifyCloudflare(String jobId) {
    final MangaDownloadCloudflareChallenge? record = _cloudflare[jobId];
    if (record == null) return Future<bool>.value(false);
    final String host = record.challenge.url.host;
    final Future<bool>? pending = _verifying[host];
    if (pending != null) return pending;
    // 先建 future → 再写 map → 最后挂清理（同 Mihon 解题 resolver 的单飞顺序）。
    final Future<bool> solving = _solveCloudflareAndRetry(record);
    _verifying[host] = solving;
    _notifyTransientChange();
    return solving.whenComplete(() {
      _verifying.remove(host);
      _notifyTransientChange();
    });
  }

  Future<bool> _solveCloudflareAndRetry(
    MangaDownloadCloudflareChallenge record,
  ) async {
    final bool solved = await solveMihonCloudflare(
      runtime: record.runtime,
      error: record.challenge,
    );
    if (!solved) return false;
    final String host = record.challenge.url.host;
    final List<String> sameSite = <String>[
      for (final MapEntry<String, MangaDownloadCloudflareChallenge> entry
          in _cloudflare.entries)
        if (entry.value.challenge.url.host == host &&
            identical(entry.value.runtime, record.runtime))
          entry.key,
    ];
    for (final String jobId in sameSite) {
      await retry(jobId);
    }
    return true;
  }

  /// 任务表之外的瞬态状态（验证中）变了：并进 [watchJobs] 让下载中心重绘。
  void _notifyTransientChange() {
    if (!_transferChanges.isClosed) _transferChanges.add(null);
  }

  /// 任务因 [error] 落 `failed` 前调用：是 Cloudflare 挑战、且适配器给得出能解
  /// 它的运行时，就留下解题材料。
  void _rememberCloudflare(MangaDownloadJobRow job, Object error) {
    final MihonCloudflareChallengeException? challenge =
        mihonCloudflareChallenge(error);
    if (challenge == null) return;
    final OnlineMangaRuntimeKind? kind = OnlineMangaRuntimeKind.fromWire(
      job.runtime,
    );
    if (kind == null) return;
    final Object? runtime;
    try {
      runtime = switch (_serviceFor(kind).adapter) {
        OnlineMangaChallengeSolver(:final Object challengeRuntime) =>
          challengeRuntime,
        _ => null,
      };
    } on Object catch (resolveError, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.cloudflareRuntime ${job.jobId}',
        resolveError,
        stack,
      );
      return;
    }
    if (runtime == null ||
        !canSolveMihonCloudflare(runtime: runtime, error: challenge)) {
      return;
    }
    _cloudflare[job.jobId] = (runtime: runtime, challenge: challenge);
  }

  Future<List<MangaDownloadJobRow>> listJobs({
    Set<String> statuses = const <String>{},
  }) => _database.listMangaDownloadJobs(statuses: statuses);

  /// 一本书的任务，按 chapterKey 索引（作品页 / 章节选择器一次取全量）。
  Future<Map<String, MangaDownloadJobRow>> jobsForBook(String bookKey) =>
      _chapterJobsOf(bookKey);

  Future<Map<String, MangaDownloadJobRow>> _chapterJobsOf(
    String bookKey,
  ) async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobsForBook(
          kind: MangaDownloadJobKind.chapter,
          bookKey: bookKey,
        );
    return <String, MangaDownloadJobRow>{
      for (final MangaDownloadJobRow row in rows) row.chapterKey: row,
    };
  }

  /// 一本书的章节任务（按 chapterKey 索引）**变了**的流（HBK-AUDIT-050）。
  ///
  /// 作品页只关心本书：[watchJobs] 是全表信号，别的书每写一次进度都会叫醒它，让它
  /// 重查任务、重判全部章节并重建。这里在服务侧收全表信号、只查本书的行（走索引），
  /// 与上一次的结果逐行比较，**只有本书的行确实变了才发**；订阅时先取一次当基线，
  /// 不发（订阅方自己取首屏）。查询串行：在跑的那次结束后最多补一次。
  Stream<Map<String, MangaDownloadJobRow>> watchChapterJobsForBook(
    String bookKey,
  ) {
    StreamSubscription<void>? table;
    Map<String, MangaDownloadJobRow>? last;
    bool querying = false;
    bool dirty = false;
    bool cancelled = false;
    late final StreamController<Map<String, MangaDownloadJobRow>> changes;

    Future<void> pump() async {
      if (querying) {
        dirty = true;
        return;
      }
      querying = true;
      try {
        do {
          dirty = false;
          final Map<String, MangaDownloadJobRow> current = await _chapterJobsOf(
            bookKey,
          );
          if (cancelled) return;
          final Map<String, MangaDownloadJobRow>? previous = last;
          last = current;
          if (previous != null && !mapEquals(previous, current)) {
            changes.add(current);
          }
        } while (dirty);
      } on Object catch (error, stack) {
        if (!cancelled) changes.addError(error, stack);
      } finally {
        querying = false;
      }
    }

    changes = StreamController<Map<String, MangaDownloadJobRow>>(
      onListen: () {
        table = _database.watchMangaDownloadJobs().listen(
          (_) => unawaited(pump()),
          onError: changes.addError,
        );
        unawaited(pump());
      },
      onCancel: () async {
        cancelled = true;
        await table?.cancel();
      },
    );
    return changes.stream;
  }

  /// 一个 mokuro.moe 系列的卷任务，按卷名索引（目录页渲染行内状态用）。
  Future<Map<String, MangaDownloadJobRow>> mokuroJobsForSeries(
    String seriesName,
  ) async {
    final String bookKey = mokuroMoeBookKey(seriesName);
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs();
    return <String, MangaDownloadJobRow>{
      for (final MangaDownloadJobRow row in rows)
        if (row.bookKey == bookKey &&
            row.kind == MangaDownloadJobKind.mokuroVolume)
          row.chapterKey: row,
    };
  }

  /// 入队一卷 mokuro.moe 卷（`kind = mokuro_volume`，`bookKey = mokuro:<系列>`，
  /// `chapterKey = 卷名`）。
  ///
  /// 幂等：`queued` / `running` 原样返回；`done` / `failed` / `cancelled` 复位成
  /// `queued`**同一行**重跑（done 的卷重下会被下载器的 `DuplicatePolicy.skip()`
  /// 判成已在库，视作成功但无新行）。返回 `(row, added)`：added = 这次是否真的
  /// 新排了任务（目录页据此计数 toast）。
  Future<({MangaDownloadJobRow row, bool added})> enqueueMokuroVolume({
    required String seriesName,
    required String volumeName,
  }) async {
    final String bookKey = mokuroMoeBookKey(seriesName);
    final String jobId = mangaDownloadJobId(
      kind: MangaDownloadJobKind.mokuroVolume,
      bookKey: bookKey,
      chapterKey: volumeName,
    );
    final MangaDownloadJobRow? existing = await _database.getMangaDownloadJob(
      jobId,
    );
    if (existing != null &&
        (existing.status == MangaDownloadJobStatus.queued ||
            existing.status == MangaDownloadJobStatus.running)) {
      return (row: existing, added: false);
    }
    final int now = _now;
    await _database.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion(
        jobId: Value<String>(jobId),
        kind: const Value<String>(MangaDownloadJobKind.mokuroVolume),
        bookKey: Value<String>(bookKey),
        chapterKey: Value<String>(volumeName),
        runtime: const Value<String>(kMokuroMoeDownloadRuntime),
        title: Value<String>(
          MokuroMoeVolumeDownloader.volumeTitle(seriesName, volumeName),
        ),
        chapterTitle: Value<String>(volumeName),
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(0),
        attemptCount: const Value<int>(0),
        lastError: const Value<String?>(null),
        autoOcr: const Value<bool>(false),
        createdAt: Value<int>(existing?.createdAt ?? _nextCreatedAt()),
        updatedAt: Value<int>(now),
        completedAt: const Value<int?>(null),
      ),
    );
    _kick();
    return (row: (await _database.getMangaDownloadJob(jobId))!, added: true);
  }

  /// 批量入队若干卷（保持传入顺序）。返回真正新排的卷数。
  Future<int> enqueueMokuroVolumes({
    required String seriesName,
    required Iterable<String> volumeNames,
  }) async {
    int added = 0;
    for (final String volume in volumeNames) {
      final ({MangaDownloadJobRow row, bool added}) result =
          await enqueueMokuroVolume(seriesName: seriesName, volumeName: volume);
      if (result.added) added += 1;
    }
    return added;
  }

  /// 入队一章。
  ///
  /// 幂等：已 `done` 且目录判据为真 → 原样返回不重下；`queued` / `running` →
  /// 原样返回；`failed` / `cancelled` / 已 done 但目录被删 → 重置成 `queued`。
  /// 条目必须已在书架（`bookKey` 由条目身份推导，与作品页入库用的同一条）。
  Future<MangaDownloadJobRow> enqueueChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required bool autoOcr,
  }) async {
    if (!onlineMangaChapterDownloadsAvailable(entry.runtime)) {
      throw StateError('Chapter downloads are unavailable on this platform');
    }
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(entry);
    final String jobId = mangaDownloadJobId(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: chapter.key,
    );
    final MangaDownloadJobRow? existing = await _database.getMangaDownloadJob(
      jobId,
    );
    if (existing != null) {
      switch (existing.status) {
        case MangaDownloadJobStatus.queued:
        case MangaDownloadJobStatus.running:
          return existing;
        case MangaDownloadJobStatus.done:
          final EpubBookRow? row = await _database.getEpubBook(bookKey);
          if (row != null &&
              row.extractDir.isNotEmpty &&
              await isChapterDownloaded(row.extractDir, chapter.key)) {
            return existing;
          }
      }
    }
    final int now = _now;
    await _database.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion(
        jobId: Value<String>(jobId),
        kind: const Value<String>(MangaDownloadJobKind.chapter),
        bookKey: Value<String>(bookKey),
        chapterKey: Value<String>(chapter.key),
        runtime: Value<String>(entry.runtime.wireValue),
        title: Value<String>(entry.series.title),
        chapterTitle: Value<String>(mangaChapterDisplayName(chapter)),
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(0),
        attemptCount: const Value<int>(0),
        lastError: const Value<String?>(null),
        autoOcr: Value<bool>(autoOcr),
        createdAt: Value<int>(existing?.createdAt ?? _nextCreatedAt()),
        updatedAt: Value<int>(now),
        completedAt: const Value<int?>(null),
      ),
    );
    _kick();
    return (await _database.getMangaDownloadJob(jobId))!;
  }

  /// 批量入队（按给定顺序）。
  Future<void> enqueueChapters({
    required OnlineMangaLibraryEntry entry,
    required Iterable<OnlineMangaChapter> chapters,
    required bool autoOcr,
  }) async {
    for (final OnlineMangaChapter chapter in chapters) {
      await enqueueChapter(entry: entry, chapter: chapter, autoOcr: autoOcr);
    }
  }

  /// 取消：`queued` / `paused` 直接改状态并删半成品；正在飞的任务中止并删半成品
  /// 目录。
  Future<void> cancel(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    final _ActiveJob? active = _active;
    if (active != null && active.jobId == jobId) {
      active.token.cancel();
      active.abort?.call();
      return;
    }
    _pauseRequested.remove(jobId);
    if (isMangaDownloadJobUnfinished(row.status)) {
      await _database.updateMangaDownloadJobStatus(
        jobId,
        status: MangaDownloadJobStatus.cancelled,
        updatedAt: _now,
      );
      await _discardPartialDownload(row);
    }
  }

  /// 暂停：`queued` 直接改成 `paused`；正在飞的任务中止（已落地的页 / `.part`
  /// 留着），等它收尾落库后才返回。已结束 / 已暂停的任务不动。
  Future<void> pause(String jobId) => _pauseWhere(jobId: jobId);

  /// 暂停一本书（[bookKey] 为 null = 全部）所有未结束的任务。先把排队的整批改成
  /// `paused`（一条条件 UPDATE），再停正在飞的那条——反过来做，worker 会在两步
  /// 之间领走下一条排队任务。
  Future<void> pauseAll({String? bookKey}) => _pauseWhere(bookKey: bookKey);

  Future<void> _pauseWhere({String? jobId, String? bookKey}) async {
    await _database.transitionMangaDownloadJobs(
      from: const <String>{MangaDownloadJobStatus.queued},
      to: MangaDownloadJobStatus.paused,
      updatedAt: _now,
      jobId: jobId,
      bookKey: bookKey,
    );
    bool matches(MangaDownloadJobRow row) =>
        (jobId == null || row.jobId == jobId) &&
        (bookKey == null || row.bookKey == bookKey);
    final List<MangaDownloadJobRow> running = await _database
        .listMangaDownloadJobs(
          statuses: const <String>{MangaDownloadJobStatus.running},
        );
    final List<Future<void>> stopping = <Future<void>>[];
    for (final MangaDownloadJobRow row in running) {
      if (!matches(row)) continue;
      final _ActiveJob? active = _active;
      if (active != null && active.jobId == row.jobId) {
        active.token.pause();
        active.abort?.call();
        stopping.add(active.done.future);
      } else if (_started) {
        // 刚被领走、还没挂上 _active：worker 挂上时立即按暂停收尾。
        _pauseRequested.add(row.jobId);
      } else {
        // 服务还没 start()：这是上次进程留下的 running 行，没有执行体，直接落
        // paused，start() 的复位只动 running，不会再把它排回去。
        await _markPaused(row);
      }
    }
    await Future.wait<void>(stopping);
  }

  /// 恢复 `paused` 的任务：改回 `queued`（保留原 `created_at`，排回原来的位置），
  /// worker 从磁盘现状续跑。
  Future<void> resume(String jobId) => _resumeWhere(jobId: jobId);

  /// 恢复一本书（[bookKey] 为 null = 全部）所有暂停的任务。
  Future<void> resumeAll({String? bookKey}) => _resumeWhere(bookKey: bookKey);

  Future<void> _resumeWhere({String? jobId, String? bookKey}) async {
    if (jobId != null) _pauseRequested.remove(jobId);
    final int changed = await _database.transitionMangaDownloadJobs(
      from: const <String>{MangaDownloadJobStatus.paused},
      to: MangaDownloadJobStatus.queued,
      updatedAt: _now,
      jobId: jobId,
      bookKey: bookKey,
      resetAttempts: true,
    );
    if (changed > 0) _kick();
  }

  /// 取消一本书（[bookKey] 为 null = 全部）所有未结束（排队 / 下载中 / 暂停）的
  /// 任务，半成品一并删除（语义同 [cancel]）。
  Future<void> cancelAll({String? bookKey}) async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs(statuses: kMangaDownloadUnfinishedStatuses);
    for (final MangaDownloadJobRow row in rows) {
      if (bookKey != null && row.bookKey != bookKey) continue;
      await cancel(row.jobId);
    }
  }

  /// 重试 `failed` / `cancelled` 的任务。
  Future<void> retry(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    if (row.status != MangaDownloadJobStatus.failed &&
        row.status != MangaDownloadJobStatus.cancelled) {
      return;
    }
    _cloudflare.remove(jobId);
    await _database.updateMangaDownloadJobStatus(
      jobId,
      status: MangaDownloadJobStatus.queued,
      updatedAt: _now,
      clearLastError: true,
      attemptCount: 0,
    );
    _kick();
  }

  /// 删任务行（正在飞的先取消）。不删已下载的章目录——那是内容，走
  /// [deleteChapterDownload]。
  Future<void> remove(String jobId) async {
    final _ActiveJob? active = _active;
    if (active != null && active.jobId == jobId) {
      active.token.cancel();
      active.abort?.call();
      await active.done.future;
    }
    _cloudflare.remove(jobId);
    await _database.deleteMangaDownloadJob(jobId);
  }

  /// 删所有已结束（done / failed / cancelled）的任务行（下载中心「清除已完成」）。
  Future<void> clearFinished() async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs(
          statuses: const <String>{
            MangaDownloadJobStatus.done,
            MangaDownloadJobStatus.failed,
            MangaDownloadJobStatus.cancelled,
          },
        );
    for (final MangaDownloadJobRow row in rows) {
      _cloudflare.remove(row.jobId);
      await _database.deleteMangaDownloadJob(row.jobId);
    }
  }

  // ── worker ─────────────────────────────────────────────────────────

  void _kick() {
    if (!_started || _disposed) return;
    if (_draining) {
      _wakeRequested = true;
      return;
    }
    _draining = true;
    _idle = Completer<void>();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_disposed) {
        final MangaDownloadJobRow? next = await _database
            .claimNextQueuedMangaDownloadJob(updatedAt: _now);
        if (next == null) break;
        final _ActiveJob active = _ActiveJob(next);
        _active = active;
        if (_pauseRequested.remove(next.jobId)) active.token.pause();
        _reportKeepAlive(next);
        try {
          await _run(next, active);
        } on Object catch (error, stack) {
          // _run 自己把失败落库；能到这里的是落库本身失败（库已关等）。
          ErrorLogService.instance.log(
            'MangaDownloadService.run ${next.jobId}',
            error,
            stack,
          );
        } finally {
          _active = null;
          active.done.complete();
        }
      }
    } finally {
      _draining = false;
      final Completer<void>? idle = _idle;
      _idle = null;
      idle?.complete();
      if (_wakeRequested && !_disposed) {
        // 马上还有下一轮：不撤保活——撤了之后 app 若已在后台，Android 不允许
        // 再拉起前台服务，后续任务就失去保护。
        _wakeRequested = false;
        _kick();
      } else {
        _stopKeepAlive();
      }
    }
  }

  /// 当前任务的保活通知：标题是作品名，正文是章 / 卷名（有页数时带百分比）。
  /// 节流 / 去重在 [DownloadKeepAlive] 实现里做，这里每次进度变化都如实报。
  void _reportKeepAlive(
    MangaDownloadJobRow job, {
    int done = 0,
    int total = 0,
  }) {
    if (_disposed) return;
    final int? percent = total > 0
        ? (done.clamp(0, total) * 100 ~/ total)
        : null;
    _keepAliveActive = true;
    unawaited(
      _keepAlive.update(
        title: job.title,
        text: percent == null
            ? job.chapterTitle
            : '${job.chapterTitle} · $percent%',
        percent: percent,
      ),
    );
  }

  void _stopKeepAlive() {
    if (!_keepAliveActive) return;
    _keepAliveActive = false;
    unawaited(_keepAlive.stop());
  }

  Future<void> _run(MangaDownloadJobRow job, _ActiveJob active) async {
    final _CancelToken token = active.token;
    int attempt = job.attemptCount;
    // 重新开跑（重试 / 重新入队）：上一次留下的挑战作废，再撞上会重新留。
    _cloudflare.remove(job.jobId);
    while (true) {
      try {
        _throwIfCancelled(token);
        switch (job.kind) {
          case MangaDownloadJobKind.mokuroVolume:
            await _downloadMokuroVolume(job, active);
          default:
            await _download(job, active);
        }
        return;
      } on _Stopped {
        // 服务停止：行保持 running，下次 start() 复位成 queued 续跑；用户同时
        // 要求过暂停的，落成 paused（重启后不该自己又跑起来）。
        if (token.paused && !token.cancelled) await _markPaused(job);
        return;
      } on _Paused {
        await _markPaused(job);
        return;
      } on _Cancelled {
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.cancelled,
          updatedAt: _now,
        );
        await _discardPartialDownload(job);
        return;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaDownloadService.download ${job.jobId}',
          error,
          stack,
        );
        attempt += 1;
        if (attempt >= kMangaDownloadMaxAttempts ||
            _disposed ||
            isPermanentMangaDownloadFailure(error)) {
          // 先留解题材料再落库：落库触发下载中心重取，那时「验证」就该在。
          _rememberCloudflare(job, error);
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.failed,
            updatedAt: _now,
            lastError: '$error',
            attemptCount: attempt,
          );
          return;
        }
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.running,
          updatedAt: _now,
          lastError: '$error',
          attemptCount: attempt,
        );
        // 退避可被暂停 / 取消 / 停止打断：与 token 的完成信号赛跑（[_wait] 注入口
        // 保留，测试照旧记录退避表）。
        await Future.any<void>(<Future<void>>[
          _wait(
            kMangaDownloadRetryBackoff[(attempt - 1).clamp(
              0,
              kMangaDownloadRetryBackoff.length - 1,
            )],
          ),
          token.tripped,
        ]);
        if (token.stopped) return;
        if (token.paused && !token.cancelled) {
          await _markPaused(job);
          return;
        }
        if (token.cancelled) {
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.cancelled,
            updatedAt: _now,
          );
          await _discardPartialDownload(job);
          return;
        }
      }
    }
  }

  Future<void> _download(MangaDownloadJobRow job, _ActiveJob active) async {
    final _CancelToken token = active.token;
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      job.runtime,
    );
    if (runtime == null) {
      throw MangaDownloadPreconditionFailed(
        'Unknown manga runtime: ${job.runtime}',
      );
    }
    final OnlineMangaLibraryService service = _serviceFor(runtime);
    EpubBookRow? row = await _database.getEpubBook(job.bookKey);
    if (row == null) {
      throw MangaDownloadPreconditionFailed(
        'The manga is no longer in the library: ${job.bookKey}',
      );
    }
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry == null) {
      throw const MangaDownloadPreconditionFailed(
        'The library row has no online descriptor',
      );
    }
    final int chapterIndex = entry.indexOfChapterKey(job.chapterKey);
    if (chapterIndex < 0) {
      throw MangaDownloadPreconditionFailed(
        'The chapter is no longer listed: ${job.chapterKey}',
      );
    }
    final OnlineMangaChapter chapter = entry.chapters[chapterIndex];
    row = await service.ensureBookDirectory(row);
    final String bookDir = row.extractDir;
    final Directory chapterDir = mangaChapterDirectory(bookDir, chapter.key);
    final File mangaJson = mangaChapterJsonFile(chapterDir);
    if (await isChapterDownloaded(bookDir, chapter.key)) {
      await _markDone(job, chapterDir, mangaJson, entry, chapter);
      return;
    }
    _throwIfCancelled(token);
    final OnlineMangaRuntimeAdapter adapter = service.adapter;
    // 页引用会随运行时进程失效（桌面 sidecar 整章下载途中重启，BUG-4908）：经
    // [OnlineMangaChapterPageRefs] 取页，撞上失效就重解析一次页表换新引用接着取，
    // 而不是整章按一般失败退避、重试时从头再解析。
    final OnlineMangaChapterPageRefs pages = OnlineMangaChapterPageRefs(
      adapter: adapter,
      entry: entry,
      chapter: chapter,
      pages: await _untilTripped(
        adapter.resolveChapterPages(entry: entry, chapter: chapter),
        token,
      ),
    );
    if (pages.length == 0) {
      throw StateError('The chapter has no pages');
    }
    _throwIfCancelled(token);
    final Directory images = mangaChapterImagesDirectory(chapterDir);
    await images.create(recursive: true);
    final List<_PageFile?> files = List<_PageFile?>.filled(pages.length, null);
    int done = 0;
    // 续跑：磁盘上已完整落地的页直接认（暂存文件不算）。
    for (int index = 0; index < pages.length; index++) {
      final _PageFile? existing = await _existingPageFile(images, index);
      if (existing != null) {
        files[index] = existing;
        done += 1;
      }
    }
    final _ProgressWriter progress = _ProgressWriter(
      database: _database,
      jobId: job.jobId,
      now: () => _now,
    );
    await progress.report(done: done, total: pages.length);
    _reportKeepAlive(job, done: done, total: pages.length);
    final List<int> pending = <int>[
      for (int index = 0; index < pages.length; index++)
        if (files[index] == null) index,
    ];
    Object? firstError;
    StackTrace? firstStack;
    // 在飞的取页（页序）：暂停 / 取消时经 [OnlineMangaPageCancellable] 交给运行时
    // 取消，释放运行时侧的取图通道（Android 取图线程池有限，见 MihonChannelHandler）。
    // 记页序而不是引用：重解析后在飞的是新引用，取消时按页序取当前引用。
    final Set<int> inFlight = <int>{};
    if (adapter is OnlineMangaPageCancellable) {
      final OnlineMangaPageCancellable cancellable =
          adapter as OnlineMangaPageCancellable;
      active.abort = () {
        if (inFlight.isEmpty) return;
        final List<OnlineMangaPageRef> requests = <OnlineMangaPageRef>[
          for (final int index in inFlight) pages[index],
        ];
        unawaited(
          cancellable.cancelChapterPages(requests).catchError((
            Object error,
            StackTrace stack,
          ) {
            ErrorLogService.instance.log(
              'MangaDownloadService.cancelPages ${job.jobId}',
              error,
              stack,
            );
          }),
        );
      };
    }
    // 待取页按游标出队（单 isolate，worker 之间不会并发改游标）：头删 removeAt(0)
    // 每次都要整体前移剩余元素，P 页一章共 P(P-1)/2 次搬移（HBK-AUDIT-046）。
    int nextPending = 0;
    Future<void> worker() async {
      while (nextPending < pending.length && firstError == null) {
        if (token.isTripped) return;
        final int index = pending[nextPending++];
        inFlight.add(index);
        try {
          files[index] = await _fetchPage(pages, images, index, token);
          done += 1;
          await progress.report(done: done, total: pages.length);
          _reportKeepAlive(job, done: done, total: pages.length);
        } on Object catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        } finally {
          inFlight.remove(index);
        }
      }
    }

    final int concurrency = pageConcurrency < 1 ? 1 : pageConcurrency;
    bool completed = false;
    try {
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < concurrency; i++) worker(),
      ]);
      completed = true;
    } finally {
      active.abort = null;
      // 暂停 / 取消 / 失败停下时，节流攒着的最后进度也要落库（暂停行显示真实页数）。
      await _flushStoppedProgress(
        progress,
        job.jobId,
        stoppingWithError: !completed || token.isTripped || firstError != null,
      );
    }
    _throwIfCancelled(token);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    // 全部页齐 → 用真实字节尺寸写章 manga.json。
    final List<MokuroImage> payloadImages = <MokuroImage>[];
    // 全章校验逐页读整页并解尺寸，几百页的高清章要好几秒：每页前后都看中止令牌，
    // 解尺寸与令牌赛跑，暂停 / 取消不必等校验走完（HBK-AUDIT-046）。
    // 读页**不**与令牌赛跑、要读完：赛跑会把仍开着句柄的读丢在后台，取消随即删
    // 章目录，Windows 上删有打开句柄的文件报 errno 32（ERROR_SHARING_VIOLATION），
    // 半成品就删不掉了。单页读是有界的本地 I/O，最多多等一页。
    for (final _PageFile? file in files) {
      _throwIfCancelled(token);
      if (file == null) throw StateError('A page is missing after download');
      final Uint8List bytes = await file.file.readAsBytes();
      _throwIfCancelled(token);
      final ({int width, int height})? size = await _untilTripped(
        _pageDimensions(bytes),
        token,
      );
      if (size == null) {
        throw StateError('Undecodable page image: ${file.relativeUrl}');
      }
      payloadImages.add(
        MokuroImage(
          url: file.relativeUrl,
          size: MokuroSize(size.width.toDouble(), size.height.toDouble()),
          blocks: const <MokuroBlock>[],
        ),
      );
    }
    _throwIfCancelled(token);
    MokuroPayload payload = MokuroPayload(images: payloadImages);
    final List<String> sourceUrls = <String>[
      for (int index = 0; index < pages.length; index++)
        pages[index].sourceUrl ?? '',
    ];
    final MangaDownloadSidecarFetcher? sidecarFetcher =
        _sidecarFetcher ??
        (adapter is MangaOcrSidecarProvider
            ? (OnlineMangaLibraryEntry e, OnlineMangaChapter c) =>
                  (adapter as MangaOcrSidecarProvider).fetchChapterOcrSidecar(
                    entry: e,
                    chapter: c,
                  )
            : null);
    if (sidecarFetcher != null) {
      try {
        final String? sidecar = await _untilTripped(
          sidecarFetcher(entry, chapter),
          token,
        );
        if (sidecar != null && looksLikeMokuroSidecar(sidecar)) {
          final MokuroSidecarMergeResult merged = mergeMokuroSidecar(
            downloaded: payload,
            sidecarJson: sidecar,
            sourceUrls: sourceUrls,
          );
          if (merged.accepted) payload = merged.payload;
        }
      } on _Interrupted {
        rethrow;
      } on Object catch (error, stack) {
        // sidecar 是增强能力，网络或格式问题不得让图片下载失败。
        ErrorLogService.instance.log(
          'MangaDownloadService.sidecar ${job.jobId}',
          error,
          stack,
        );
      }
    }
    _throwIfCancelled(token);
    await runExclusiveOnMangaJson<void>(
      mangaJson.path,
      () => writeMangaJsonAtomically(mangaJson.path, payload),
    );
    await _markDone(job, chapterDir, mangaJson, entry, chapter);
  }

  /// mokuro.moe 卷：把 [MokuroMoeVolumeDownloader.run] 的事件流映射到任务行。
  ///
  /// 进度：CBZ 阶段的字节只进内存 [_transfer]（经 [progressOf] / [watchJobs]
  /// 给 UI），导入阶段的页才落 `pages_done / pages_total`——页列永远是页。开跑先把
  /// 页列清零：旧版本曾把字节写进页列，续跑的行不能带着它显示。取消 / 停止经 [_ActiveJob.abort] 直接掐下载器
  /// （它在下个 chunk 处抛 [MokuroMoeDownloadCancelled]，`.part` 保留续传），再
  /// 由 token 区分是用户取消还是服务停止。流没走到 done 就正常结束按取消处理
  /// （与旧队列语义一致）。
  Future<void> _downloadMokuroVolume(
    MangaDownloadJobRow job,
    _ActiveJob active,
  ) async {
    final MokuroMoeVolumeDownloaderFactory? factory = _mokuroDownloader;
    if (factory == null) {
      throw const MangaDownloadPreconditionFailed(
        'No mokuro.moe downloader is wired into this service',
      );
    }
    final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
    if (seriesName == null) {
      throw MangaDownloadPreconditionFailed(
        'Not a mokuro.moe task: ${job.bookKey}',
      );
    }
    final _CancelToken token = active.token;
    _throwIfCancelled(token);
    await _database.updateMangaDownloadJobProgress(
      job.jobId,
      pagesDone: 0,
      pagesTotal: 0,
      updatedAt: _now,
    );
    final MokuroMoeVolumeDownloader downloader = factory();
    active.abort = downloader.cancel;
    MokuroMoeVolumeDownloadEvent? last;
    final _ProgressWriter progress = _ProgressWriter(
      database: _database,
      jobId: job.jobId,
      now: () => _now,
    );
    bool completed = false;
    try {
      await for (final MokuroMoeVolumeDownloadEvent event in downloader.run(
        db: _database,
        seriesName: seriesName,
        volumeName: job.chapterKey,
      )) {
        last = event;
        switch (_mokuroProgressOf(event)) {
          case MangaDownloadByteProgress bytes:
            _setTransfer(job.jobId, bytes);
            final int? total = bytes.total;
            if (total != null) {
              _reportKeepAlive(job, done: bytes.received, total: total);
            }
          case MangaDownloadPageProgress pages:
            _setTransfer(job.jobId, null);
            await progress.report(done: pages.done, total: pages.total);
            _reportKeepAlive(job, done: pages.done, total: pages.total);
          case null:
            // 字节阶段之后（解包 / 落库前）不再有字节可报。
            if (event.stage != MokuroMoeDownloadStage.downloadingCbz) {
              _setTransfer(job.jobId, null);
            }
        }
      }
      completed = true;
    } on MokuroMoeDownloadCancelled {
      _throwIfCancelled(token);
      // 下载器自己中止但服务没要求（不该发生）：按取消收尾。
      throw const _Cancelled();
    } finally {
      active.abort = null;
      _setTransfer(job.jobId, null);
      await _flushStoppedProgress(
        progress,
        job.jobId,
        stoppingWithError:
            !completed ||
            token.isTripped ||
            last == null ||
            last.stage != MokuroMoeDownloadStage.done,
      );
    }
    _throwIfCancelled(token);
    if (last == null || last.stage != MokuroMoeDownloadStage.done) {
      throw const _Cancelled();
    }
    final int now = _now;
    await _database.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.done,
      updatedAt: now,
      clearLastError: true,
      completedAt: now,
    );
    if (!last.skippedExisting && last.bookKey != null) {
      mokuroImportedCount.value += 1;
    }
  }

  /// 事件 → 带单位的进度：CBZ 阶段是字节（只进内存），导入阶段是页（落
  /// `pages_done / pages_total`）；本阶段没有可报的进度返回 null。
  static MangaDownloadProgress? _mokuroProgressOf(
    MokuroMoeVolumeDownloadEvent event,
  ) {
    switch (event.stage) {
      case MokuroMoeDownloadStage.downloadingCbz:
        final int? total = event.totalBytes;
        if (total == null || total <= 0) {
          return MangaDownloadByteProgress(
            received: event.receivedBytes < 0 ? 0 : event.receivedBytes,
          );
        }
        return MangaDownloadByteProgress(
          received: event.receivedBytes.clamp(0, total),
          total: total,
        );
      case MokuroMoeDownloadStage.importing:
        if (event.pagesTotal <= 0) return null;
        return MangaDownloadPageProgress(
          done: event.pagesDone.clamp(0, event.pagesTotal),
          total: event.pagesTotal,
        );
      case MokuroMoeDownloadStage.done:
      case MokuroMoeDownloadStage.downloadingMokuro:
      case MokuroMoeDownloadStage.extracting:
        return null;
    }
  }

  /// 暂停收尾：行改 `paused`，半成品（页图 / `.part`）不动，恢复后续跑。
  Future<void> _markPaused(MangaDownloadJobRow job) =>
      _database.updateMangaDownloadJobStatus(
        job.jobId,
        status: MangaDownloadJobStatus.paused,
        updatedAt: _now,
      );

  Future<void> _markDone(
    MangaDownloadJobRow job,
    Directory chapterDir,
    File mangaJson,
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  ) async {
    final int now = _now;
    await _database.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.done,
      updatedAt: now,
      clearLastError: true,
      completedAt: now,
    );
    final MangaDownloadJobRow? current = await _database.getMangaDownloadJob(
      job.jobId,
    );
    if (current == null || !current.autoOcr) return;
    try {
      final MokuroPayload existing = parseMangaJson(
        await mangaJson.readAsString(),
      );
      if (existing.images.isNotEmpty &&
          existing.images.every(
            (MokuroImage image) => image.blocks.isNotEmpty,
          )) {
        return;
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.sidecarOcrCheck ${job.jobId}',
        error,
        stack,
      );
    }
    final MangaDownloadOcrHook? hook = _onChapterDownloaded;
    if (hook == null) return;
    try {
      await hook(
        MangaDownloadedChapter(
          job: current,
          bookKey: job.bookKey,
          chapterKey: chapter.key,
          title: entry.series.title,
          chapterTitle: mangaChapterDisplayName(chapter),
          chapterDirectory: chapterDir,
          mangaJsonPath: mangaJson.path,
        ),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.autoOcr ${job.jobId}',
        error,
        stack,
      );
    }
  }

  /// 取一页落盘。取字节与 [token] 赛跑：暂停 / 取消后不再等在飞的请求，它晚到的
  /// 字节直接丢掉、**不写盘**——已落地的页照旧留给续跑，没落地的那页恢复后重取。
  Future<_PageFile> _fetchPage(
    OnlineMangaChapterPageRefs pages,
    Directory images,
    int index,
    _CancelToken token,
  ) async {
    final Uint8List bytes = await _untilTripped(pages.fetch(index), token);
    // 空页 / 超单页上限与在线直读同一口径（manga_page_files.dart）。
    checkMangaPageBytes(bytes);
    // 落盘名不变：`page-NNNNNN` + 嗅探扩展名，嗅不出来按 `.jpg`（AVIF 有自己的
    // 扩展名，WebView / 导入白名单按扩展名认格式）。先写暂存再改名：半截文件被
    // 续跑当成有效页就是一页永久坏图。
    final String name = mangaPageFileName(
      index,
      bytes,
      unknownExtension: _kUnknownPageExtension,
    );
    final File target = await writeMangaPageFile(
      File(p.join(images.path, name)),
      bytes,
    );
    return _PageFile(
      relativeUrl: '${MangaStorage.kImagesDirName}/$name',
      file: target,
    );
  }

  /// 下载侧嗅不出格式时的扩展名（直读缓存用 `.img`，那边不进章目录）。
  static const String _kUnknownPageExtension = '.jpg';

  /// 续跑时找磁盘上已落地的第 [index] 页（扩展名表里任一个，暂存文件不算，空文件
  /// 不算）。
  Future<_PageFile?> _existingPageFile(Directory images, int index) async {
    final String stem = mangaPageFileStem(index);
    for (final String ext in <String>{
      ...kMangaPageExtensionByContentType.values,
      _kUnknownPageExtension,
    }) {
      final File file = File(p.join(images.path, '$stem$ext'));
      if (await file.exists() && await file.length() > 0) {
        return _PageFile(
          relativeUrl: '${MangaStorage.kImagesDirName}/$stem$ext',
          file: file,
        );
      }
    }
    return null;
  }

  /// 用户取消后丢掉这条任务的半成品（issue #2720）。
  ///
  /// - 章节任务：删未完成章的目录（页图 / 暂存文件）；章已完整落地（manga.json
  ///   在、判据 [isChapterDownloaded] 为真）就是用户的内容，**不删**——取消一条
  ///   排队中的重下任务不能把已下好的章顺手抹掉。
  /// - mokuro 卷：删下载器 staging（`.part` / 未导入的 `.cbz`）；已导入的卷在库
  ///   目录里，不在 staging，不受影响。失败 / 服务停止不走这里，`.part` 照留续传。
  Future<void> _discardPartialDownload(MangaDownloadJobRow job) async {
    try {
      if (job.kind == MangaDownloadJobKind.mokuroVolume) {
        final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
        final MokuroMoeVolumeDownloaderFactory? factory = _mokuroDownloader;
        if (seriesName == null || factory == null) return;
        await factory().discardStaging(
          seriesName: seriesName,
          volumeName: job.chapterKey,
        );
        return;
      }
      if (job.kind != MangaDownloadJobKind.chapter) return;
      final EpubBookRow? row = await _database.getEpubBook(job.bookKey);
      if (row == null) return;
      final String bookDir = row.extractDir;
      if (bookDir.isEmpty) return;
      if (await isChapterDownloaded(bookDir, job.chapterKey)) return;
      await deleteChapterDownload(bookDir, job.chapterKey);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.deleteChapter ${job.jobId}',
        error,
        stack,
      );
    }
  }

  /// 任务停下时把节流攒着的最后进度落库。[stoppingWithError] 为真表示任务正因
  /// 取消 / 暂停 / 停止 / 失败停下：这时写库失败只记日志，不能顶掉那个异常——否则
  /// 任务的停下原因（暂停还是失败、失败原因）会被判错。正常跑完时照常抛。
  static Future<void> _flushStoppedProgress(
    _ProgressWriter progress,
    String jobId, {
    required bool stoppingWithError,
  }) async {
    try {
      await progress.flush();
    } on Object catch (error, stack) {
      if (!stoppingWithError) rethrow;
      ErrorLogService.instance.log(
        'MangaDownloadService.flushProgress $jobId',
        error,
        stack,
      );
    }
  }

  /// 优先级：停止 > 取消 > 暂停（同时要求取消与暂停时取消赢，半成品要删）。
  static void _throwIfCancelled(_CancelToken token) {
    if (token.stopped) throw const _Stopped();
    if (token.cancelled) throw const _Cancelled();
    if (token.paused) throw const _Paused();
  }

  /// 等 [work]，但 [token] 一置位就按 [_throwIfCancelled] 的优先级抛中止异常，
  /// 不再等 [work]。[work] 晚到的结果 / 错误被吞掉（调用方已经不要它了）。
  static Future<T> _untilTripped<T>(Future<T> work, _CancelToken token) {
    final Completer<T> result = Completer<T>();
    void interrupt() {
      if (result.isCompleted) return;
      try {
        _throwIfCancelled(token);
      } on _Interrupted catch (error, stack) {
        result.completeError(error, stack);
      }
    }

    // 监听在 [work] 结束时摘掉（见 [_CancelToken._listeners]：不摘的话每页字节
    // 都被令牌攥到任务结束）。
    final void Function() unsubscribe = token.onTrip(interrupt);
    work.then<void>(
      (T value) {
        unsubscribe();
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        unsubscribe();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    if (token.isTripped) interrupt();
    return result.future;
  }
}

/// 执行体被暂停 / 取消 / 停止打断（不是失败，不进重试与错误日志）。
sealed class _Interrupted implements Exception {
  const _Interrupted();
}

class _Cancelled extends _Interrupted {
  const _Cancelled();
}

class _Paused extends _Interrupted {
  const _Paused();
}

class _Stopped extends _Interrupted {
  const _Stopped();
}
