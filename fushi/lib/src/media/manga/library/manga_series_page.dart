import 'dart:async';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/manga_ocr_settings_page.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart'
    show ReaderHistoryDeleteDialog;
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/sync/deletion_prompt_preferences.dart';
import 'package:fushi/src/sync/deletion_propagation_availability.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:path/path.dart' as p;

/// 作品页要显示**哪一部**作品。
///
/// 两个变体的差别只在「条目从哪来、能不能落库」，头部、章节列表、阅读入口全部
/// 是同一套代码——所以这里用 sealed 穷尽，而不是给页面塞一堆可空参数再靠
/// 「恰有一个非空」的隐式约定分流（与 `MihonBrowseTarget` 同款处理）。
sealed class MangaSeriesTarget {
  const MangaSeriesTarget();
}

/// 已在书架的条目。**只带 bookKey**：作品页因此不需要任何来源上下文就能开，
/// 源挂了、扩展被禁用、甚至离线，用户依然能看到自己书架里这部作品有哪些章。
class ShelfMangaSeriesTarget extends MangaSeriesTarget {
  const ShelfMangaSeriesTarget(this.bookKey, {this.item});

  final String bookKey;

  /// 书架传进来的媒体条目。开阅读器时原样交回 `AppModel.openMedia`，让沉浸
  /// 模式、wakelock、audio handler、历史记账与 v88 前逐字相同。书架以外的入口
  /// （源浏览）没有它，开阅读器时现造一条。
  final MediaItem? item;
}

/// 还没入库的在线作品，来自一次源浏览。
///
/// [seed] 的 `chapters` 通常是空的（网格上只有标题和封面），进页后由
/// [OnlineMangaLibraryService.refreshFromSource] 拉齐。
class SourceMangaSeriesTarget extends MangaSeriesTarget {
  const SourceMangaSeriesTarget({
    required this.adapter,
    required this.seed,
    this.service,
    this.sourceLabel,
    this.remoteCoverBuilder,
  });

  /// 拉详情/章节/页面用的运行时半边。
  ///
  /// **只给 adapter 就能把这一页显示出来**：源浏览进来的作品还没入库，展示它不该
  /// 需要数据库、更不该需要整个 AppModel（那会让「点开一个作品」依赖应用初始化，
  /// 也让这条路径没法在 widget 测试里单独立起来）。
  final OnlineMangaRuntimeAdapter adapter;

  final OnlineMangaLibraryEntry seed;

  /// 书架半边。缺席时页面照常展示，只是「加入书架」不可用——由页面按需从
  /// AppModel 解析；解析不到就保持缺席，不炸页面。
  final OnlineMangaLibraryService? service;

  final String? sourceLabel;

  /// 未入库时怎么画封面。
  ///
  /// 入库后封面走本地落盘那张（作品页首屏不该依赖网络）；但**还没入库**时本地
  /// 什么都没有，只能由来源自己提供取图控件——Mihon 要经扩展的 imageProxy 带鉴权
  /// 头，Aidoku 是普通 https + referer，两者的取图方式没有公共分母。作品页因此
  /// 不自己开取图路径，只留这个口子。
  final Widget Function(BuildContext context)? remoteCoverBuilder;
}

/// 漫画作品页。
///
/// 这一层在 v88 前**根本不存在**：书架点开漫画直接钻进 `MangaFushiPage` 的某一
/// 章，而那一章由 `currentChapterIndex` 决定、第一次开书就被钉死成最旧的一话。
/// 于是「加入书架后只能看第一章」——章节列表明明已经完整存在
/// `sourceMetadata` 里，却没有任何界面展示它，唯一的章节列表藏在
/// 发现→来源→搜索→详情 的深处，而那个页面构造需要源上下文，书架够不着。
///
/// 设计要点：
/// - **先离线渲染，再后台刷新**。首屏只读库里的描述符，一次网络调用都不发；
///   刷新失败只在顶部挂一条可重试的提示条，不遮挡任何已有内容。
/// - **与运行时无关**。只跟 [OnlineMangaLibraryService] 打交道，Mihon 和
///   Aidoku 走同一条路径。
/// - **本地卷也进这里**（用户明确要求的一致性）：本地 mokuro 卷没有章节，
///   章节区换成页数/进度，不假装有章节列表。
class MangaSeriesPage extends ConsumerStatefulWidget {
  const MangaSeriesPage({
    required this.target,
    super.key,
    this.ocrEnginesOverride,
    this.lensDisclosureOverride,
  });

  final MangaSeriesTarget target;

  /// 测试缝：「识别本章 / 识别全部已下载」的引擎集合（null = 生产装配
  /// `MangaOcrWizardEngines.resolve`）。
  final MangaOcrWizardEngines? ocrEnginesOverride;

  /// 测试缝：Google Lens 上传同意闸门（null = [ensureGoogleLensDisclosure]）。
  final GoogleLensDisclosureGate? lensDisclosureOverride;

  @override
  ConsumerState<MangaSeriesPage> createState() => _MangaSeriesPageState();
}

class _MangaSeriesPageState extends ConsumerState<MangaSeriesPage> {
  EpubBookRow? _row;
  OnlineMangaLibraryEntry? _entry;
  OnlineMangaLibraryService? _service;
  OnlineMangaRuntimeAdapter? _adapter;
  Map<String, MangaChapterStateRow> _states =
      const <String, MangaChapterStateRow>{};
  String? _sourceLabel;

  bool _loading = true;
  bool _refreshing = false;

  /// 至少成功从源刷过一次。空章节列表的语言解释只在这之后出现：进页那一刻的
  /// seed 本来就是空的，那时提示「该源只收录 X 语言」是把「还没拉」说成「拉完了
  /// 没有」。
  bool _refreshSucceeded = false;
  bool _busy = false;
  Object? _fatalError;
  OnlineMangaUnavailable? _refreshError;
  Future<void> Function()? _challengeRetry;

  bool _newestFirst = true;
  bool _unreadOnly = false;

  /// 下载状态位（设计稿 2026-09-12 §5）：任务行 + 磁盘判据，两份合成章节行上
  /// 的一个状态。任务表一变就整体重算。
  Map<String, MangaDownloadJobRow> _jobs =
      const <String, MangaDownloadJobRow>{};
  Set<String> _downloaded = const <String>{};
  StreamSubscription<void>? _jobsWatch;

  /// OCR 进度（BUG-2481）：注册表的「任务集合变了」信号 + 当前任务的事件流。
  /// 页面只观察，不拥有任务（所有权在注册表，BUG-2449）。
  StreamSubscription<void>? _ocrChangesWatch;
  StreamSubscription<MangaOcrBackgroundEvent>? _ocrEventsWatch;
  MangaOcrRunningJob? _ocrJob;
  MangaOcrBackgroundEvent? _ocrEvent;
  List<String> _ocrQueued = const <String>[];
  String? _bookDir;

  AppModel get _appModel => ref.read(appProvider);

  Widget _challengeAction(Object? error) => MihonCloudflareAction(
    runtime: switch (_adapter) {
      MihonLibraryAdapter(:final manager) => manager.runtime,
      _ => null,
    },
    error: error,
    onVerified: () => (_challengeRetry ?? _refreshFromSource)(),
  );

  /// 取 AppModel，取不到返回 null。
  ///
  /// 源浏览进来的作品页可以活在没有 `ProviderScope` 的树里（widget 测试就是这么
  /// 立起来的），而它展示所需的一切都在 target 的 adapter 里。所以「拿不到
  /// AppModel」是一种**正常状态**，不是错误：只是不能碰书架而已。
  AppModel? get _appModelOrNull {
    try {
      return ref.read(appProvider);
    } on Object {
      return null;
    }
  }

