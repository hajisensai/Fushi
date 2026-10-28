/// Kavita EPUB 系列详情：章（文件）列表，每章可「阅读」（下载成缓存副本后入库阅读，
/// 缓存有上限、按最近使用淘汰）或「下载」（持久副本）。
///
/// 打开 = [KavitaBookService.openOrImport]（已在本地就不重复下载）+ 打开后
/// [KavitaBookService.trimCache]；下载 = 打开 + [KavitaBookService.pin]；移除下载 =
/// [KavitaBookService.removeDownload]（真删本地文件与书架条目）。下载是用户自有内容的
/// 离线副本，问 `userConfiguredServersAvailable`（不挂下载中心的 `downloads` 门；
/// 2026-10-27 用户拍板 iOS 也保留），阅读不受限。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/kavita/kavita_api_registry.dart';
import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

class KavitaBookSeriesPage extends ConsumerStatefulWidget {
  const KavitaBookSeriesPage({
    required this.server,
    required this.series,
    required this.api,
    this.service,
    this.readerSettleDelays = kReaderSettleDelays,
    super.key,
  });

  /// 阅读器关闭后的「追平」重取间隔。阅读器 dispose 只是把最后一页交给
  /// `KavitaEpubSyncSession.close()`（fire-and-forget，最长等 `kCloseFlushTimeout` = 5s），
  /// 页面拿不到那个 future，所以关书后立刻重取可能早于最后一次推送。这里在立即重取之后
  /// 再按间隔补取（累计 6s > 5s 的 flush 上限），一旦某次补取看到章节进度变化就停：
  /// 变化 = 推送已落到服务器。
  static const List<Duration> kReaderSettleDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
  ];

  final List<Duration> readerSettleDelays;

  /// 注入的书服务（测试用）；null = 用 appProvider 的数据库与临时目录自建。
  final KavitaBookService? service;

  final KavitaServerConfig server;
  final KavitaSeries series;
  final KavitaApi api;

  @override
  ConsumerState<KavitaBookSeriesPage> createState() =>
      _KavitaBookSeriesPageState();
}

/// 章节在服务器上的已读百分比（0-100）；没有页数信息时为 0。
int kavitaChapterReadPercent(KavitaChapter chapter) {
  if (chapter.pages <= 0) return 0;
  return ((chapter.pagesRead * 100) ~/ chapter.pages).clamp(0, 100);
}

/// 章节行的进度文案：读完 / 读了一部分 / 没读（空串）。
String kavitaChapterProgressLabel(KavitaChapter chapter) {
  if (chapter.isRead) return t.kavita_book_progress_finished;
  final int percent = kavitaChapterReadPercent(chapter);
  return percent > 0 ? t.kavita_book_progress_percent(percent: '$percent') : '';
}

