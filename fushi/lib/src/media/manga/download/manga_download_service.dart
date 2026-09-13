/// 在线漫画章节下载服务（设计稿 2026-09-12 §4，app 级、挂 `AppModel`）。
///
/// 在线漫画必须先下载再读：点章节即入队，单 worker 串行取 `manga_download_jobs`
/// 里最早的 `queued` 任务，任务内 4 并发取页落到章目录，全部齐后写章 `manga.json`
/// → `done`。失败按 2s / 8s / 20s 退避重试三次，再失败留 `failed` + `last_error`；
/// 取消真中止并删半成品目录。进程重启后 `running` 行复位为 `queued` 续跑，已落地的
/// 页按磁盘现状跳过。
///
/// 完成钩子 [onChapterDownloaded]：`auto_ocr` 为真时由装配方（AppModel）解析引擎
/// 并经 `MangaOcrJobRegistry.enqueue` 起整卷 OCR。钩子抛错只记日志，不影响任务
/// 状态——下载已经成功，OCR 失败是另一件事。
///
/// **mokuro.moe 整卷**（阶段 C，设计稿 §4）：`kind = mokuro_volume` 的任务由同一个
/// worker 调既有 [MokuroMoeVolumeDownloader]（`.part` 续传 / 原子 rename / 解包 /
/// `importFromMokuroPath` 落库语义原样），进度映射到 `pages_done / pages_total`
/// （CBZ 阶段是字节、导入阶段是页）。原内存队列 `MokuroMoeDownloadQueue` 已删除：
/// 任务落表后关目录页、重启 app 都不丢，重试仍是**同一行**复位成 `queued`
/// （BUG-1433 的「就地重试不新建行」语义）。
///
/// **合规**：本服务**不**挂 `StoreRestrictedCapability.downloads`——互联对端漫画
/// 在 iOS 是保留的在线源，改成必须下载后读，若下载被门挡住就是死路。Mihon /
/// Aidoku 入口继续受 `onlineMangaSource` 门控（iOS 无入口）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

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
typedef MangaDownloadOcrHook = Future<void> Function(
  MangaDownloadedChapter chapter,
);

/// 三次自动重试之间的退避（与 mokuro 队列既有语义一致）。
const List<Duration> kMangaDownloadRetryBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

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

/// 中止信号。用户取消（[cancelled]）与服务停止（[stopped]）必须分开：前者把行改成
/// `cancelled` 并删半成品，后者只是进程要退出，行保持 `running` 留给下次启动续跑。
class _CancelToken {
  bool cancelled = false;
  bool stopped = false;
}

class _ActiveJob {
  _ActiveJob(this.jobId);

  final String jobId;
  final _CancelToken token = _CancelToken();
  final Completer<void> done = Completer<void>();

  /// 中止当前执行体的钩子（mokuro 卷任务挂 downloader.cancel；章节任务按页
  /// 检查 token，不需要）。取消 / 停止时与 token 一起触发。
  void Function()? abort;
}

class _PageFile {
  const _PageFile({required this.relativeUrl, required this.file});

  final String relativeUrl;
  final File file;
}

class MangaDownloadService {
  MangaDownloadService({
    required FushiDatabase database,
    required OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
        serviceFor,
    MangaDownloadOcrHook? onChapterDownloaded,
    MokuroMoeVolumeDownloaderFactory? mokuroDownloader,
    DateTime Function()? clock,
    Future<void> Function(Duration duration)? wait,
    this.pageConcurrency = 4,
  })  : _database = database,
        _serviceFor = serviceFor,
        _onChapterDownloaded = onChapterDownloaded,
        _mokuroDownloader = mokuroDownloader,
        _clock = clock ?? DateTime.now,
        _wait = wait ?? ((Duration duration) => Future<void>.delayed(duration));