  /// 书架半边，按需解析。解析不到就一直是 null，页面照常展示。
  OnlineMangaLibraryService? _shelfServiceFor(OnlineMangaLibraryEntry entry) {
    final OnlineMangaLibraryService? existing = _service;
    if (existing != null) return existing;
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return null;
    try {
      return _service = appModel.onlineMangaLibraryService(entry.runtime);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.resolveService',
        error,
        stack,
      );
      return null;
    }
  }

  /// 在库时的 bookKey；未入库的源条目为 null。
  String? get _bookKey => _row?.bookKey;

  String? get _bookUid {
    final String? uid = _row?.uid;
    return uid == null || uid.isEmpty ? null : uid;
  }

  /// 本地卷（无在线描述符）。
  bool get _isLocal => _entry == null && _row != null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_jobsWatch?.cancel());
    _jobsWatch = null;
    unawaited(_ocrChangesWatch?.cancel());
    unawaited(_ocrEventsWatch?.cancel());
    super.dispose();
  }

  /// 首次拿到 bookKey 后挂上注册表；之后任务起停都会把页面重新对到当前任务。
  void _watchOcr(String bookKey) {
    if (_ocrChangesWatch != null) return;
    final MangaOcrJobRegistry registry = ref.read(mangaOcrJobRegistryProvider);
    _ocrChangesWatch = registry.changes.listen((_) => _syncOcrJob(bookKey));
    _syncOcrJob(bookKey);
  }

  void _syncOcrJob(String bookKey) {
    if (!mounted) return;
    final MangaOcrJobRegistry registry = ref.read(mangaOcrJobRegistryProvider);
    final MangaOcrRunningJob? job = registry.running(bookKey);
    final List<String> queued = registry.queuedDirectories(bookKey);
    if (!identical(job, _ocrJob)) {
      unawaited(_ocrEventsWatch?.cancel());
      _ocrEventsWatch = job?.events.listen(
        (MangaOcrBackgroundEvent event) {
          if (mounted) setState(() => _ocrEvent = event);
        },
        onError: (Object _, StackTrace __) => _syncOcrJob(bookKey),
        onDone: () => _syncOcrJob(bookKey),
      );
      _ocrEvent = job?.lastEvent;
    }
    setState(() {
      _ocrJob = job;
      _ocrQueued = queued;
    });
  }

  /// 任务目录 → 章节 key（任务只认目录，章节行只认 key）。
  String? _chapterKeyForDirectory(String directory) {
    final String? bookDir = _bookDir;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (bookDir == null || entry == null) return null;
    for (final OnlineMangaChapter chapter in entry.chapters) {
      if (p.equals(
        mangaChapterDirectory(bookDir, chapter.key).path,
        directory,
      )) {
        return chapter.key;
      }
    }
    return null;
  }

  Set<String> get _ocrQueuedChapterKeys => <String>{
    for (final String directory in _ocrQueued)
      if (_chapterKeyForDirectory(directory) case final String key) key,
  };

  String? get _ocrRunningChapterKey {
    final MangaOcrRunningJob? job = _ocrJob;
    if (job == null) return null;
    return _chapterKeyForDirectory(job.job.managedDirectory);
  }

  Future<void> _cancelOcr() async {
    final String? bookKey = _bookKey;
    if (bookKey == null) return;
    await ref.read(mangaOcrJobRegistryProvider).cancel(bookKey);
  }

  /// 识别进度横幅：当前章 + 页进度 + 排队数 + 取消。没任务、没排队时不出现。
  Widget? _buildOcrBanner(BuildContext context) {
    final MangaOcrRunningJob? job = _ocrJob;
    final int queuedCount = _ocrQueued.length;
    if (job == null && queuedCount == 0) return null;
    final ThemeData theme = Theme.of(context);
    final MangaOcrBackgroundEvent? event = _ocrEvent;
    final int done = event?.pagesDone ?? 0;
    final int total = event?.pagesTotal ?? 0;
    final String? runningKey = _ocrRunningChapterKey;
    final OnlineMangaChapter? running = runningKey == null
        ? null
        : _entry?.chapters.cast<OnlineMangaChapter?>().firstWhere(
            (OnlineMangaChapter? chapter) => chapter?.key == runningKey,
            orElse: () => null,
          );
    final List<String> lines = <String>[
      if (job != null)
        t.manga_series_ocr_running(
          chapter: running == null ? '' : mangaChapterDisplayName(running),
          done: '$done',
          total: '$total',
        ),
      if (queuedCount > 0) t.manga_series_ocr_queued_count(count: queuedCount),
    ];
    return FushiCard(
      key: const ValueKey<String>('manga_series_ocr_banner'),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(lines.join(' · '), style: theme.textTheme.bodyMedium),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: job == null || total <= 0 ? null : done / total,
                ),
              ],
            ),
          ),
          if (job != null)
            IconButton(
              key: const ValueKey<String>('manga_series_ocr_cancel'),
              tooltip: t.dialog_cancel,
              onPressed: () => unawaited(_cancelOcr()),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }

  /// 重算下载状态位并（首次）订阅任务表。只对在库条目有意义：未入库的作品既没有
  /// 任务也没有章目录。
  Future<void> _refreshDownloadState() async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (row == null || entry == null || appModel == null) return;
    final MangaDownloadService downloads = appModel.mangaDownloadService;
    _jobsWatch ??= downloads.watchJobs().listen(
      (_) => unawaited(_refreshDownloadState()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaSeriesPage.watchDownloads',
          error,
          stack,
        );
      },
    );
    final Map<String, MangaDownloadJobRow> jobs = await downloads.jobsForBook(
      row.bookKey,
    );
    final String bookDir = await MangaStorage.bookPath(row.bookKey);
    final Set<String> downloaded = await downloadedChapterKeys(
      bookDir,
      entry.chapters.map((OnlineMangaChapter chapter) => chapter.key),
    );
    if (!mounted) return;
    setState(() {
      _jobs = jobs;
      _downloaded = downloaded;
      _bookDir = bookDir;
    });
    _watchOcr(row.bookKey);
  }

  Future<void> _enqueueChapter(OnlineMangaChapter chapter) async {
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null) return;
    try {
      await appModel.mangaDownloadService.enqueueChapter(
        entry: entry,
        chapter: chapter,
        autoOcr: appModel.mangaDownloadAutoOcr,
      );
      if (mounted) FushiToast.show(msg: t.manga_chapter_download_queued);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.enqueue', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
    await _refreshDownloadState();
  }

  Future<void> _retryChapterDownload(OnlineMangaChapter chapter) async {
    final MangaDownloadJobRow? job = _jobs[chapter.key];
    final AppModel? appModel = _appModelOrNull;
    if (job == null || appModel == null) return;
    await appModel.mangaDownloadService.retry(job.jobId);
    await _refreshDownloadState();
  }

  Future<void> _deleteChapterDownload(OnlineMangaChapter chapter) async {
    final EpubBookRow? row = _row;
    if (row == null) return;
    try {
      await deleteChapterDownload(
        await MangaStorage.bookPath(row.bookKey),
        chapter.key,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.deleteDownload',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
    await _refreshDownloadState();
  }

  /// 「下载全部」：未下载且没有排队 / 执行中任务的章按章序（旧 → 新）入队。
  /// 已下载、已在队列里的不重复入队；一章都没有可下的就说清楚。
  Future<void> _downloadAll() async {
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null || _bookKey == null) return;
    // 锁定章（未登录 / 未购买）入队必败，整批跳过并说清楚跳了几个；用户登录并
    // 刷新后它们会脱锁，再点一次即可（BUG-2479）。
    int lockedSkipped = 0;
    final List<OnlineMangaChapter> pending = <OnlineMangaChapter>[];
    for (final OnlineMangaChapter chapter in entry.chapters.reversed) {
      if (_downloaded.contains(chapter.key) || _isChapterPending(chapter)) {
        continue;
      }
      if (chapter.locked) {
        lockedSkipped++;
        continue;
      }
      pending.add(chapter);
    }
    if (lockedSkipped > 0) {
      FushiToast.show(
        msg: t.manga_series_download_all_locked_skipped(count: lockedSkipped),
      );
    }
    if (pending.isEmpty) {
      if (lockedSkipped == 0) {
        FushiToast.show(msg: t.manga_series_download_all_none);
      }
      return;
    }
    try {
      await appModel.mangaDownloadService.enqueueChapters(
        entry: entry,
        chapters: pending,
        autoOcr: appModel.mangaDownloadAutoOcr,
      );
      if (mounted) {
        FushiToast.show(
          msg: t.manga_series_download_all_queued(count: pending.length),
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.downloadAll', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
    await _refreshDownloadState();
  }

  /// 点了锁定章：源站要登录并购买 / 租借才给页。弹窗给三条路——登录该源、
  /// 仍然下载（用户确信自己已解锁、只是列表没刷新）、取消。
  ///
  /// 返回 true = 继续入队下载。选「登录」时登录完自动刷新章节列表（锁位跟着
  /// 变），本次不入队。
  Future<bool> _promptLockedChapter(OnlineMangaChapter chapter) async {
    // 按章问「登录能不能解开」，不是按源：能登录的源也有登录后照样读不了的章
    // （BUG-2514 quirk 章），那时不给「登录」按钮、提示改成说清楚。
    final OnlineMangaLibraryEntry? entry = _entry;
    final OnlineMangaLoginTarget? login = switch (_adapter) {
      OnlineMangaLoginCapable(:final loginTargetForChapter)
          when entry != null =>
        loginTargetForChapter(entry, chapter),
      _ => null,
    };
    final bool loginUnavailable = login == null && _loginTarget != null;
    if (!mounted) return false;
    final _LockedChapterChoice?
    choice = await showAppDialog<_LockedChapterChoice>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        key: const ValueKey<String>('manga_chapter_locked_dialog'),
        title: Text(t.manga_chapter_locked_title),
        content: Text(
          '${chapter.name}\n\n'
          '${loginUnavailable ? t.manga_chapter_locked_login_unsupported_hint : t.manga_chapter_locked_hint}',
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () =>
                Navigator.pop(dialogContext, _LockedChapterChoice.download),
            child: Text(t.manga_chapter_locked_download_anyway),
          ),
          if (login != null)
            KeyedSubtree(
              key: const ValueKey<String>('manga_chapter_locked_login'),
              child: adaptiveDialogAction(
                context: dialogContext,
                isDefaultAction: true,
                onPressed: () =>
                    Navigator.pop(dialogContext, _LockedChapterChoice.login),
                child: Text(t.mihon_source_login),
              ),
            ),
        ],
      ),
    );
    switch (choice) {
      case _LockedChapterChoice.download:
        return true;
      case _LockedChapterChoice.login:
        if (login != null) await _loginToSource(login);
        return false;
      case null:
        return false;
    }
  }

  /// 当前条目所属源的登录目标；适配器没这条流程（Aidoku / 互联对端）或源不接受
  /// 浏览器登录时为 null——AppBar 的登录按钮与锁章弹窗的「登录」项共用这一判据。
  OnlineMangaLoginTarget? get _loginTarget {
    final OnlineMangaLibraryEntry? entry = _entry;
    return switch (_adapter) {
      OnlineMangaLoginCapable(:final loginTarget) when entry != null =>
        loginTarget(entry),
      _ => null,
    };
  }

  /// 空章节列表的语言解释（BUG-2510）：只在「刷新成功结束、0 话」时给。刷新
  /// 途中是加载态、失败有提示条，那两种情况下都不该出现「该源只收录 X 语言」。
  OnlineMangaSourceLanguageScope? get _languageScope {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null ||
        entry.chapters.isNotEmpty ||
        _refreshing ||
        !_refreshSucceeded ||
        _refreshError != null) {
      return null;
    }
    return switch (_adapter) {
      OnlineMangaLanguageScoped(:final languageScope) => languageScope(entry),
      _ => null,
    };
  }

  /// 同一部作品换到同扩展的另一语言源看：开一页新的作品页，不动本页与书架状态
  /// （用户在那页决定要不要把那个源的版本加进书架）。
  Future<void> _openSiblingSource(OnlineMangaSiblingSource sibling) async {
    // 声明成 Object?：OnlineMangaLanguageScoped 不是 OnlineMangaRuntimeAdapter
    // 的子类型，`is!` 对 `OnlineMangaRuntimeAdapter?` 局部变量不提升。
    final Object? adapter = _adapter;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (adapter is! OnlineMangaLanguageScoped || entry == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    final ({OnlineMangaRuntimeAdapter adapter, OnlineMangaLibraryEntry seed})
    handle;
    try {
      handle = await adapter.siblingOf(entry, sibling);
    } on OnlineMangaUnavailable catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.sibling', error, stack);
      if (mounted) {
        FushiToast.show(msg: error.message, severity: ToastSeverity.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaSeriesPage(
          target: SourceMangaSeriesTarget(
            adapter: handle.adapter,
            seed: handle.seed,
            service: _service,
            sourceLabel: sibling.name,
            // 封面照本页的画法（本地落盘那张 / 源代理取图）：同一部作品、同一个
            // 扩展，取图路径一样，本页还压在导航栈里没销毁。
            remoteCoverBuilder: _buildCover,
          ),
          ocrEnginesOverride: widget.ocrEnginesOverride,
          lensDisclosureOverride: widget.lensDisclosureOverride,
        ),
      ),
    );
  }

  Future<void> _loginToSource(OnlineMangaLoginTarget target) async {
    final bool saved = await openMihonWebLogin(
      context,
      runtime: target.runtime,
      sourceName: target.sourceName,
      baseUrl: target.baseUrl,
    );
    if (!mounted || !saved) return;
    FushiToast.show(msg: t.mihon_source_login_saved);
    // 登录态变了，章节的锁位跟着变：立刻从源重取，用户不用自己想到去点刷新。
    await _refreshFromSource();
  }

  bool _isChapterPending(OnlineMangaChapter chapter) {
    final String? status = _jobs[chapter.key]?.status;
    return status == MangaDownloadJobStatus.queued ||
        status == MangaDownloadJobStatus.running;
  }

  Future<void> _setAutoOcr(bool value) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return;
    await appModel.setMangaDownloadAutoOcr(value);
    if (mounted) setState(() {});
  }

  /// 「识别本章」：已下载的章目录排一个整卷 OCR 任务（阅读器外触发，设计稿 §1.3）。
  ///
  /// 已有识别结果的章 = **重新识别**（丢掉逐页缓存重跑）；还没结果的章沿用缓存
  /// 续跑。此前不分这两种，模型没换时整卷缓存命中直接回放旧结果，用户点了
  /// 「识别本章」什么都不会变。
  ///
  /// 引擎解析与向导 / 下载钩子共用同一份探测（`manga_ocr_engine_probe.dart`）；
  /// 与后台钩子的差别只有「用户在场」：Lens 可以选，但要先过一次上传同意闸门。
  /// 任务经 `MangaOcrJobRegistry.enqueue` 按 bookKey 排队（BUG-2449 所有权 +
  /// 同书 FIFO），作品页只负责起任务，阅读器按 bookKey + 目录接回进度。
  Future<void> _ocrChapter(OnlineMangaChapter chapter) async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (row == null || entry == null || _busy) return;
    final String bookDir = await MangaStorage.bookPath(row.bookKey);
    if (!await isChapterDownloaded(bookDir, chapter.key)) return;
    final int queued = await _enqueueChapterOcr(
      entry,
      row,
      <OnlineMangaChapter>[chapter],
      // 只有「确实已有识别结果」才丢缓存重跑；没结果或 manga.json 读不出都续跑
      // ——读不出的坏文件不该被整章重跑悄悄覆盖。
      onlyMissing: await _chapterOcrState(bookDir, chapter.key) !=
          _ChapterOcrState.hasResult,
    );
    if (queued > 0 && mounted) {
      FushiToast.show(msg: t.manga_series_ocr_queued);
    }
  }

  /// 「识别全部已下载」：已下载且章 `manga.json` 里 blocks 全空的章依次排队。
  Future<void> _ocrAllDownloaded() async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (row == null || entry == null || _busy) return;
    final String bookDir = await MangaStorage.bookPath(row.bookKey);
    final List<OnlineMangaChapter> targets = <OnlineMangaChapter>[];
    for (final OnlineMangaChapter chapter in entry.chapters.reversed) {
      if (!_downloaded.contains(chapter.key)) continue;
      if (await _chapterOcrState(bookDir, chapter.key) ==
          _ChapterOcrState.empty) {
        targets.add(chapter);
      }
    }
    if (targets.isEmpty) {
      FushiToast.show(msg: t.manga_series_ocr_all_none);
      return;
    }
    final int queued = await _enqueueChapterOcr(entry, row, targets);
    if (queued > 0 && mounted) {
      FushiToast.show(msg: t.manga_series_ocr_queued);
    }
  }

  /// 章 `manga.json` 的识别状态：一个 block 都没有 = 还没识别过（[empty]）；
  /// 读不出来单独一态（[unreadable]）——坏文件既不排进「识别全部」，也不当作
  /// 「已有结果」去丢缓存重跑。
  static Future<_ChapterOcrState> _chapterOcrState(
    String bookDir,
    String chapterKey,
  ) async {
    try {
      final File json = mangaChapterJsonFile(
        mangaChapterDirectory(bookDir, chapterKey),
      );
      final MokuroPayload payload = parseMangaJson(await json.readAsString());
      final bool empty = payload.images.isNotEmpty &&
          payload.images.every((MokuroImage image) => image.blocks.isEmpty);
      return empty ? _ChapterOcrState.empty : _ChapterOcrState.hasResult;
    } on Object {
      return _ChapterOcrState.unreadable;
    }
  }

  /// 解析引擎（一次），逐章排任务。返回排上的章数；解析不到引擎 / 用户拒绝 Lens
  /// 上传 → 0 并提示。
  Future<int> _enqueueChapterOcr(
    OnlineMangaLibraryEntry entry,
    EpubBookRow row,
    List<OnlineMangaChapter> chapters, {
    bool onlyMissing = true,
  }) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return 0;
    final MangaOcrWizardEngines engines =
        widget.ocrEnginesOverride ??
        MangaOcrWizardEngines.resolve(context: context, db: appModel.database);
    final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
      engines,
    );
    final MangaOcrEnginePreference preference =
        MangaOcrEnginePreferenceKey.fromKey(appModel.mangaOcrEnginePreference);
    final MangaOcrEngineId? engine = resolveMangaOcrEngine(
      preference: preference,
      hasExistingMetadata: false,
      capabilities: availability.capabilities,
    );
    if (!mounted) return 0;
    if (engine == null || !availability.isUsable(engine)) {
      FushiToast.show(
        msg: t.manga_series_ocr_no_engine,
        severity: ToastSeverity.error,
      );
      return 0;
    }
    if (engine == MangaOcrEngineId.googleLens) {
      final GoogleLensDisclosureGate gate =
          widget.lensDisclosureOverride ?? ensureGoogleLensDisclosure;
      if (!await gate(context)) return 0;
      if (!mounted) return 0;
    }
    final MangaOcrJobRegistry registry = ref.read(mangaOcrJobRegistryProvider);
    final String bookDir = await MangaStorage.bookPath(row.bookKey);
    int queued = 0;
    for (final OnlineMangaChapter chapter in chapters) {
      final Directory chapterDir = mangaChapterDirectory(bookDir, chapter.key);
      final MangaOcrJobSpec spec = MangaOcrJobSpec(
        engine: engine,
        engines: engines,
        imageDirPath: chapterDir.path,
        lensLanguage: appModel.mangaOcrLensLanguage,
        onlyMissing: onlyMissing,
        volumeTitle:
            '${entry.series.title} ${mangaChapterDisplayName(chapter)}',
        remoteTarget: availability.remoteTarget,
      );
      // 刻意不 await 启动：同书上一章还在识别时 enqueue 要等它结束。
      unawaited(
        registry.enqueue(
          job: MangaOcrBackgroundJob(
            bookKey: row.bookKey,
            managedDirectory: chapterDir.path,
            engine: engine,
            events: mangaOcrBackgroundEvents(spec),
          ),
          mangaJsonPath: mangaChapterJsonFile(chapterDir).path,
        ),
      );
      queued += 1;
    }
    return queued;
  }

  /// 书签 = 订阅开关：开订阅时默认同时开「新章自动下载」；关订阅把两位一起关
  /// （没有订阅的自动下载没有意义，探针只看 autoDownload）。
  Future<void> _toggleSubscription() async {
    final bool subscribed = !(_entry?.subscribed ?? false);
    await _writeSubscription(subscribed: subscribed, autoDownload: subscribed);
  }

  Future<void> _toggleAutoDownload() async {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return;
    await _writeSubscription(
      subscribed: entry.subscribed,
      autoDownload: !entry.autoDownload,
    );
  }

  Future<void> _writeSubscription({
    required bool subscribed,
    required bool autoDownload,
  }) async {
    final OnlineMangaLibraryService? service = _service;
    final OnlineMangaLibraryEntry? entry = _entry;
    final String? bookKey = _bookKey;
    if (service == null || entry == null || bookKey == null || _busy) return;
    try {
      final OnlineMangaLibraryEntry updated = await service.setSubscription(
        bookKey: bookKey,
        entry: entry,
        subscribed: subscribed,
        autoDownload: autoDownload,
      );
      if (mounted) setState(() => _entry = updated);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.subscribe', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  Future<void> _load() async {
    try {
      switch (widget.target) {
        case ShelfMangaSeriesTarget(:final String bookKey):
          await _loadFromShelf(bookKey);
        case SourceMangaSeriesTarget(
          :final OnlineMangaRuntimeAdapter adapter,
          :final OnlineMangaLibraryService? service,
          :final OnlineMangaLibraryEntry seed,
          :final String? sourceLabel,
        ):
          await _loadFromSource(adapter, service, seed, sourceLabel);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.load', error, stack);
      if (mounted) setState(() => _fatalError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFromShelf(String bookKey) async {
    final EpubBookRow? row = await _appModel.database.getEpubBook(bookKey);
    if (row == null) {
      throw StateError('The book is no longer in the library: $bookKey');
    }
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    // 服务解析失败（平台不支持等）不该挡住离线渲染——章节列表已经在描述符里
    // 了，用户至少要能看见自己书架里有什么。
    final OnlineMangaLibraryService? service = entry == null
        ? null
        : _shelfServiceFor(entry);
    final Map<String, MangaChapterStateRow> states = await _readChapterStates(
      row,
    );
    if (!mounted) return;
    setState(() {
      _row = row;
      _entry = entry;
      _service = service;
      _adapter = service?.adapter;
      _states = states;
    });
    if (entry != null && service != null) {
      unawaited(_resolveSourceLabel(service.adapter, entry));
      unawaited(_refreshFromSource(silent: true));
    }
    unawaited(_refreshDownloadState());
  }

  Future<void> _loadFromSource(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaLibraryService? service,
    OnlineMangaLibraryEntry seed,
    String? sourceLabel,
  ) async {
    // 已经入过库就直接切成书架条目：同一部作品不该因为「从哪进来的」而显示成
    // 两种状态（在库的那份有已读标记，seed 那份没有）。
    //
    // 书架半边可能整个缺席（没有 AppModel 的树里），那时就当「不在库」处理——
    // 展示照旧，只是入库按钮不可用。
    final OnlineMangaLibraryService? shelf = service ?? _shelfServiceFor(seed);
    EpubBookRow? existing;
    if (shelf != null) {
      try {
        existing = await shelf.find(seed);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log('MangaSeriesPage.find', error, stack);
      }
    }
    final OnlineMangaLibraryEntry entry = existing == null
        ? seed
        : OnlineMangaLibraryEntry.tryParse(existing.sourceMetadata) ?? seed;
    final Map<String, MangaChapterStateRow> states = existing == null
        ? const <String, MangaChapterStateRow>{}
        : await _readChapterStates(existing);
    if (!mounted) return;
    setState(() {
      _row = existing;
      _entry = entry;
      _adapter = adapter;
      _service = shelf;
      _sourceLabel = sourceLabel;
      _states = states;
    });
    unawaited(_refreshFromSource(silent: true));
    unawaited(_refreshDownloadState());
  }

  Future<Map<String, MangaChapterStateRow>> _readChapterStates(
    EpubBookRow row,
  ) async {
    if (row.uid.isEmpty) return const <String, MangaChapterStateRow>{};
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return const <String, MangaChapterStateRow>{};
    return appModel.database.getMangaChapterStates(row.uid);
  }

  Future<void> _resolveSourceLabel(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaLibraryEntry entry,
  ) async {
    final String? label = await adapter.sourceLabel(entry);
    if (mounted && label != null) setState(() => _sourceLabel = label);
  }

  /// 联网刷新作品详情 + 章节列表。
  ///
  /// [silent] = 进页时的自动刷新：失败只挂提示条，不弹 toast。用户手点刷新时
  /// 反过来——他在等一个明确回应。
  Future<void> _refreshFromSource({bool silent = false}) async {
    _challengeRetry = null;
    final OnlineMangaRuntimeAdapter? adapter = _adapter;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (adapter == null || entry == null || _refreshing) return;
    if (!adapter.isSupportedOnThisPlatform) {
      if (mounted) {
        setState(
          () => _refreshError = const OnlineMangaUnavailable(
            OnlineMangaUnavailableReason.platformUnsupported,
            'This manga runtime is not available on this platform',
          ),
        );
      }
      return;
    }
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      final String? bookKey = _bookKey;
      final OnlineMangaLibraryService? service = _service;
      if (bookKey == null || service == null) {
        // 未入库（或够不着书架）：只拉，不落库。
        final OnlineMangaRefreshResult result = await adapter.refresh(entry);
        if (!mounted) return;
        setState(() {
          _entry = entry.copyWith(
            series: result.series,
            chapters: result.chapters,
          );
          _refreshSucceeded = true;
        });
        return;
      }
      final OnlineMangaLibraryEntry updated = await service.refreshFromSource(
        bookKey: bookKey,
        entry: entry,
      );
      final EpubBookRow? row = await service.database.getEpubBook(bookKey);
      if (!mounted) return;
      setState(() {
        _entry = updated;
        if (row != null) _row = row;
        _refreshSucceeded = true;
      });
    } on OnlineMangaUnavailable catch (error, stack) {
      // 这条**才是**在线漫画的主流失败路径：adapter 已经把 Mihon/Aidoku 的运行时
      // 与网络异常全包成了 OnlineMangaUnavailable，兜底的 `on Object` 基本收不到
      // 东西。不在这里记，用户报「漫画刷不出来」时事后捞日志就是空的。
      ErrorLogService.instance.log(
        'MangaSeriesPage.refresh[${error.reason.name}]',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() => _refreshError = error);
      if (!silent) {
        FushiToast.show(msg: error.message, severity: ToastSeverity.error);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.refresh', error, stack);
      if (!mounted) return;
      final OnlineMangaUnavailable wrapped = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
      );
      setState(() => _refreshError = wrapped);
      if (!silent) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _addToLibrary() async {
    final OnlineMangaLibraryService? service = _service;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (service == null || entry == null || _busy || _row != null) return;
    setState(() => _busy = true);
    try {
      final EpubBookRow row = await service.add(entry);
      if (!mounted) return;
      setState(() {
        _row = row;
        _entry = OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? entry;
      });
      unawaited(_refreshDownloadState());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.add', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 移出书架 = 删这本书（DB 行 + 解压目录里已下载的章节 + 章节状态 + 下载
  /// 任务行，`deleteEpubBook` 一个事务级联）。与书架长按删除同一条路径，不另起
  /// 一套「只摘条目留文件」的半删除——那会留下没人引用的下载目录。
  ///
  /// 删完页面**不关**、退回「未入库」态：条目本身（作品 + 章节列表）还在手上，
  /// 用户可以立刻重新加入或换源；关页面反而把他丢回不知道哪一层的列表。
  Future<void> _removeFromLibrary() async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (row == null || entry == null || appModel == null || _busy) return;
    final DeleteDecision? decision = await _confirmRemoveFromLibrary(appModel);
    if (decision == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // 先停引用再销毁实体：正在识别 / 下载这本书的任务还握着目录句柄。OCR 连排队
      // 的一起放弃；下载用 remove（等正在飞的那个真停）而不是 cancel（只置标志
      // 就返回，worker 还在往目录里写页，随后的目录删除会撞 errno 32 留孤儿）。
      // 任务行随后由 deleteEpubBook 级联删，这里删掉也无妨。
      await _cancelOcr();
      final MangaDownloadService downloads = appModel.mangaDownloadService;
      final Map<String, MangaDownloadJobRow> jobs = await downloads.jobsForBook(
        row.bookKey,
      );
      for (final MangaDownloadJobRow job in jobs.values) {
        if (job.status == MangaDownloadJobStatus.queued ||
            job.status == MangaDownloadJobStatus.running) {
          await downloads.remove(job.jobId);
        }
      }
      final DeleteBookResult result = await ReaderFushiSource.instance
          .deleteBook(
            db: appModel.database,
            bookKey: row.bookKey,
            scope: decision.scope,
          );
      if (!mounted) return;
      if (!result.deleted) {
        final String reason = result.failureReason ?? '';
        FushiToast.show(
          msg: reason.isEmpty
              ? t.epub_delete_error
              : '${t.epub_delete_error}: $reason',
          severity: ToastSeverity.error,
        );
        return;
      }
      setState(() {
        _row = null;
        _states = const <String, MangaChapterStateRow>{};
        _downloaded = const <String>{};
        _jobs = const <String, MangaDownloadJobRow>{};
        // 丢掉三样只属于「在库」的状态：当前章、订阅、自动下载。
        _entry = entry.copyWith(
          clearCurrentChapter: true,
          subscribed: false,
          autoDownload: false,
        );
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.remove', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 与书架长按删除同一个确认框（披露 + 「同步删除」范围 + 记住选择），删除
  /// 传播语义因此一致：用户选了同步删除，对端也跟着删。
  Future<DeleteDecision?> _confirmRemoveFromLibrary(AppModel appModel) async {
    final bool canSyncEverywhere = await hasDeletionPropagationChannel(
      SyncRepository(appModel.database),
    );
    final DeletePromptPreferenceStore preferenceStore =
        DeletePromptPreferenceStore(appModel.database);
    final DeletePromptRememberedChoices? rememberedChoices =
        await preferenceStore.load();
    if (!mounted) return null;
    return showAppDialog<DeleteDecision>(
      context: context,
      builder: (BuildContext ctx) => ReaderHistoryDeleteDialog(
        title: t.manga_series_remove_from_bookshelf,
        message: t.manga_series_remove_confirm,
        disclosure: buildDeletionDisclosure(
          target: DeletionDisclosureTarget.shelfBook,
        ),
        showSyncScope: canSyncEverywhere,
        rememberedChoices: rememberedChoices,
        onPersistChoices: preferenceStore.write,
        onConfirm: (DeleteDecision d) => Navigator.pop(ctx, d),
      ),
    );
  }

  /// 「继续阅读」落到哪一章。
  int get _resumeIndex {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return -1;
    return OnlineMangaLibraryService.resumeChapterIndex(entry, _states);
  }

  /// 点章节：已下载 → 开读；否则入队并提示（设计稿 2026-09-12 §5，在线漫画先
  /// 下载再读）。未入库的先入库——任务表按 bookKey 记，没有行就没地方挂任务。
  Future<void> _openChapterAt(int index) async {
    final OnlineMangaLibraryService? service = _service;
    OnlineMangaLibraryEntry? entry = _entry;
    if (service == null || entry == null || _busy) return;
    if (index < 0 || index >= entry.chapters.length) return;
    setState(() => _busy = true);
    try {
      String? bookKey = _bookKey;
      if (bookKey == null) {
        // 从源里直接点章：先入库再读，否则进度、已读标记、断点续读全都无处可落。
        final EpubBookRow row = await service.add(entry);
        entry = OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? entry;
        bookKey = row.bookKey;
        if (!mounted) return;
        setState(() {
          _row = row;
          _entry = entry;
        });
      }
      final OnlineMangaChapter chapter = entry.chapters[index];
      final String bookDir = await MangaStorage.bookPath(bookKey);
      if (!await isChapterDownloaded(bookDir, chapter.key)) {
        if (chapter.locked && !await _promptLockedChapter(chapter)) return;
        await _enqueueChapter(chapter);
        return;
      }
      final OnlineMangaLibraryEntry selected = await service.selectChapter(
        bookKey: bookKey,
        entry: entry,
        chapterIndex: index,
      );
      if (!mounted) return;
      setState(() => _entry = selected);
      await _openReader(bookKey);
      // 从阅读器回来必须重读：读了哪些页、哪章读完了全在阅读器里写的库。
      await _reloadAfterReading();
    } on OnlineMangaUnavailable catch (error, stack) {
      // 同 refresh：开章失败绝大多数落在这一支，不记就等于「漫画打不开」这类
      // 报障永远没有可捞的记录。
      ErrorLogService.instance.log(
        'MangaSeriesPage.openChapter[${error.reason.name}]',
        error,
        stack,
      );
      if (mounted) {
        _challengeRetry = () => _openChapterAt(index);
        setState(() => _refreshError = error);
        FushiToast.show(msg: error.message, severity: ToastSeverity.error);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.openChapter', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLocalBook() async {
    final String? bookKey = _bookKey;
    if (bookKey == null) return;
    await _openReader(bookKey);
    await _reloadAfterReading();
  }

  /// 开阅读器。
  ///
  /// **必须走 `openMedia`**，不能自己 `Navigator.push` 一个 `MangaFushiPage`：
  /// 沉浸模式、wakelock、audio handler 预热、`_currentMediaSource`、历史记账
  /// 全在 `openMedia` 里。v88 前书架是直接 `openMedia` 开阅读器的，作品页插在
  /// 中间后，这些副作用必须原样跟着阅读器走，否则漫画会静默丢掉一整套会话行为。
  ///
  /// `MangaFushiSource.buildLaunchPage` 仍然返回阅读器（不是作品页），所以这里
  /// 不会自我递归。
  Future<void> _openReader(String bookKey) async {
    MediaItem? item = switch (widget.target) {
      ShelfMangaSeriesTarget(:final MediaItem? item) => item,
      SourceMangaSeriesTarget() => null,
    };
    item ??= await ReaderFushiSource.instance.mediaItemForBookKey(bookKey);
    if (!mounted) return;
    if (item == null) {
      // 条目刚入库、MediaItem 还建不出来（不该发生）：退回直接开阅读器，
      // 宁可少一层会话副作用，也不能让「点了没反应」。
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) => FushiAppUiScaleNeutralizer(
            child: MangaFushiPage(item: null, bookKey: bookKey),
          ),
        ),
      );
      return;
    }
    await _appModel.openMedia(
      ref: ref,
      mediaSource: MangaFushiSource.instance,
      item: item,
    );
  }

  /// 本地卷的整卷 OCR：阅读器内已不再触发 OCR（BUG-2461），作品页是本地漫画唯一的
  /// 入口。向导只负责选参数并交回冷任务，真正的所有权在 app 级注册表
  /// （BUG-2449）——从这里离开、进阅读器、再返回，任务照跑，阅读器按 bookKey 接回。
  Future<void> _runLocalBookOcr() async {
    final EpubBookRow? row = _row;
    if (row == null || _busy) return;
    final MangaOcrJobRegistry registry = ref.read(mangaOcrJobRegistryProvider);
    if (registry.running(row.bookKey) != null) {
      FushiToast.show(
        msg: t.manga_ocr_wizard_running,
        severity: ToastSeverity.info,
      );
      return;
    }
    final MangaOcrBackgroundJob? job = await MangaModule.openBookOcr(
      context: context,
      db: _appModel.database,
      book: row,
      startPage: 0,
    );
    if (!mounted || job == null) return;
    registry.start(
      job: job,
      mangaJsonPath: p.join(row.extractDir, row.epubPath),
    );
    FushiToast.show(
      msg: t.manga_ocr_wizard_running,
      severity: ToastSeverity.info,
    );
  }

  Future<void> _reloadAfterReading() async {
    final String? bookKey = _bookKey;
    if (bookKey == null || !mounted) return;
    final EpubBookRow? row = await _appModel.database.getEpubBook(bookKey);
    if (row == null || !mounted) return;
    final Map<String, MangaChapterStateRow> states = await _readChapterStates(
      row,
    );
    if (!mounted) return;
    setState(() {
      _row = row;
      _entry = OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? _entry;
      _states = states;
    });
    unawaited(_refreshDownloadState());
  }

  Future<void> _toggleChapterRead(OnlineMangaChapter chapter) async {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    final MangaChapterStateRow? state = _states[chapter.key];
    if (state?.readAt != null) {
      await _appModel.database.clearMangaChapterRead(
        bookUid: bookUid,
        chapterKey: chapter.key,
      );
    } else {
      await _appModel.database.markMangaChaptersRead(
        bookUid: bookUid,
        chapterKeys: <String>[chapter.key],
      );
    }
    await _reloadChapterStates();
  }

  /// 标记「这一章及更早的全部」为已读。
  ///
  /// 「更早」= 列表里**它之后**的所有章：源按新→旧返回，所以下标越大越旧。
  Future<void> _markUpToRead(OnlineMangaChapter chapter) async {
    final String? bookUid = _bookUid;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (bookUid == null || entry == null) return;
    final int index = entry.indexOfChapterKey(chapter.key);
    if (index < 0) return;
    await _appModel.database.markMangaChaptersRead(
      bookUid: bookUid,
      chapterKeys: <String>[
        for (int i = index; i < entry.chapters.length; i++)
          entry.chapters[i].key,
      ],
    );
    await _reloadChapterStates();
  }

  Future<void> _reloadChapterStates() async {
    final EpubBookRow? row = _row;
    if (row == null || !mounted) return;
    final Map<String, MangaChapterStateRow> states = await _readChapterStates(
      row,
    );
    if (mounted) setState(() => _states = states);
  }

  // ── 渲染 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final OnlineMangaLibraryEntry? entry = _entry;
    final String title = entry?.series.title ?? _row?.title ?? t.manga_library;
    final bool canSubscribe = entry != null && _row != null && _service != null;
    final OnlineMangaLoginTarget? login = _loginTarget;
    return FushiPageScaffold(
      title: title,
      subtitle: _subtitle(),
      actions: <Widget>[
        // 源站要登录才给锁章（BUG-2497）：入口放在用户看到「锁」的这一页，
        // 不必先点一条锁章再从弹窗里找。
        if (login != null)
          IconButton(
            key: const ValueKey<String>('manga_series_login'),
            tooltip: t.mihon_source_login,
            onPressed: _busy || _refreshing
                ? null
                : () => unawaited(_loginToSource(login)),
            icon: const Icon(Icons.login),
          ),
        if (canSubscribe)
          IconButton(
            key: const ValueKey<String>('manga_series_subscribe'),
            tooltip: entry.subscribed
                ? t.manga_series_unsubscribe
                : t.manga_series_subscribe,
            onPressed: _busy ? null : () => unawaited(_toggleSubscription()),
            icon: Icon(
              entry.subscribed ? Icons.bookmark : Icons.bookmark_add_outlined,
            ),
          ),
        if (entry != null)
          IconButton(
            key: const ValueKey<String>('manga_series_refresh'),
            tooltip: t.manga_series_refresh,
            onPressed: _refreshing
                ? null
                : () => unawaited(_refreshFromSource()),
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        if (canSubscribe && entry.subscribed)
          FushiOverflowMenu<String>(
            key: const ValueKey<String>('manga_series_more'),
            items: <PopupMenuEntry<String>>[
              FushiPopupMenuItem<String>(
                key: const ValueKey<String>('manga_series_auto_download'),
                value: 'auto-download',
                label: t.manga_series_auto_download,
                icon: entry.autoDownload
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                selected: entry.autoDownload,
              ),
            ],
            onSelected: (String value) {
              if (value == 'auto-download') unawaited(_toggleAutoDownload());
            },
          ),
      ],
      body: _buildBody(context),
    );
  }

  String? _subtitle() {
    if (_isLocal) return t.manga_series_local_volume;
    final String? label = _sourceLabel;
    if (label != null && label.isNotEmpty) return label;
    return _entry?.extensionPackage;
  }

  /// 页面上是不是一点内容都没有。
  ///
  /// 未入库 + 一章都没拉到 = 这次是**加载**失败，不是刷新失败。两者要给完全不同
  /// 的界面：有内容时失败只挂一条不遮挡的横幅；什么都没有时必须把真实原因、
  /// 诊断入口和重试摆出来，否则用户只看到一页空白（BUG-1767 的原始症状就是
  /// 「只渲染一行光秃的异常文本，既没重试也拿不到堆栈」）。
  bool get _hasNothingToShow =>
      _row == null && (_entry?.chapters.isEmpty ?? true);

  Widget _buildBody(BuildContext context) {
    if (_loading) return Center(child: adaptiveIndicator(context: context));
    final Object? fatal = _fatalError;
    if (fatal != null) return _buildFatalError(context, fatal);
    final OnlineMangaUnavailable? loadError = _refreshError;
    if (loadError != null && _hasNothingToShow) {
      return _buildLoadError(context, loadError);
    }
    final Widget? ocrBanner = _isLocal ? null : _buildOcrBanner(context);
    return ListView(
      // BUG-2440：scaffold 的 body 不再扣底部安全区，章节列表得自己把这段补进
      // 滚动 padding，否则最后一章静止时压在手势条底下点不到。
      padding: withBottomSafeInset(context, const EdgeInsets.all(16)),
      children: <Widget>[
        if (_refreshError != null) ...<Widget>[
          _buildRefreshBanner(context, _refreshError!),
          const SizedBox(height: 12),
        ],
        _buildHeader(context),
        const SizedBox(height: 16),
        _buildActions(context),
        const SizedBox(height: 24),
        if (ocrBanner != null) ...<Widget>[
          ocrBanner,
          const SizedBox(height: 12),
        ],
        if (_isLocal)
          _buildLocalDetails(context)
        else
          MangaChapterList(
            entry: _entry,
            states: _states,
            newestFirst: _newestFirst,
            unreadOnly: _unreadOnly,
            currentChapterKey: _entry?.currentChapter?.key,
            onSortToggled: () => setState(() => _newestFirst = !_newestFirst),
            onUnreadOnlyToggled: () =>
                setState(() => _unreadOnly = !_unreadOnly),
            onChapterTap: (OnlineMangaChapter chapter) {
              final int index = _entry?.indexOfChapterKey(chapter.key) ?? -1;
              if (index >= 0) unawaited(_openChapterAt(index));
            },
            onToggleRead: _bookUid == null
                ? null
                : (OnlineMangaChapter chapter) =>
                      unawaited(_toggleChapterRead(chapter)),
            onMarkUpToRead: _bookUid == null
                ? null
                : (OnlineMangaChapter chapter) =>
                      unawaited(_markUpToRead(chapter)),
            downloadedChapterKeys: _downloaded,
            jobsByChapterKey: _jobs,
            ocrRunningChapterKey: _ocrRunningChapterKey,
            ocrProgress: _ocrJob == null
                ? null
                : (
                    done: _ocrEvent?.pagesDone ?? 0,
                    total: _ocrEvent?.pagesTotal ?? 0,
                  ),
            ocrQueuedChapterKeys: _ocrQueuedChapterKeys,
            languageScope: _languageScope,
            onSiblingSourceTap: (OnlineMangaSiblingSource sibling) =>
                unawaited(_openSiblingSource(sibling)),
            onDownload: _bookKey == null
                ? null
                : (OnlineMangaChapter chapter) =>
                      unawaited(_enqueueChapter(chapter)),
            onRetryDownload: _bookKey == null
                ? null
                : (OnlineMangaChapter chapter) =>
                      unawaited(_retryChapterDownload(chapter)),
            onDeleteDownload: _bookKey == null
                ? null
                : (OnlineMangaChapter chapter) =>
                      unawaited(_deleteChapterDownload(chapter)),
            onOcr: _bookKey == null
                ? null
                : (OnlineMangaChapter chapter) =>
                      unawaited(_ocrChapter(chapter)),
          ),
      ],
    );
  }

  /// 一点内容都拉不到时的完整错误视图。
  ///
  /// 三件事缺一不可（BUG-1767 用例逐条盯着）：**原因可见**（把桥接层给的
  /// message 原样摆出来，不是一句「加载失败」）、**诊断入口**（原生堆栈和失败
  /// 阶段太长不能铺在页面上，只能进可复制对话框）、**重试真的重发请求**。
  Widget _buildLoadError(BuildContext context, OnlineMangaUnavailable error) {
    final ThemeData theme = Theme.of(context);
    // 源被禁用 / 平台不支持时重试永远不会成功，别给一个骗人的按钮。
    final bool retryable =
        error.reason == OnlineMangaUnavailableReason.runtimeFailure;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.manga_online_detail_load_failed,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText(
              error.message,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                if (retryable)
                  FilledButton(
                    key: const ValueKey<String>('manga_series_error_retry'),
                    onPressed: _refreshing
                        ? null
                        : () => unawaited(_refreshFromSource()),
                    child: Text(t.retry),
                  ),
                _challengeAction(error),
                TextButton(
                  key: const ValueKey<String>('manga_series_error_details'),
                  onPressed: () => unawaited(
                    showErrorDetails(
                      context,
                      title: t.mihon_extension_error,
                      error: error.diagnostics,
                    ),
                  ),
                  child: Text(t.manga_online_error_view_detail),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFatalError(BuildContext context, Object error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            t.manga_online_detail_load_failed,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          SelectableText(
            '$error',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  /// 刷新失败提示条。
  ///
  /// 按 [OnlineMangaUnavailableReason] 分流是有意义的：源被禁用和网络抽风给的
  /// 出路完全不同，把两者都渲染成「加载失败 + 重试」会让用户对着一个永远不会
  /// 成功的按钮反复点。
  Widget _buildRefreshBanner(
    BuildContext context,
    OnlineMangaUnavailable error,
  ) {
    final ThemeData theme = Theme.of(context);
    final (String text, bool retryable) = switch (error.reason) {
      OnlineMangaUnavailableReason.sourceDisabled => (
        t.manga_series_source_disabled,
        false,
      ),
      OnlineMangaUnavailableReason.platformUnsupported => (
        t.manga_series_platform_unsupported,
        false,
      ),
      OnlineMangaUnavailableReason.runtimeFailure => (
        t.manga_series_refresh_failed,
        true,
      ),
    };
    return FushiCard(
      child: Row(
        children: <Widget>[
          Icon(Icons.cloud_off_outlined, color: theme.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(text, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  t.manga_series_offline_hint,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (retryable)
            TextButton(
              onPressed: _refreshing
                  ? null
                  : () => unawaited(_refreshFromSource()),
              child: Text(t.retry),
            ),
          _challengeAction(error),
          TextButton(
            key: const ValueKey<String>('manga_series_error_details'),
            onPressed: () => unawaited(
              showErrorDetails(
                context,
                title: t.manga_online_detail_load_failed,
                error: '${error.reason}\n\n${error.message}',
              ),
            ),
            child: Text(t.manga_online_error_view_detail),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final OnlineMangaSeries? series = _entry?.series;
    final String? description = series?.description?.trim();
    final List<String> genres = series?.genreLabels ?? const <String>[];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 150,
          height: 220,
          child: ClipRRect(
            borderRadius: FushiBorderRadius.poster,
            child: _buildCover(context),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (series?.byline != null)
                Text(series!.byline!, style: theme.textTheme.bodyMedium),
              if (_isLocal && _row?.author != null)
                Text(_row!.author!, style: theme.textTheme.bodyMedium),
              if (genres.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final String genre in genres.take(8))
                      FushiTagChip(label: genre),
                  ],
                ),
              ],
              if (description != null && description.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(description, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 封面。
  ///
  /// 入库条目一律走**本地已落盘**的封面：作品页的首屏不该依赖网络，源挂了封面
  /// 也得在。没有本地封面（刚从源进来还没入库）才回退到占位块——真正的远端取图
  /// 由源浏览页的封面缓存负责，作品页不自己再开一条取图路径。
  Widget _buildCover(BuildContext context) {
    final EpubBookRow? row = _row;
    if (row != null) {
      // 复用书架/制卡那份解析（TODO-1388 / BUG-703），别自己拼路径：coverPath 可能
      // 是相对页图路径、可能大小写与磁盘不符（跨平台备份还原），那些坑都已经在
      // resolveCoverFilePath 里踩过了。
      final String? resolved = ReaderFushiSource.resolveCoverFilePath(
        extractDir: row.extractDir,
        coverPath: row.coverPath,
      );
      if (resolved != null) {
        return Image.file(
          File(resolved),
          fit: BoxFit.cover,
          // BUG-2496：坏封面文件解码失败退回占位块，不当致命 FlutterError。
          errorBuilder: (_, Object error, __) {
            ErrorLogService.instance.logDiagnostic(
              'MangaSeriesPage.coverDecode',
              '$resolved: $error',
            );
            return const ColoredBox(
              color: Color(0xff303030),
              child: Icon(Icons.menu_book_outlined),
            );
          },
        );
      }
    }
    final MangaSeriesTarget target = widget.target;
    if (target is SourceMangaSeriesTarget) {
      final Widget Function(BuildContext)? builder = target.remoteCoverBuilder;
      if (builder != null) return builder(context);
    }
    return const ColoredBox(
      color: Color(0xff303030),
      child: Icon(Icons.menu_book_outlined),
    );
  }

  Widget _buildActions(BuildContext context) {
    final OnlineMangaLibraryEntry? entry = _entry;
    final bool inLibrary = _row != null;
    if (_isLocal) {
      return Wrap(
        spacing: 12,
        runSpacing: 8,
        children: <Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('manga_series_open_local'),
            onPressed: _busy ? null : () => unawaited(_openLocalBook()),
            icon: const Icon(Icons.play_arrow),
            label: Text(t.book_continue_reading),
          ),
          OutlinedButton.icon(
            key: const ValueKey<String>('manga_series_run_ocr'),
            onPressed: _busy ? null : () => unawaited(_runLocalBookOcr()),
            icon: const Icon(Icons.document_scanner_outlined),
            label: Text(t.manga_ocr_wizard_run),
          ),
          _ocrSettingsButton(),
        ],
      );
    }
    final int resumeIndex = _resumeIndex;
    final OnlineMangaChapter? resumeChapter =
        entry != null && resumeIndex >= 0 && resumeIndex < entry.chapters.length
        ? entry.chapters[resumeIndex]
        : null;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: <Widget>[
        FilledButton.icon(
          key: const ValueKey<String>('manga_series_continue'),
          onPressed: resumeChapter == null || _busy
              ? null
              : () => unawaited(_openChapterAt(resumeIndex)),
          icon: const Icon(Icons.play_arrow),
          label: Text(
            resumeChapter == null
                ? t.book_continue_reading
                : '${t.book_continue_reading} · ${resumeChapter.name}',
          ),
        ),
        // 同一个位置、同一个按钮：不在库是「加入」，在库是「移出」（用户诉求：加了
        // 要能取消）。移出走书架同一条 deleteBook 路径，连已下载章节一起删。
        if (inLibrary)
          OutlinedButton.icon(
            key: const ValueKey<String>('manga_series_remove_from_bookshelf'),
            onPressed: _busy ? null : () => unawaited(_removeFromLibrary()),
            icon: const Icon(Icons.library_add_check),
            label: Text(t.manga_series_remove_from_bookshelf),
          )
        else
          OutlinedButton.icon(
            key: const ValueKey<String>('manga_series_add_to_bookshelf'),
            onPressed: _busy ? null : () => unawaited(_addToLibrary()),
            icon: const Icon(Icons.library_add_outlined),
            label: Text(t.mihon_add_to_bookshelf),
          ),
        // 下载动作只对在库条目有意义：任务表按 bookKey 记，没有行就没地方挂任务。
        if (inLibrary) ...<Widget>[
          OutlinedButton.icon(
            key: const ValueKey<String>('manga_series_download_all'),
            onPressed: _busy ? null : () => unawaited(_downloadAll()),
            icon: const Icon(Icons.download_outlined),
            label: Text(t.manga_series_download_all),
          ),
          FushiSelectableChip(
            key: const ValueKey<String>('manga_series_auto_ocr_chip'),
            label: t.manga_series_auto_ocr,
            leadingIcon: Icons.document_scanner_outlined,
            selected: _appModelOrNull?.mangaDownloadAutoOcr ?? false,
            onSelected: (bool value) => unawaited(_setAutoOcr(value)),
          ),
          OutlinedButton.icon(
            key: const ValueKey<String>('manga_series_ocr_all_downloaded'),
            onPressed: _busy ? null : () => unawaited(_ocrAllDownloaded()),
            icon: const Icon(Icons.document_scanner_outlined),
            label: Text(t.manga_series_ocr_all_downloaded),
          ),
          _ocrSettingsButton(),
        ],
      ],
    );
  }

  /// 「OCR 设置」：作品页是阅读器外触发 OCR 的入口（BUG-2461），引擎偏好 / 模型
  /// 下载 / Lens 语言 / 外部 mokuro 路径必须就在触发点旁边可达——否则解析不到引擎
  /// 时用户只看到一条红 toast，不知道该去哪配。返回后重建：偏好是 AppModel 上的
  /// 状态，下一次「识别」按新偏好解析。
  Widget _ocrSettingsButton() {
    return OutlinedButton.icon(
      key: const ValueKey<String>('manga_series_ocr_settings'),
      onPressed: () => unawaited(_openOcrSettings()),
      icon: const Icon(Icons.tune_outlined),
      label: Text(t.manga_ocr_settings_open),
    );
  }

  Future<void> _openOcrSettings() async {
    await MangaOcrSettingsPage.push(context);
    if (mounted) setState(() {});
  }

  /// 本地卷没有章节，章节区换成「这一卷有多少页、读到哪」。
  ///
  /// 刻意不去猜「同系列的其它卷」：本地导入是一卷一条目、标题由 mokuro 的
  /// `title`+`volume` 拼出来，按标题前缀猜同系列会把不相干的书归到一起。真正
  /// 的成组关系有合集（`MediaCollections`）承载，那是显式的。
  Widget _buildLocalDetails(BuildContext context) {
    final EpubBookRow? row = _row;
    if (row == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.manga_series_volume_info, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        FushiCard(
          padding: EdgeInsets.zero,
          child: FushiListItem(
            leading: const Icon(Icons.auto_stories_outlined),
            title: Text(t.manga_series_page_count),
            trailing: Text('${row.chapterCount}'),
          ),
        ),
      ],
    );
  }
}

/// 锁定章弹窗的三条路；取消 = null。
enum _LockedChapterChoice { login, download }

/// 章 `manga.json` 的识别状态（见 `_chapterOcrState`）。
enum _ChapterOcrState { empty, hasResult, unreadable }