class _KavitaBookSeriesPageState extends ConsumerState<KavitaBookSeriesPage>
    with WidgetsBindingObserver {
  List<KavitaChapter> _chapters = const <KavitaChapter>[];
  Map<int, ({String bookKey, KavitaBookBinding binding})> _bound =
      const <int, ({String bookKey, KavitaBookBinding binding})>{};
  bool _loading = true;
  Object? _error;

  /// 正在下载的章 → 进度百分比（null = 大小未知）。
  final Map<int, int?> _busy = <int, int?>{};
  final Map<int, KavitaCancelToken> _tokens = <int, KavitaCancelToken>{};

  KavitaBookService? _service;

  Future<KavitaBookService> _ensureService() async {
    final KavitaBookService? existing = _service ?? widget.service;
    if (existing != null) return _service = existing;
    final AppModel appModel = ref.read(appProvider);
    final KavitaBookService created = KavitaBookService(
      db: appModel.database,
      tempRoot: await getTemporaryDirectory(),
      apiFor: (String serverConfigId) => KavitaApiRegistry.instance
          .apiForServerId(appModel.prefsRepo.kavitaServers, serverConfigId),
    );
    return _service = created;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  /// 应用从后台回来：服务器上的进度可能被别处（网页端标已读 / 未读）改过，静默重取。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(silent: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settleGeneration++;
    for (final KavitaCancelToken token in _tokens.values) {
      token.cancel();
    }
    super.dispose();
  }

  /// [silent] = 刷新已有列表（回前台 / 下拉 / 读完回来 / 标记后）：不闪加载态，失败
  /// 只记日志、保留旧数据。章节的已读进度（`pagesRead`）只来自这次拉取，所以任何
  /// 「服务器可能变了」的时机都要走它。
  /// 返回这次是否成功取到并应用了列表。
  Future<bool> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final KavitaSeriesDetail detail = await widget.api.getSeriesDetail(
        widget.series.id,
      );
      final KavitaBookService service = await _ensureService();
      final Map<int, ({String bookKey, KavitaBookBinding binding})> bound =
          await service.boundChapters(widget.server.id);
      if (!mounted) return false;
      setState(() {
        _chapters = detail.allChapters;
        _bound = bound;
        _loading = false;
      });
      return true;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBookSeries.load', error, stack);
      if (!mounted || silent) return false;
      setState(() {
        _error = error;
        _loading = false;
      });
      return false;
    }
  }

  int _settleGeneration = 0;

  String _progressSignature() => <String>[
    for (final KavitaChapter c in _chapters) '${c.id}:${c.pagesRead}',
  ].join(',');

  /// 阅读器关闭后重取：先立即取一次，再按 [KavitaBookSeriesPage.readerSettleDelays]
  /// 补取直到进度出现变化（见该常量说明）。新一轮 / 页面销毁会让旧一轮作废。
  Future<void> _reloadAfterReader() async {
    final int generation = ++_settleGeneration;
    await _load(silent: true);
    for (final Duration delay in widget.readerSettleDelays) {
      final String before = _progressSignature();
      await Future<void>.delayed(delay);
      if (!mounted || generation != _settleGeneration) return;
      final bool ok = await _load(silent: true);
      if (ok && _progressSignature() != before) return;
    }
  }

  Future<void> _refreshBound() async {
    final KavitaBookService service = await _ensureService();
    final Map<int, ({String bookKey, KavitaBookBinding binding})> bound =
        await service.boundChapters(widget.server.id);
    if (mounted) setState(() => _bound = bound);
  }

  /// 确保这一章在本地，返回 bookKey；失败 / 取消返回 null（已提示用户）。
  Future<String?> _ensureLocal(KavitaChapter chapter) async {
    final KavitaBookService service = await _ensureService();
    final KavitaCancelToken token = KavitaCancelToken();
    _tokens[chapter.id] = token;
    setState(() => _busy[chapter.id] = null);
    try {
      return await service.openOrImport(
        serverConfigId: widget.server.id,
        api: widget.api,
        series: widget.series,
        chapter: chapter,
        cancelToken: token,
        onProgress: (int received, int? total) {
          if (!mounted || total == null || total <= 0) return;
          setState(() => _busy[chapter.id] = (received * 100) ~/ total);
        },
      );
    } on KavitaDownloadCancelled {
      return null;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBookSeries.download', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          FushiSnackBar(
            content: Text(
              t.kavita_book_download_failed(
                reason: error is KavitaApiException
                    ? 'HTTP ${error.statusCode}'
                    : error.runtimeType.toString(),
              ),
            ),
          ),
        );
      }
      return null;
    } finally {
      _tokens.remove(chapter.id);
      if (mounted) setState(() => _busy.remove(chapter.id));
    }
  }

  Future<void> _read(KavitaChapter chapter) async {
    final String? bookKey = await _ensureLocal(chapter);
    if (bookKey == null || !mounted) return;
    unawaited(_refreshBound());
    unawaited(_trimCache(keep: bookKey));
    final AppModel appModel = ref.read(appProvider);
    final MediaItem? item = await ReaderFushiSource.instance
        .mediaItemForBookKey(bookKey);
    if (item == null || !mounted) return;
    await appModel.openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: appModel),
      item: item,
    );
    // 阅读器关闭时会把进度推给服务器；回来后重取，列表上的进度才是服务器的最新值。
    if (mounted) unawaited(_reloadAfterReader());
  }

  /// 手动标已读 / 未读（长按 / 右键菜单）：先改服务器，再把本地副本的位置与同步基线
  /// 对齐（见 [KavitaBookService.alignLocalWithServerMark]），最后重取列表。
  Future<void> _setRead(KavitaChapter chapter, {required bool read}) async {
    Object? failure;
    try {
      if (read) {
        await widget.api.markChaptersRead(
          seriesId: widget.series.id,
          chapterIds: <int>[chapter.id],
        );
      } else {
        await widget.api.markChaptersUnread(
          seriesId: widget.series.id,
          chapterIds: <int>[chapter.id],
        );
      }
      final KavitaBookService service = await _ensureService();
      await service.alignLocalWithServerMark(
        serverConfigId: widget.server.id,
        chapterId: chapter.id,
        read: read,
        totalPages: chapter.pages,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBookSeries.mark', error, stack);
      failure = error;
    }
    if (!mounted) return;
    FushiToast.show(
      msg: failure != null
          ? t.kavita_book_mark_failed(
              reason: failure is KavitaApiException
                  ? 'HTTP ${failure.statusCode}'
                  : failure.runtimeType.toString(),
            )
          : read
          ? t.kavita_book_marked_read
          : t.kavita_book_marked_unread,
      severity: failure != null ? ToastSeverity.error : ToastSeverity.success,
    );
    await _load(silent: true);
  }

  /// 章节菜单（长按 / 右键）：标已读 / 未读。
  Future<void> _showChapterMenu(KavitaChapter chapter) async {
    final bool read = chapter.isRead;
    final bool? markRead = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => FushiAlertDialog(
        key: const ValueKey<String>('kavita-chapter-menu'),
        title: Text(
          chapter.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!read)
              FushiListItem(
                key: const ValueKey<String>('kavita-chapter-mark-read'),
                leading: const FushiIcon(FushiIcons.check),
                title: Text(t.kavita_book_mark_read),
                onTap: () => Navigator.pop(dialogContext, true),
              ),
            if (read || chapter.pagesRead > 0)
              FushiListItem(
                key: const ValueKey<String>('kavita-chapter-mark-unread'),
                leading: const FushiIcon(FushiIcons.visibilityOff),
                title: Text(t.kavita_book_mark_unread),
                onTap: () => Navigator.pop(dialogContext, false),
              ),
          ],
        ),
      ),
    );
    if (markRead == null || !mounted) return;
    await _setRead(chapter, read: markRead);
  }

  Future<void> _download(KavitaChapter chapter) async {
    final String? bookKey = await _ensureLocal(chapter);
    if (bookKey == null) return;
    final KavitaBookService service = await _ensureService();
    await service.pin(bookKey);
    if (mounted) await _refreshBound();
  }

  /// 「阅读」刚产生 / 用到一份缓存副本：把缓存收回上限（不挡开书，失败只记日志）。
  Future<void> _trimCache({required String keep}) async {
    try {
      final KavitaBookService service = await _ensureService();
      await service.trimCache(keep: keep);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('KavitaBookSeries.trimCache', error, stack);
    }
    if (mounted) await _refreshBound();
  }

  Future<void> _removeDownload(String bookKey) async {
    final KavitaBookService service = await _ensureService();
    final bool hasUserData = await service.hasLocalUserData(bookKey);
    if (!mounted) return;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => FushiAlertDialog(
        key: const ValueKey<String>('kavita-remove-download-confirm'),
        title: Text(t.kavita_book_remove_download),
        content: Text(
          hasUserData
              ? t.kavita_book_remove_download_confirm_user_data
              : t.kavita_book_remove_download_confirm,
        ),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.kavita_book_cancel),
          ),
          FushiTextButton(
            key: const ValueKey<String>('kavita-remove-download-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.kavita_book_remove_download),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final KavitaLocalRemoval outcome = await service.removeDownload(bookKey);
    if (!mounted) return;
    final String? message = switch (outcome) {
      KavitaLocalRemoval.removed => null,
      KavitaLocalRemoval.keptUnsynced => t.kavita_book_remove_download_kept,
      KavitaLocalRemoval.failed => t.kavita_book_remove_download_failed,
    };
    if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(FushiSnackBar(content: Text(message)));
    }
    await _refreshBound();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FushiAppBar(title: Text(widget.series.displayName)),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return Center(child: adaptiveIndicator(context: context));
    if (_error != null) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.error,
        message: t.kavita_connect_failed(reason: ''),
        action: FushiFilledButton.icon(
          onPressed: () => unawaited(_load()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.retry),
        ),
      );
    }
    if (_chapters.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.books,
        message: t.kavita_book_no_chapters,
      );
    }
    final bool canDownload = userConfiguredServersAvailable;
    return FushiRefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: FushiEntranceScope(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: _chapters.length,
          itemBuilder: fushiStaggeredItemBuilder((
            BuildContext context,
            int index,
          ) {
            final KavitaChapter chapter = _chapters[index];
            return _chapterTile(chapter, canDownload: canDownload);
          }),
        ),
      ),
    );
  }

  Widget _chapterTile(KavitaChapter chapter, {required bool canDownload}) {
    final ({String bookKey, KavitaBookBinding binding})? local =
        _bound[chapter.id];
    final bool busy = _busy.containsKey(chapter.id);
    final int? percent = _busy[chapter.id];
    final bool pinned = local != null && !local.binding.cachedOnly;
    final String status = busy
        ? (percent == null
              ? t.kavita_book_downloading(percent: '…')
              : t.kavita_book_downloading(percent: '$percent'))
        : pinned
        ? t.kavita_book_downloaded
        : local != null
        ? t.kavita_book_cached
        : '';
    final String progress = kavitaChapterProgressLabel(chapter);
    final String subtitle = <String>[
      if (progress.isNotEmpty) progress,
      if (status.isNotEmpty) status,
    ].join(' · ');
    final Widget item = FushiListItem(
      key: ValueKey<String>('kavita_chapter_${chapter.id}'),
      title: Text(chapter.displayName),
      titleMaxLines: 2,
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: busy ? null : () => unawaited(_read(chapter)),
      trailing: busy
          ? FushiTextButton(
              onPressed: () => _tokens[chapter.id]?.cancel(),
              child: Text(t.kavita_book_cancel),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (canDownload && pinned)
                  FushiIconButtonControl(
                    tooltip: t.kavita_book_remove_download,
                    icon: const FushiIcon(FushiIcons.downloadDone),
                    onPressed: () => unawaited(_removeDownload(local.bookKey)),
                  )
                else if (canDownload)
                  FushiIconButtonControl(
                    tooltip: t.kavita_book_download,
                    icon: const FushiIcon(FushiIcons.download),
                    onPressed: () => unawaited(_download(chapter)),
                  ),
                FushiIconButtonControl(
                  tooltip: t.kavita_book_open,
                  icon: const FushiIcon(FushiIcons.books),
                  onPressed: () => unawaited(_read(chapter)),
                ),
              ],
            ),
    );
    // 右键走绑定表（ContextMenuTrigger），长按给触屏；下载中不弹（避免与取消抢）。
    if (busy) return item;
    return ContextMenuTrigger(
      onInvoke: (Offset _) => unawaited(_showChapterMenu(chapter)),
      child: GestureDetector(
        onLongPress: () => unawaited(_showChapterMenu(chapter)),
        child: item,
      ),
    );
  }
}
