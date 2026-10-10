import 'dart:async';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/online/online_shelf_removal.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/media/online/online_work_detail.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart'
    show MangaOcrPageFocus;
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
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

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
  /// 头，各运行时的取图方式没有公共分母。作品页因此不自己开取图路径，只留这个
  /// 口子。
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
/// - **与运行时无关**。只跟 [OnlineMangaLibraryService] 打交道，Mihon 与
///   互联对端走同一条路径。
/// - **本地卷也进这里**（用户明确要求的一致性）：本地 mokuro 卷没有章节，
///   章节区换成页数/进度，不假装有章节列表。
class MangaSeriesPage extends ConsumerStatefulWidget {
  const MangaSeriesPage({
    required this.target,
    super.key,
    this.ocrEnginesOverride,
    this.lensDisclosureOverride,
    this.openExternal,
  });

  final MangaSeriesTarget target;

  /// 测试缝：「在网站打开」默认用系统浏览器（[launchUrl]）。
  final Future<void> Function(Uri url)? openExternal;

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

  /// 章节排序：初值读全局偏好（阅读器章节抽屉同一份），切换即写回。
  bool _newestFirst = true;
  bool _unreadOnly = false;

  /// 正文滚动（窄屏整页 / 宽屏右栏）：快速滚动条与「跳到当前章节」都挂在它上。
  final ScrollController _scroll = ScrollController();
  final GlobalKey _currentChapterAnchor = GlobalKey(
    debugLabel: 'manga_series_current_chapter',
  );

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
    _newestFirst = _appModelOrNull?.mangaChapterListNewestFirst ?? true;
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_jobsWatch?.cancel());
    _jobsWatch = null;
    unawaited(_ocrChangesWatch?.cancel());
    unawaited(_ocrEventsWatch?.cancel());
    _scroll.dispose();
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
                FushiLinearProgressIndicator(
                  value: job == null || total <= 0 ? null : done / total,
                ),
              ],
            ),
          ),
          if (job != null)
            FushiIconButtonControl(
              key: const ValueKey<String>('manga_series_ocr_cancel'),
              tooltip: t.dialog_cancel,
              onPressed: () => unawaited(_cancelOcr()),
              icon: const FushiIcon(FushiIcons.close),
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
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
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

  /// 删除某章的本地下载。
  ///
  /// 2026-10 体验优化：原先菜单一点即删整章页图（重下要再跑一遍网络 + OCR），
  /// 先确认（写明章名），删完给 Toast。
  Future<void> _deleteChapterDownload(OnlineMangaChapter chapter) async {
    final EpubBookRow? row = _row;
    if (row == null) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.manga_chapter_download_delete_action,
      message: chapter.name,
      icon: FushiIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await deleteChapterDownload(
        await MangaStorage.bookPath(row.bookKey),
        chapter.key,
      );
      if (mounted) FushiToast.show(msg: t.storage_entry_delete_done);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.deleteDownload',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
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
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
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
      builder: (BuildContext dialogContext) => FushiAlertDialog.adaptive(
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
        FushiToast.show(
          msg: error.userMessage,
          severity: ToastSeverity.error,
        );
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

  /// 「在网站打开」：作品在源站的网页（扩展的 `getMangaUrl`，兜底 baseUrl + url）
  /// 交给系统浏览器。打不开浏览器不算本页错误，只提示。
  Future<void> _openWebsite(
    OnlineMangaWebUrlCapable adapter,
    OnlineMangaLibraryEntry entry,
  ) async {
    final Uri? url = await adapter.webUrl(entry);
    if (!mounted) return;
    if (url == null) {
      FushiToast.show(
        msg: t.mihon_source_website_unavailable,
        severity: ToastSeverity.warning,
      );
      return;
    }
    try {
      await (widget.openExternal ?? _launchExternal)(url);
    } on Object catch (error) {
      if (!mounted) return;
      FushiToast.show(
        msg: describeOnlineSourceError(error),
        severity: ToastSeverity.error,
      );
    }
  }

  static Future<void> _launchExternal(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
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
      final MangaOcrPageFocus focus = MangaOcrPageFocus();
      final MangaOcrJobSpec spec = MangaOcrJobSpec(
        engine: engine,
        engines: engines,
        imageDirPath: chapterDir.path,
        lensLanguage: appModel.mangaOcrLensLanguage,
        onlyMissing: onlyMissing,
        volumeTitle:
            '${entry.series.title} ${mangaChapterDisplayName(chapter)}',
        remoteTarget: availability.remoteTarget,
        focus: focus,
      );
      // 刻意不 await 启动：同书上一章还在识别时 enqueue 要等它结束。
      unawaited(
        registry.enqueue(
          job: MangaOcrBackgroundJob(
            bookKey: row.bookKey,
            managedDirectory: chapterDir.path,
            engine: engine,
            events: mangaOcrBackgroundEvents(spec),
            focus: focus,
            follower: mangaOcrJobFollower(spec),
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
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
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
      // 手点刷新才补 toast：提示条可能早已挂着，没有 toast 等于点了没反应。
      if (!silent) {
        FushiToast.show(
          msg: _loadErrorText(error),
          severity: ToastSeverity.error,
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.refresh', error, stack);
      if (!mounted) return;
      final OnlineMangaUnavailable wrapped = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        describeOnlineSourceError(error),
        cause: error,
      );
      setState(() => _refreshError = wrapped);
      if (!silent) {
        FushiToast.show(
          msg: wrapped.userMessage,
          severity: ToastSeverity.error,
        );
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
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
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
            deleteStatistics: decision.deleteStatistics,
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
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 与书架长按删除同一个确认框（[confirmRemoveOnlineWorkFromShelf]）。
  Future<DeleteDecision?> _confirmRemoveFromLibrary(AppModel appModel) =>
      confirmRemoveOnlineWorkFromShelf(
        context: context,
        appModel: appModel,
        title: t.manga_series_remove_from_bookshelf,
        message: t.manga_series_remove_confirm,
        statisticsSubtitle: t.delete_statistics_manga_desc,
      );

  /// 「继续阅读」落到哪一章。
  int get _resumeIndex {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return -1;
    return OnlineMangaLibraryService.resumeChapterIndex(
      entry,
      _states,
      target: MangaResumeTargetKey.fromKey(
        _appModelOrNull?.mangaResumeTarget ?? kMangaResumeTargetDefault,
      ),
    );
  }

  /// 点章节：开读——已下载从磁盘读，未下载在线直读（2026-09-26 用户撤回设计稿
  /// 2026-09-12 §1.1「先下载再读」；下载入口不变，走章节行溢出菜单 / 下载全部）。
  /// 未入库的先入库——进度、已读标记、下载任务都按 bookKey 记，没有行就无处可落。
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
      // 未下载的章也直接开读：阅读器按同一判据分流，已下载从磁盘读、未下载在线
      // 直读（2026-09-26 用户撤回设计稿 §1.1）。锁章（源标了要登录 / 购买）照旧
      // 先问：弹窗的出口是「仍然下载」/「登录」，选下载就入队、不开读。
      if (chapter.locked && !await isChapterDownloaded(bookDir, chapter.key)) {
        if (await _promptLockedChapter(chapter)) {
          await _enqueueChapter(chapter);
        }
        return;
      }
      final OnlineMangaLibraryEntry selected = await service.selectChapter(
        bookKey: bookKey,
        entry: entry,
        chapterIndex: index,
      );
      if (!mounted) return;
      setState(() => _entry = selected);
      await _openReader(bookKey, chapterIndex: index);
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
        FushiToast.show(
          msg: error.userMessage,
          severity: ToastSeverity.error,
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.openChapter', error, stack);
      if (mounted) {
        FushiToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
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
  /// [chapterIndex]：在线漫画点名要开的章，显式交给阅读器（不点名时阅读器按「重新
  /// 打开位置」偏好自己选章，那是首页「继续」等直接开书的语义）。
  Future<void> _openReader(String bookKey, {int? chapterIndex}) async {
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
            child: MangaFushiPage(
              item: null,
              bookKey: bookKey,
              initialChapterIndex: chapterIndex,
            ),
          ),
        ),
      );
      return;
    }
    final MediaItem launchItem = item;
    await _appModel.openMedia(
      ref: ref,
      mediaSource: MangaFushiSource.instance,
      item: launchItem,
      launchPageBuilder: () => MangaFushiSource.instance
          .buildChapterLaunchPage(item: launchItem, chapterIndex: chapterIndex),
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

  /// M3E 作品详情骨架（2026-10，与视频系列 / 在线作品页同一套
  /// `media_detail_kit.dart`）：AppBar 只留标题；原 AppBar 上的动作挪进 hero 的
  /// 主操作按钮组——登录 / 订阅是常驻的图标次按钮（BUG-2497：登录入口要直接
  /// 可见），在网站打开 / 刷新 / 自动下载 / OCR 进「⋯」。各动作的 ValueKey 原样
  /// 带到新组件上。
  @override
  Widget build(BuildContext context) {
    final OnlineMangaLibraryEntry? entry = _entry;
    final String title = entry?.series.title ?? _row?.title ?? t.manga_library;
    // 正文铺到悬浮页头底下（脚手架默认 extendBodyBehindHeader）：封面模糊背景
    // 一直画到窗口顶端，页头只是胶囊。
    return FushiPageScaffold(
      title: title,
      body: _buildBody(context),
    );
  }

  /// hero 标题上方的来源名（本地卷 / 源名 / 扩展包名）。
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
    if (_loading) return const MediaDetailSkeleton();
    final Object? fatal = _fatalError;
    // 页头浮在正文上（extendBodyBehindHeader）：错误态自己让开页头。
    if (fatal != null) {
      return SafeArea(bottom: false, child: _buildFatalError(context, fatal));
    }
    final OnlineMangaUnavailable? loadError = _refreshError;
    if (loadError != null && _hasNothingToShow) {
      return SafeArea(
        bottom: false,
        child: _buildLoadError(context, loadError),
      );
    }
    final double page = FushiDesignTokens.of(context).spacing.page;
    final Widget? ocrBanner = _isLocal ? null : _buildOcrBanner(context);
    // 宽屏两栏：左 hero（封面 / 标题 / 操作 / 简介）独立滚动，右章节列表；窄屏
    // 单列。BUG-2440 的底部安全区由 MediaDetailLayout 的尾部 SliverSafeArea 补。
    return FushiEntranceScope(
      child: MangaChapterFastScrollbar(
        controller: _scroll,
        notificationPredicate: _isBodyScroll,
        child: MediaDetailLayout(
          controller: _scroll,
          backdrop: _coverImageProvider(),
          header: _buildHeader(context),
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: page),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (ocrBanner != null) ...<Widget>[
                      FushiStaggeredEntrance(index: 0, child: ocrBanner),
                      const SizedBox(height: 12),
                    ],
                    if (_isLocal)
                      FushiStaggeredEntrance(
                        index: 1,
                        child: _buildLocalDetails(context),
                      )
                    else
                      _buildChapterList(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 章节区：刷新中顶一条波浪进度（原 AppBar 刷新钮的转圈挪进了「⋯」菜单，
  /// 进行中的反馈落在被刷新的列表上）+ 共享的 [MangaChapterList]。
  Widget _buildChapterList(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_refreshing)
          const Padding(
            key: ValueKey<String>('manga_series_refreshing'),
            padding: EdgeInsets.only(bottom: 8),
            child: FushiLinearProgressIndicator(),
          ),
        MangaChapterList(
          entry: _entry,
          states: _states,
          newestFirst: _newestFirst,
          unreadOnly: _unreadOnly,
          currentChapterKey: _entry?.currentChapter?.key,
          currentChapterAnchorKey: _currentChapterAnchor,
          onSortToggled: _toggleSort,
          onJumpToCurrent: _entry?.currentChapter == null
              ? null
              : () => scrollToMangaChapterAnchor(
                  _currentChapterAnchor,
                  duration: fushiMotionDuration(context, FushiMotion.medium),
                ),
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

  /// 切换章节排序并写回全局偏好（阅读器章节抽屉同一份）。没有 AppModel（源浏览
  /// 立起的无 ProviderScope 树）时只在本页生效。
  void _toggleSort() {
    setState(() => _newestFirst = !_newestFirst);
    final AppModel? appModel = _appModelOrNull;
    if (appModel != null) {
      unawaited(appModel.setMangaChapterListNewestFirst(_newestFirst));
    }
  }

  /// 快速滚动条只跟正文那个滚动视图：宽屏两栏时左栏（hero）也会冒滚动通知。
  bool _isBodyScroll(ScrollNotification notification) {
    if (notification.depth != 0 || !_scroll.hasClients) return false;
    final ScrollableState? scrollable = notification.context
        ?.findAncestorStateOfType<ScrollableState>();
    return scrollable != null &&
        _scroll.positions.contains(scrollable.position);
  }

  /// 可读文案：桥接层 message 往往是 `Exception: ...` 原串，经
  /// [OnlineMangaUnavailable.userMessage] 归一（2026-10 体验优化）；原串只进
  /// 「查看详情」。
  static String _loadErrorText(OnlineMangaUnavailable error) =>
      error.userMessage;

  /// 一点内容都拉不到时的完整错误视图。
  ///
  /// 三件事缺一不可（BUG-1767 用例逐条盯着）：**原因可见**（把桥接层给的
  /// message 原样摆出来，不是一句「加载失败」）、**诊断入口**（原生堆栈和失败
  /// 阶段太长不能铺在页面上，只能进可复制对话框）、**重试真的重发请求**。
  Widget _buildLoadError(BuildContext context, OnlineMangaUnavailable error) {
    // 源被禁用 / 平台不支持时重试永远不会成功，别给一个骗人的按钮。
    final bool retryable =
        error.reason == OnlineMangaUnavailableReason.runtimeFailure;
    return SingleChildScrollView(
      child: FushiPlaceholderMessage(
        icon: FushiIcons.cloudOff,
        tone: FushiPlaceholderTone.error,
        message: t.manga_online_detail_load_failed,
        // 原始异常（含堆栈）在「查看详情」对话框里，这里给可读短句。
        detail: _loadErrorText(error),
        detailMaxLines: 6,
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (retryable)
              FushiFilledButton.icon(
                key: const ValueKey<String>('manga_series_error_retry'),
                onPressed: _refreshing
                    ? null
                    : () => unawaited(_refreshFromSource()),
                icon: const FushiIcon(FushiIcons.refresh),
                label: Text(t.retry),
              ),
            _challengeAction(error),
            FushiTextButton(
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
      ),
    );
  }

  /// 读库本身失败（条目被删 / 数据库异常）：错误占位 + 重试（重新走一遍
  /// [_load]，不是只刷新源）。
  Widget _buildFatalError(BuildContext context, Object error) =>
      SingleChildScrollView(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: t.manga_online_detail_load_failed,
          detail: describeOnlineSourceError(error),
          detailMaxLines: 6,
          action: FushiFilledButton.icon(
            key: const ValueKey<String>('manga_series_fatal_retry'),
            onPressed: _retryLoad,
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );

  void _retryLoad() {
    setState(() {
      _fatalError = null;
      _loading = true;
    });
    unawaited(_load());
  }

  /// 刷新失败提示条（hero 简介下方，不遮挡章节）。
  ///
  /// 按 [OnlineMangaUnavailableReason] 分流是有意义的：源被禁用和网络抽风给的
  /// 出路完全不同，把两者都渲染成「加载失败 + 重试」会让用户对着一个永远不会
  /// 成功的按钮反复点。按钮另起一行 Wrap：两栏左栏只有 400 宽，与文案并排必溢出。
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
      key: const ValueKey<String>('manga_series_refresh_banner'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiIcon(FushiIcons.cloudOff, color: theme.colorScheme.error),
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
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              if (retryable)
                FushiTextButton(
                  onPressed: _refreshing
                      ? null
                      : () => unawaited(_refreshFromSource()),
                  child: Text(t.retry),
                ),
              _challengeAction(error),
              FushiTextButton(
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
        ],
      ),
    );
  }

  /// 作品页头部：三域共用的 [OnlineWorkHeader]（M3E 详情 hero）——封面模糊大
  /// 背景 + 封面卡 + 来源 overline + 标题 + 作者 / 在书架 chip + 主操作按钮组 +
  /// 类型标签 + 可展开简介（+ 刷新失败提示条）。
  Widget _buildHeader(BuildContext context) {
    final OnlineMangaSeries? series = _entry?.series;
    final OnlineMangaUnavailable? refreshError = _refreshError;
    return OnlineWorkHeader(
      cover: _buildCover(context),
      backdrop: _coverImageProvider(),
      overline: _subtitle(),
      title: series?.title ?? _row?.title ?? t.manga_library,
      chips: <MediaDetailChip>[
        for (final String? line in <String?>[
          series?.byline,
          if (_isLocal) _row?.author,
        ])
          if (line != null && line.trim().isNotEmpty)
            MediaDetailChip(line.trim(), icon: FushiIcons.person),
        if (_row != null && !_isLocal)
          MediaDetailChip(
            t.video_discovery_in_library,
            icon: FushiIcons.check,
            tone: MediaDetailChipTone.primary,
            key: const ValueKey<String>('manga_series_in_library_chip'),
          ),
        // 扩展源的作品来自第三方站点（10-09 所有者「外部来源」提示）；互联对端
        // 是用户自己的设备，本地卷没有在线来源，都不标。
        if (_entry case final OnlineMangaLibraryEntry entry
            when entry.runtime != OnlineMangaRuntimeKind.interconnect)
          ...extensionSourceDetailChips(),
      ],
      genres: series?.genreLabels ?? const <String>[],
      description: series?.description,
      primaryAction: _buildPrimaryAction(),
      secondaryActions: _buildSecondaryActions(),
      moreItems: _buildMoreItems(),
      extra: refreshError == null
          ? null
          : _buildRefreshBanner(context, refreshError),
    );
  }

  /// 本地已落盘封面的路径；未入库 / 无封面为 null。
  String? _localCoverPath() {
    final EpubBookRow? row = _row;
    if (row == null) return null;
    // 复用书架/制卡那份解析（TODO-1388 / BUG-703），别自己拼路径：coverPath 可能
    // 是相对页图路径、可能大小写与磁盘不符（跨平台备份还原），那些坑都已经在
    // resolveCoverFilePath 里踩过了。
    return ReaderFushiSource.resolveCoverFilePath(
      extractDir: row.extractDir,
      coverPath: row.coverPath,
    );
  }

  /// hero 大背景：本地封面模糊铺底。未入库的源条目只有来源自己的取图控件、拿不到
  /// ImageProvider，就只画色晕（不为背景另开一条取图路径）。
  ImageProvider? _coverImageProvider() {
    final String? path = _localCoverPath();
    return path == null ? null : FileImage(File(path));
  }

  /// 封面。
  ///
  /// 入库条目一律走**本地已落盘**的封面：作品页的首屏不该依赖网络，源挂了封面
  /// 也得在。没有本地封面（刚从源进来还没入库）才回退到占位块——真正的远端取图
  /// 由源浏览页的封面缓存负责，作品页不自己再开一条取图路径。
  Widget _buildCover(BuildContext context) {
    final String? resolved = _localCoverPath();
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
          return _coverPlaceholder(context);
        },
      );
    }
    final MangaSeriesTarget target = widget.target;
    if (target is SourceMangaSeriesTarget) {
      final Widget Function(BuildContext)? builder = target.remoteCoverBuilder;
      if (builder != null) return builder(context);
    }
    return _coverPlaceholder(context);
  }

  /// 无封面 / 封面解码失败的占位块：跟随主题的中性底（深浅色都可读），
  /// 不再是写死的深灰 #303030（浅色主题下是突兀的黑块、图标也看不清）。
  Widget _coverPlaceholder(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: FushiIcon(
          FushiIcons.manga,
          size: 40,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 在飞下载（排队 / 执行中）的整体页进度：主按钮下挂波浪条。没有在飞任务 =
  /// null；页数还不知道 = -1（不确定进度）。
  double? get _downloadProgress {
    bool active = false;
    int done = 0;
    int total = 0;
    for (final MangaDownloadJobRow job in _jobs.values) {
      if (job.status != MangaDownloadJobStatus.queued &&
          job.status != MangaDownloadJobStatus.running) {
        continue;
      }
      active = true;
      done += job.pagesDone;
      total += job.pagesTotal;
    }
    if (!active) return null;
    if (total <= 0) return -1;
    return (done / total).clamp(0.0, 1.0);
  }

  /// 主按钮：本地卷「继续阅读」；在线作品「继续阅读 · 第 N 话」（未入库点了会
  /// 先入库再读，见 [_openChapterAt]）。
  Widget _buildPrimaryAction() {
    if (_isLocal) {
      return MediaDetailPrimaryButton(
        buttonKey: const ValueKey<String>('manga_series_open_local'),
        icon: FushiIcons.play,
        label: t.book_continue_reading,
        onPressed: _busy ? null : () => unawaited(_openLocalBook()),
      );
    }
    final OnlineMangaLibraryEntry? entry = _entry;
    final int resumeIndex = _resumeIndex;
    final OnlineMangaChapter? resumeChapter =
        entry != null && resumeIndex >= 0 && resumeIndex < entry.chapters.length
        ? entry.chapters[resumeIndex]
        : null;
    return MediaDetailPrimaryButton(
      buttonKey: const ValueKey<String>('manga_series_continue'),
      icon: FushiIcons.play,
      label: resumeChapter == null
          ? t.book_continue_reading
          : '${t.book_continue_reading} · ${resumeChapter.name}',
      progress: _downloadProgress,
      onPressed: resumeChapter == null || _busy
          ? null
          : () => unawaited(_openChapterAt(resumeIndex)),
    );
  }

  /// 次按钮（tonal）：加入 ↔ 移出书架（同一位置，在库时 selected）、下载全部；
  /// 订阅（书签）与登录是图标钮。本地卷只有「OCR 设置」。
  List<Widget> _buildSecondaryActions() {
    if (_isLocal) {
      // 没有「开始 OCR」：进入阅读器即自动整卷识别（manga_reader_auto_ocr.dart）。
      return <Widget>[_ocrSettingsButton()];
    }
    final OnlineMangaLibraryEntry? entry = _entry;
    final bool inLibrary = _row != null;
    final OnlineMangaLoginTarget? login = _loginTarget;
    return <Widget>[
      // 同一个位置、同一个按钮：不在库是「加入」，在库是「移出」（用户诉求：加了
      // 要能取消）。移出走书架同一条 deleteBook 路径，连已下载章节一起删。
      if (inLibrary)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>(
            'manga_series_remove_from_bookshelf',
          ),
          icon: FushiIcons.libraryAdd,
          label: t.manga_series_remove_from_bookshelf,
          selected: true,
          onPressed: _busy ? null : () => unawaited(_removeFromLibrary()),
        )
      else
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_add_to_bookshelf'),
          icon: FushiIcons.libraryAdd,
          label: t.mihon_add_to_bookshelf,
          onPressed: _busy ? null : () => unawaited(_addToLibrary()),
        ),
      // 下载动作只对在库条目有意义：任务表按 bookKey 记，没有行就没地方挂任务。
      if (inLibrary)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_download_all'),
          icon: FushiIcons.download,
          label: t.manga_series_download_all,
          onPressed: _busy ? null : () => unawaited(_downloadAll()),
        ),
      if (entry != null && inLibrary && _service != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_subscribe'),
          icon: entry.subscribed ? FushiIcons.bookmark : FushiIcons.bookmarkAdd,
          label: entry.subscribed
              ? t.manga_series_unsubscribe
              : t.manga_series_subscribe,
          selected: entry.subscribed,
          iconOnly: true,
          onPressed: _busy ? null : () => unawaited(_toggleSubscription()),
        ),
      // 源站要登录才给锁章（BUG-2497）：入口放在用户看到「锁」的这一页、常驻
      // 可见，不必先点一条锁章再从弹窗里找。
      if (login != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_login'),
          icon: FushiIcons.login,
          label: t.mihon_source_login,
          iconOnly: true,
          onPressed: _busy || _refreshing
              ? null
              : () => unawaited(_loginToSource(login)),
        ),
    ];
  }

  /// 「⋯」：在网站打开、刷新章节、新章自动下载（订阅中）、下载后自动识别、
  /// 识别全部已下载、OCR 设置（在库）。
  List<MediaDetailMenuItem> _buildMoreItems() {
    if (_isLocal) return const <MediaDetailMenuItem>[];
    final OnlineMangaLibraryEntry? entry = _entry;
    final Object? adapter = _adapter;
    final bool inLibrary = _row != null;
    final bool autoOcr = _appModelOrNull?.mangaDownloadAutoOcr ?? false;
    return <MediaDetailMenuItem>[
      // 源站网页入口：只有在线源（Mihon）有网页可去，本地卷 / 互联对端没有。
      if (entry != null && adapter is OnlineMangaWebUrlCapable)
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_open_website'),
          icon: FushiIcons.openInNew,
          label: t.mihon_source_website_open,
          onSelected: () => unawaited(_openWebsite(adapter, entry)),
        ),
      if (entry != null)
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_refresh'),
          icon: FushiIcons.refresh,
          label: t.manga_series_refresh,
          enabled: !_refreshing,
          onSelected: () => unawaited(_refreshFromSource()),
        ),
      if (entry != null && inLibrary && _service != null && entry.subscribed)
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_auto_download'),
          icon: entry.autoDownload
              ? FushiIcons.filled(FushiIcons.success)
              : FushiIcons.cloudDownload,
          label: t.manga_series_auto_download,
          enabled: !_busy,
          onSelected: () => unawaited(_toggleAutoDownload()),
        ),
      if (inLibrary) ...<MediaDetailMenuItem>[
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_auto_ocr_chip'),
          icon: autoOcr ? FushiIcons.filled(FushiIcons.success) : FushiIcons.ocr,
          label: t.manga_series_auto_ocr,
          onSelected: () => unawaited(_setAutoOcr(!autoOcr)),
        ),
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_ocr_all_downloaded'),
          icon: FushiIcons.ocr,
          label: t.manga_series_ocr_all_downloaded,
          enabled: !_busy,
          onSelected: () => unawaited(_ocrAllDownloaded()),
        ),
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_ocr_settings'),
          icon: FushiIcons.settings,
          label: t.manga_ocr_settings_open,
          onSelected: () => unawaited(_openOcrSettings()),
        ),
      ],
    ];
  }

  /// 「OCR 设置」：作品页是阅读器外触发 OCR 的入口（BUG-2461），引擎偏好 / 模型
  /// 下载 / Lens 语言 / 外部 mokuro 路径必须就在触发点旁边可达——否则解析不到引擎
  /// 时用户只看到一条红 toast，不知道该去哪配。返回后重建：偏好是 AppModel 上的
  /// 状态，下一次「识别」按新偏好解析。在线作品在「⋯」里，本地卷是次按钮。
  Widget _ocrSettingsButton() {
    return MediaDetailSecondaryButton(
      buttonKey: const ValueKey<String>('manga_series_ocr_settings'),
      icon: FushiIcons.settings,
      label: t.manga_ocr_settings_open,
      onPressed: () => unawaited(_openOcrSettings()),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MediaDetailSectionHeader(t.manga_series_volume_info),
        MediaDetailItemRow(
          index: 0,
          count: 1,
          leading: const FushiIcon(FushiIcons.books),
          title: t.manga_series_page_count,
          trailing: Text(
            '${row.chapterCount}',
            style: context.fushiType.titleMediumEmphasized.tabular,
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