  final FushiDatabase _database;
  final OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
      _serviceFor;
  final MangaDownloadOcrHook? _onChapterDownloaded;
  final MokuroMoeVolumeDownloaderFactory? _mokuroDownloader;
  final DateTime Function() _clock;
  final Future<void> Function(Duration duration) _wait;

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
  Completer<void>? _idle;

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
      active.token.stopped = true;
      active.abort?.call();
    }
  }

  /// 任务表变了的信号流（不带行，消费方自己 [listJobs]）。
  Stream<void> watchJobs() => _database.watchMangaDownloadJobs();

  Future<List<MangaDownloadJobRow>> listJobs({
    Set<String> statuses = const <String>{},
  }) =>
      _database.listMangaDownloadJobs(statuses: statuses);

  /// 一本书的任务，按 chapterKey 索引（作品页 / 章节选择器一次取全量）。
  Future<Map<String, MangaDownloadJobRow>> jobsForBook(String bookKey) async {
    final List<MangaDownloadJobRow> rows =
        await _database.listMangaDownloadJobs();
    return <String, MangaDownloadJobRow>{
      for (final MangaDownloadJobRow row in rows)
        if (row.bookKey == bookKey && row.kind == MangaDownloadJobKind.chapter)
          row.chapterKey: row,
    };
  }

  /// 一个 mokuro.moe 系列的卷任务，按卷名索引（目录页渲染行内状态用）。
  Future<Map<String, MangaDownloadJobRow>> mokuroJobsForSeries(
    String seriesName,
  ) async {
    final String bookKey = mokuroMoeBookKey(seriesName);
    final List<MangaDownloadJobRow> rows =
        await _database.listMangaDownloadJobs();
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
    final MangaDownloadJobRow? existing =
        await _database.getMangaDownloadJob(jobId);
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
          await enqueueMokuroVolume(
        seriesName: seriesName,
        volumeName: volume,
      );
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
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(entry);
    final String jobId = mangaDownloadJobId(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: chapter.key,
    );
    final MangaDownloadJobRow? existing =
        await _database.getMangaDownloadJob(jobId);
    if (existing != null) {
      switch (existing.status) {
        case MangaDownloadJobStatus.queued:
        case MangaDownloadJobStatus.running:
          return existing;
        case MangaDownloadJobStatus.done:
          final EpubBookRow? row = await _database.getEpubBook(bookKey);
          if (row != null &&
              await isChapterDownloaded(
                await MangaStorage.bookPath(row.bookKey),
                chapter.key,
              )) {
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

  /// 取消：`queued` 直接改状态；正在飞的任务中止并删半成品目录。
  Future<void> cancel(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    final _ActiveJob? active = _active;
    if (active != null && active.jobId == jobId) {
      active.token.cancelled = true;
      active.abort?.call();
      return;
    }
    if (row.status == MangaDownloadJobStatus.queued ||
        row.status == MangaDownloadJobStatus.running) {
      await _database.updateMangaDownloadJobStatus(
        jobId,
        status: MangaDownloadJobStatus.cancelled,
        updatedAt: _now,
      );
      await _deleteChapterDirectory(row);
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
      active.token.cancelled = true;
      active.abort?.call();
      await active.done.future;
    }
    await _database.deleteMangaDownloadJob(jobId);
  }

  /// 删所有已结束（done / failed / cancelled）的任务行（下载中心「清除已完成」）。
  Future<void> clearFinished() async {
    final List<MangaDownloadJobRow> rows = await _database.listMangaDownloadJobs(
      statuses: const <String>{
        MangaDownloadJobStatus.done,
        MangaDownloadJobStatus.failed,
        MangaDownloadJobStatus.cancelled,
      },
    );
    for (final MangaDownloadJobRow row in rows) {
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
        final MangaDownloadJobRow? next =
            await _database.claimNextQueuedMangaDownloadJob(updatedAt: _now);
        if (next == null) break;
        final _ActiveJob active = _ActiveJob(next.jobId);
        _active = active;
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
        _wakeRequested = false;
        _kick();
      }
    }
  }

  Future<void> _run(MangaDownloadJobRow job, _ActiveJob active) async {
    final _CancelToken token = active.token;
    int attempt = job.attemptCount;
    while (true) {
      try {
        switch (job.kind) {
          case MangaDownloadJobKind.mokuroVolume:
            await _downloadMokuroVolume(job, active);
          default:
            await _download(job, token);
        }
        return;
      } on _Stopped {
        // 服务停止：行保持 running，下次 start() 复位成 queued 续跑。
        return;
      } on _Cancelled {
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.cancelled,
          updatedAt: _now,
        );
        await _deleteChapterDirectory(job);
        return;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaDownloadService.download ${job.jobId}',
          error,
          stack,
        );
        attempt += 1;
        if (attempt >= kMangaDownloadMaxAttempts || _disposed) {
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
        await _wait(
          kMangaDownloadRetryBackoff[
              (attempt - 1).clamp(0, kMangaDownloadRetryBackoff.length - 1)],
        );
        if (token.stopped) return;
        if (token.cancelled) {
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.cancelled,
            updatedAt: _now,
          );
          await _deleteChapterDirectory(job);
          return;
        }
      }
    }
  }

  Future<void> _download(MangaDownloadJobRow job, _CancelToken token) async {
    final OnlineMangaRuntimeKind? runtime =
        OnlineMangaRuntimeKind.fromWire(job.runtime);
    if (runtime == null) {
      throw StateError('Unknown manga runtime: ${job.runtime}');
    }
    final OnlineMangaLibraryService service = _serviceFor(runtime);
    EpubBookRow? row = await _database.getEpubBook(job.bookKey);
    if (row == null) {
      throw StateError('The manga is no longer in the library: ${job.bookKey}');
    }
    final OnlineMangaLibraryEntry? entry =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata);
    if (entry == null) {
      throw StateError('The library row has no online descriptor');
    }
    final int chapterIndex = entry.indexOfChapterKey(job.chapterKey);
    if (chapterIndex < 0) {
      throw StateError('The chapter is no longer listed: ${job.chapterKey}');
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
    final List<OnlineMangaPageRef> pages = await service.adapter
        .resolveChapterPages(entry: entry, chapter: chapter);
    if (pages.isEmpty) {
      throw StateError('The chapter has no pages');
    }
    _throwIfCancelled(token);
    final Directory images = mangaChapterImagesDirectory(chapterDir);
    await images.create(recursive: true);
    final List<_PageFile?> files = List<_PageFile?>.filled(pages.length, null);
    int done = 0;
    // 续跑：磁盘上已完整落地的页直接认（`.tmp` 不算）。
    for (int index = 0; index < pages.length; index++) {
      final _PageFile? existing = await _existingPageFile(images, index);
      if (existing != null) {
        files[index] = existing;
        done += 1;
      }
    }
    await _database.updateMangaDownloadJobProgress(
      job.jobId,
      pagesDone: done,
      pagesTotal: pages.length,
      updatedAt: _now,
    );
    final List<int> pending = <int>[
      for (int index = 0; index < pages.length; index++)
        if (files[index] == null) index,
    ];
    Object? firstError;
    StackTrace? firstStack;
    Future<void> worker() async {
      while (pending.isNotEmpty && firstError == null) {
        if (token.cancelled || token.stopped) return;
        final int index = pending.removeAt(0);
        try {
          files[index] = await _fetchPage(
            service.adapter,
            pages[index],
            images,
            index,
          );
          done += 1;
          await _database.updateMangaDownloadJobProgress(
            job.jobId,
            pagesDone: done,
            pagesTotal: pages.length,
            updatedAt: _now,
          );
        } on Object catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    final int concurrency = pageConcurrency < 1 ? 1 : pageConcurrency;
    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < concurrency; i++) worker(),
    ]);
    _throwIfCancelled(token);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    // 全部页齐 → 用真实字节尺寸写章 manga.json。
    final List<MokuroImage> payloadImages = <MokuroImage>[];
    for (final _PageFile? file in files) {
      if (file == null) throw StateError('A page is missing after download');
      final Uint8List bytes = await file.file.readAsBytes();
      final ({int width, int height})? size = await mangaImageDimensions(bytes);
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
    final MokuroPayload payload = MokuroPayload(images: payloadImages);
    await runExclusiveOnMangaJson<void>(
      mangaJson.path,
      () => writeMangaJsonAtomically(mangaJson.path, payload),
    );
    await _markDone(job, chapterDir, mangaJson, entry, chapter);
  }

  /// mokuro.moe 卷：把 [MokuroMoeVolumeDownloader.run] 的事件流映射到任务行。
  ///
  /// 进度：CBZ 阶段 `pages_done / pages_total` 记字节（总量未知时不写），导入阶段
  /// 记页——UI 侧只看比值。取消 / 停止经 [_ActiveJob.abort] 直接掐下载器
  /// （它在下个 chunk 处抛 [MokuroMoeDownloadCancelled]，`.part` 保留续传），再
  /// 由 token 区分是用户取消还是服务停止。流没走到 done 就正常结束按取消处理
  /// （与旧队列语义一致）。
  Future<void> _downloadMokuroVolume(
    MangaDownloadJobRow job,
    _ActiveJob active,
  ) async {
    final MokuroMoeVolumeDownloaderFactory? factory = _mokuroDownloader;
    if (factory == null) {
      throw StateError('No mokuro.moe downloader is wired into this service');
    }
    final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
    if (seriesName == null) {
      throw StateError('Not a mokuro.moe task: ${job.bookKey}');
    }
    final _CancelToken token = active.token;
    _throwIfCancelled(token);
    final MokuroMoeVolumeDownloader downloader = factory();
    active.abort = downloader.cancel;
    MokuroMoeVolumeDownloadEvent? last;
    try {
      await for (final MokuroMoeVolumeDownloadEvent event in downloader.run(
        db: _database,
        seriesName: seriesName,
        volumeName: job.chapterKey,
      )) {
        last = event;
        final ({int done, int total})? progress = _mokuroProgressOf(event);
        if (progress != null) {
          await _database.updateMangaDownloadJobProgress(
            job.jobId,
            pagesDone: progress.done,
            pagesTotal: progress.total,
            updatedAt: _now,
          );
        }
      }
    } on MokuroMoeDownloadCancelled {
      _throwIfCancelled(token);
      // 下载器自己中止但服务没要求（不该发生）：按取消收尾。
      throw const _Cancelled();
    } finally {
      active.abort = null;
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

  /// 事件 → `(pages_done, pages_total)`；本阶段没有可比的进度返回 null（不动列）。
  static ({int done, int total})? _mokuroProgressOf(
    MokuroMoeVolumeDownloadEvent event,
  ) {
    switch (event.stage) {
      case MokuroMoeDownloadStage.downloadingCbz:
        final int? total = event.totalBytes;
        if (total == null || total <= 0) return null;
        return (done: event.receivedBytes.clamp(0, total), total: total);
      case MokuroMoeDownloadStage.importing:
        if (event.pagesTotal <= 0) return null;
        return (
          done: event.pagesDone.clamp(0, event.pagesTotal),
          total: event.pagesTotal,
        );
      case MokuroMoeDownloadStage.done:
      case MokuroMoeDownloadStage.downloadingMokuro:
      case MokuroMoeDownloadStage.extracting:
        return null;
    }
  }

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
    final MangaDownloadJobRow? current =
        await _database.getMangaDownloadJob(job.jobId);
    if (current == null || !current.autoOcr) return;
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

  Future<_PageFile> _fetchPage(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaPageRef page,
    Directory images,
    int index,
  ) async {
    final Uint8List bytes = await adapter.fetchChapterPage(page);
    if (bytes.isEmpty) {
      throw StateError('Empty page image at index $index');
    }
    final String name = '${_pageStem(index)}${_extensionFor(bytes)}';
    final File target = File(p.join(images.path, name));
    // 先写 .tmp 再 rename：半截文件被续跑当成有效页就是一页永久坏图。
    final File staged = File('${target.path}.tmp');
    await staged.writeAsBytes(bytes, flush: true);
    await staged.rename(target.path);
    return _PageFile(
      relativeUrl: '${MangaStorage.kImagesDirName}/$name',
      file: target,
    );
  }

  static String _pageStem(int index) =>
      'page-${(index + 1).toString().padLeft(6, '0')}';

  /// 续跑时找磁盘上已落地的第 [index] 页（任意扩展名，`.tmp` 除外，空文件不算）。
  Future<_PageFile?> _existingPageFile(Directory images, int index) async {
    final String stem = _pageStem(index);
    for (final String ext in const <String>['.jpg', '.png', '.webp', '.gif']) {
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

  static String _extensionFor(Uint8List bytes) {
    switch (mangaImageContentType(bytes)) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      default:
        return '.jpg';
    }
  }

  Future<void> _deleteChapterDirectory(MangaDownloadJobRow job) async {
    // mokuro 卷的半成品是下载器 staging 目录里的 `.part`，刻意保留供续传。
    if (job.kind != MangaDownloadJobKind.chapter) return;
    try {
      final EpubBookRow? row = await _database.getEpubBook(job.bookKey);
      if (row == null) return;
      await deleteChapterDownload(
        await MangaStorage.bookPath(row.bookKey),
        job.chapterKey,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.deleteChapter ${job.jobId}',
        error,
        stack,
      );
    }
  }

  static void _throwIfCancelled(_CancelToken token) {
    if (token.stopped) throw const _Stopped();
    if (token.cancelled) throw const _Cancelled();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Stopped implements Exception {
  const _Stopped();
}
