import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart' show Bookmark;
import 'package:fushi_core/fushi_core.dart' show BookFormat, EpubBookRow;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare_action.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/online/online_shelf_removal.dart';
import 'package:fushi/src/media/online/online_work_detail.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show buildCollectionReaderMediaItem;
import 'package:fushi/utils.dart';

/// 小说源的作品页：详情 + 章节目录。默认**在线阅读**，另有「加入书架」「下载」。
///
/// 版式是三域共用的 [OnlineWorkHeader]（以视频源作品页为准）：封面 + 标题 / 作者 /
/// 状态 / 类型，主操作区，简介，章节列表；页头「在网站打开」「刷新」。
/// - 点某一章 / 「在线阅读」= 在线读这一章（[LnReaderOnlineLibrary]：作品第一次在线
///   打开时建成全章占位书进书架，阅读器读到哪章取哪章）；
/// - 「加入书架」= 只建那本在线书、不开阅读器（2026-09-27 起与「下载」分开：此前
///   「加入书架」实际是整本下载，与漫画「加入书架」语义不一致）；在书架里时同一
///   位置是「移出书架」，与书架长按删除同一条路径；
/// - 「下载」/ 行尾下载按钮 = 把选定范围整本下载成 EPUB。
/// 两条路都落到普通书，阅读器 / 查词 / 制卡 / 统计 / 同步全部复用。
class LnReaderNovelDetailPage extends ConsumerStatefulWidget {
  const LnReaderNovelDetailPage({
    required this.manager,
    required this.plugin,
    required this.item,
    required this.imageHeaders,
    super.key,
    this.openExternal,
  });

  final LnReaderManager manager;
  final LnReaderInstalledPlugin plugin;
  final LnReaderNovelItem item;
  final Map<String, String> imageHeaders;

  /// 测试注入：默认用系统浏览器打开（[launchUrl]）。
  final Future<void> Function(Uri url)? openExternal;

  @override
  ConsumerState<LnReaderNovelDetailPage> createState() =>
      _LnReaderNovelDetailPageState();
}

class _LnReaderNovelDetailPageState
    extends ConsumerState<LnReaderNovelDetailPage> {
  LnReaderNovel? _novel;
  bool _loading = true;
  Object? _error;

  /// 正在准备在线书（首次建占位书 / 同步章节列表）或移出书架，期间禁止重复点。
  bool _opening = false;

  /// 这部作品在书架上的在线书（null = 不在书架）。
  EpubBookRow? _shelfBook;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.manager.load(widget.plugin);
      final LnReaderNovel novel = await widget.manager.runtime.novel(
        widget.plugin.id,
        widget.item.path,
      );
      final EpubBookRow? shelfBook = await _onlineLibrary().findBook(
        widget.plugin.id,
        widget.item.path,
      );
      if (!mounted) return;
      setState(() {
        _novel = novel;
        _shelfBook = shelfBook;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _openWebsite() async {
    try {
      final String url = await widget.manager.runtime.resolveUrl(
        widget.plugin.id,
        widget.item.path,
        isNovel: true,
      );
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        FushiToast.show(
          msg: t.mihon_source_website_unavailable,
          severity: ToastSeverity.warning,
        );
        return;
      }
      await (widget.openExternal ?? _launchExternal)(uri);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
  }

  static Future<void> _launchExternal(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  LnReaderOnlineLibrary _onlineLibrary() {
    final AppModel appModel = ref.read(appProvider);
    return LnReaderOnlineLibrary(
      manager: widget.manager,
      database: appModel.database,
      download: LnReaderBookDownload(
        manager: widget.manager,
        database: appModel.database,
        httpClientFactory: createAppHttpClient,
      ),
    );
  }

  /// 找到或建好这部作品的在线书（进书架），返回 bookKey；失败提示并返回 null。
  Future<String?> _ensureShelfBook(LnReaderNovel novel) async {
    setState(() => _opening = true);
    try {
      final LnReaderOnlineLibrary library = _onlineLibrary();
      final String bookKey = await library.ensureBook(
        plugin: widget.plugin,
        novel: novel,
        pendingText: t.novel_online_chapter_pending,
      );
      final EpubBookRow? shelfBook = await library.findBook(
        widget.plugin.id,
        widget.item.path,
      );
      if (!mounted) return bookKey;
      setState(() {
        _opening = false;
        _shelfBook = shelfBook;
      });
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      ref.invalidate(srtBooksProvider);
      return bookKey;
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() => _opening = false);
      FushiToast.show(
        msg: t.novel_online_open_failed(error: '$error'),
        severity: ToastSeverity.error,
      );
      return null;
    }
  }

  /// 「加入书架」：只建在线书、不开阅读器。
  Future<void> _addToShelf() async {
    final LnReaderNovel? novel = _novel;
    if (novel == null || novel.chapters.isEmpty || _opening) return;
    final String? bookKey = await _ensureShelfBook(novel);
    if (bookKey == null || !mounted) return;
    FushiToast.show(
      msg: t.novel_detail_library_added,
      severity: ToastSeverity.success,
    );
  }

  /// 「移出书架」：与书架长按删除同一个确认框、同一条 `deleteBook` 路径。
  Future<void> _removeFromShelf() async {
    final EpubBookRow? book = _shelfBook;
    if (book == null || _opening) return;
    final AppModel appModel = ref.read(appProvider);
    final DeleteDecision? decision = await confirmRemoveOnlineWorkFromShelf(
      context: context,
      appModel: appModel,
      title: t.novel_detail_library_remove,
      message: t.novel_detail_library_remove_confirm,
      statisticsSubtitle: t.delete_statistics_book_desc,
    );
    if (decision == null || !mounted) return;
    setState(() => _opening = true);
    try {
      final DeleteBookResult result = await ReaderFushiSource.instance
          .deleteBook(
            db: appModel.database,
            bookKey: book.bookKey,
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
      setState(() => _shelfBook = null);
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      ref.invalidate(srtBooksProvider);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'LnReaderNovelDetailPage.remove',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// 在线阅读：找到或建好这部作品的在线书，再开阅读器。[chapterIndex] 为 null
  /// 时续读上次的位置（新书从第一章开始）。
  Future<void> _readOnline({int? chapterIndex}) async {
    final LnReaderNovel? novel = _novel;
    if (novel == null || novel.chapters.isEmpty || _opening) return;
    final String? bookKey = await _ensureShelfBook(novel);
    if (bookKey == null || !mounted) return;
    final AppModel appModel = ref.read(appProvider);
    final MediaItem item = buildCollectionReaderMediaItem(
      bookKey: bookKey,
      title: novel.name.isNotEmpty ? novel.name : widget.item.name,
      format: BookFormat.epub,
    );
    await appModel.openMedia(
      ref: ref,
      mediaSource: item.getMediaSource(appModel: appModel),
      item: item,
      waitUntilClosed: false,
      initialBookmarkJump: chapterIndex == null
          ? null
          : Bookmark(
              sectionIndex: chapterIndex,
              normCharOffset: 0,
              label: '',
              createdAt: DateTime.now(),
            ),
    );
  }

  Future<void> _download({int startIndex = 0}) async {
    final LnReaderNovel? novel = _novel;
    if (novel == null || novel.chapters.isEmpty) return;
    final RangeValues? range = await showAppDialog<RangeValues>(
      context: context,
      builder: (BuildContext context) => LnReaderChapterRangeDialog(
        chapters: novel.chapters,
        initialStart: startIndex,
      ),
    );
    if (range == null || !mounted) return;
    final List<LnReaderChapter> selected = novel.chapters.sublist(
      range.start.round(),
      range.end.round() + 1,
    );
    final AppModel appModel = ref.read(appProvider);
    final LnReaderDownloadOutcome? outcome =
        await showAppDialog<LnReaderDownloadOutcome>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) => LnReaderDownloadDialog(
            download: LnReaderBookDownload(
              manager: widget.manager,
              database: appModel.database,
              httpClientFactory: createAppHttpClient,
            ),
            plugin: widget.plugin,
            novel: novel,
            chapters: selected,
          ),
        );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case LnReaderDownloadSucceeded():
        ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
        ref.invalidate(srtBooksProvider);
        FushiToast.show(
          msg: t.novel_download_done(title: novel.name),
          severity: ToastSeverity.success,
        );
      case LnReaderDownloadFailed(:final Object error):
        final String message = error is LnReaderChapterDownloadException
            ? t.novel_download_failed(
                chapter: error.chapter.name,
                error: '${error.cause}',
              )
            : '$error';
        FushiToast.show(msg: message, severity: ToastSeverity.error);
        // 章节被 Cloudflare 拦下时桥已记下挑战：重建一次让「站点验证」出现。
        setState(() {});
      case LnReaderDownloadAborted():
        FushiToast.show(msg: t.novel_download_cancelled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final LnReaderNovel? novel = _novel;
    return FushiPageScaffold(
      title: novel?.name.isNotEmpty == true ? novel!.name : widget.item.name,
      subtitle: widget.plugin.name,
      actions: <Widget>[
        IconButton(
          key: const ValueKey<String>('novel_detail_open_website'),
          tooltip: t.mihon_source_website_open,
          onPressed: () => unawaited(_openWebsite()),
          icon: const Icon(Icons.open_in_new),
        ),
        IconButton(
          tooltip: t.refresh,
          onPressed: _loading ? null : () => unawaited(_load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LnReaderNovel? novel = _novel;
    final Object? error = _error;
    final String title = novel?.name.isNotEmpty == true
        ? novel!.name
        : widget.item.name;
    final String? summary = novel?.summary == null
        ? null
        : stripLnReaderHtml(novel!.summary!);
    final List<LnReaderChapter> chapters =
        novel?.chapters ?? const <LnReaderChapter>[];
    final bool inShelf = _shelfBook != null;
    return ListView(
      padding: withBottomSafeInset(context, const EdgeInsets.all(16)),
      children: <Widget>[
        OnlineWorkHeader(
          cover: LnReaderCover(
            url: novel?.cover ?? widget.item.cover,
            site: widget.plugin.site,
            pluginHeaders: widget.imageHeaders,
            cloudflare: widget.manager.cloudflare,
          ),
          title: title,
          lines: <String?>[novel?.author, lnReaderStatusLabel(novel?.status)],
          genres: splitOnlineWorkGenres(novel?.genres),
          description: summary,
          selectableDescription: true,
          actions: <Widget>[
            FilledButton.icon(
              key: const ValueKey<String>('novel_detail_read_online'),
              onPressed: chapters.isEmpty || _opening
                  ? null
                  : () => unawaited(_readOnline()),
              icon: _opening
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.menu_book_outlined),
              label: Text(
                inShelf ? t.book_continue_reading : t.novel_detail_read_online,
              ),
            ),
            // 同一个位置、同一个按钮：不在书架是「加入」，在书架是「移出」（与漫画
            // 作品页同一口径）。
            if (inShelf)
              OutlinedButton.icon(
                key: const ValueKey<String>('novel_detail_library_remove'),
                onPressed: _opening
                    ? null
                    : () => unawaited(_removeFromShelf()),
                icon: const Icon(Icons.library_add_check),
                label: Text(t.novel_detail_library_remove),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey<String>('novel_detail_library_add'),
                onPressed: chapters.isEmpty || _opening
                    ? null
                    : () => unawaited(_addToShelf()),
                icon: const Icon(Icons.library_add_outlined),
                label: Text(t.novel_detail_library_add),
              ),
            OutlinedButton.icon(
              key: const ValueKey<String>('novel_detail_download'),
              onPressed: chapters.isEmpty ? null : () => unawaited(_download()),
              icon: const Icon(Icons.download_outlined),
              label: Text(t.novel_detail_download),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '$error',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        // 详情 / 章节下载被 Cloudflare 拦下时给出验证；没有待解挑战时不占位。
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: LnReaderCloudflareAction(
              cloudflare: widget.manager.cloudflare,
              pluginId: widget.plugin.id,
              onVerified: () => unawaited(_load()),
            ),
          ),
        ),
        OnlineWorkSectionTitle(
          t.novel_detail_chapters_title(count: chapters.length),
        ),
        if (_loading || chapters.isEmpty)
          OnlineWorkItemsPlaceholder(
            loading: _loading,
            emptyText: t.novel_detail_chapters_empty,
          )
        else
          for (int index = 0; index < chapters.length; index++)
            _buildChapterRow(chapters[index], index),
      ],
    );
  }

  Widget _buildChapterRow(LnReaderChapter chapter, int index) {
    return OnlineWorkItemTile(
      key: ValueKey<String>('novel_chapter_${chapter.path}'),
      title: chapter.name.isNotEmpty ? chapter.name : '${index + 1}',
      subtitle: chapter.releaseTime,
      trailing: IconButton(
        key: ValueKey<String>('novel_chapter_download_${chapter.path}'),
        tooltip: t.novel_detail_chapter_download,
        onPressed: () => unawaited(_download(startIndex: index)),
        icon: const Icon(Icons.download_outlined),
      ),
      onTap: _opening
          ? null
          : () => unawaited(_readOnline(chapterIndex: index)),
    );
  }
}

/// 插件报的连载状态 → 显示文案。
///
/// 与上游 `@libs/novelStatus` 的取值一一对应；`Unknown` 不带信息不显示；插件自己
/// 塞的非标准值原样显示（不猜）。
String? lnReaderStatusLabel(String? status) => switch (status?.trim()) {
  null || '' || 'Unknown' => null,
  'Ongoing' => t.novel_status_ongoing,
  'Completed' => t.novel_status_completed,
  'Licensed' => t.novel_status_licensed,
  'Publishing Finished' => t.novel_status_publishing_finished,
  'Cancelled' => t.novel_status_cancelled,
  'On Hiatus' => t.novel_status_on_hiatus,
  final String other => other,
};

/// 选下载范围：一个区间滑块（键盘方向键可调）+ 两端章节名 + 「全部章节」。
/// 返回 0 基的闭区间 `[start, end]`。
class LnReaderChapterRangeDialog extends StatefulWidget {
  const LnReaderChapterRangeDialog({
    required this.chapters,
    this.initialStart = 0,
    super.key,
  });

  final List<LnReaderChapter> chapters;
  final int initialStart;

  @override
  State<LnReaderChapterRangeDialog> createState() =>
      _LnReaderChapterRangeDialogState();
}

class _LnReaderChapterRangeDialogState
    extends State<LnReaderChapterRangeDialog> {
  late RangeValues _range = RangeValues(
    widget.initialStart.clamp(0, widget.chapters.length - 1).toDouble(),
    (widget.chapters.length - 1).toDouble(),
  );

  String _label(int index) {
    final LnReaderChapter chapter = widget.chapters[index];
    return '${index + 1}. ${chapter.name}';
  }

  @override
  Widget build(BuildContext context) {
    final int last = widget.chapters.length - 1;
    final int start = _range.start.round();
    final int end = _range.end.round();
    // 普通 AlertDialog：内含 RangeSlider，`.adaptive` 在 iOS / macOS 主题下没有
    // Material 祖先。
    return AlertDialog(
      title: Text(t.novel_download_range_title),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.novel_download_range_hint(
                from: start + 1,
                to: end + 1,
                count: end - start + 1,
              ),
            ),
            if (last > 0) ...<Widget>[
              const SizedBox(height: 12),
              RangeSlider(
                key: const ValueKey<String>('novel_download_range_slider'),
                values: _range,
                max: last.toDouble(),
                divisions: last,
                onChanged: (RangeValues value) => setState(
                  () => _range = RangeValues(
                    value.start.roundToDouble(),
                    value.end.roundToDouble(),
                  ),
                ),
              ),
              Text(
                _label(start),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                _label(end),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _range = RangeValues(0, last.toDouble())),
                  child: Text(t.novel_download_range_all),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context, _range),
          child: Text(t.novel_download_start),
        ),
      ],
    );
  }
}

/// 下载对话框的结局。
sealed class LnReaderDownloadOutcome {
  const LnReaderDownloadOutcome();
}

class LnReaderDownloadSucceeded extends LnReaderDownloadOutcome {
  const LnReaderDownloadSucceeded(this.bookKey);

  final String bookKey;
}

class LnReaderDownloadFailed extends LnReaderDownloadOutcome {
  const LnReaderDownloadFailed(this.error);

  final Object error;
}

/// 用户取消，或在标题冲突时选择不导入。
class LnReaderDownloadAborted extends LnReaderDownloadOutcome {
  const LnReaderDownloadAborted();
}

/// 下载进度对话框：自己持有这次下载，不可点外部关闭，只能「取消」。
class LnReaderDownloadDialog extends StatefulWidget {
  const LnReaderDownloadDialog({
    required this.download,
    required this.plugin,
    required this.novel,
    required this.chapters,
    super.key,
  });

  final LnReaderBookDownload download;
  final LnReaderInstalledPlugin plugin;
  final LnReaderNovel novel;
  final List<LnReaderChapter> chapters;

  @override
  State<LnReaderDownloadDialog> createState() => _LnReaderDownloadDialogState();
}

class _LnReaderDownloadDialogState extends State<LnReaderDownloadDialog> {
  int _done = 0;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<DuplicateChoice> _askOnDuplicate(String proposedTitle) async {
    if (!mounted) return DuplicateChoice.cancel;
    final bool? keep = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.book_import_duplicate_title),
        content: Text(t.book_import_duplicate_message(name: proposedTitle)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.book_import_duplicate_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.book_import_duplicate_keep),
          ),
        ],
      ),
    );
    return keep == true ? DuplicateChoice.suffix : DuplicateChoice.cancel;
  }

  Future<void> _run() async {
    LnReaderDownloadOutcome outcome;
    try {
      final String bookKey = await widget.download.run(
        plugin: widget.plugin,
        novel: widget.novel,
        chapters: widget.chapters,
        policy: DuplicatePolicy.ask(_askOnDuplicate),
        isCancelled: () => _cancelled,
        onProgress: (int done, int total) {
          if (mounted) setState(() => _done = done);
        },
      );
      outcome = LnReaderDownloadSucceeded(bookKey);
    } on LnReaderDownloadCancelled {
      outcome = const LnReaderDownloadAborted();
    } on DuplicateImportCancelledException {
      outcome = const LnReaderDownloadAborted();
    } on Object catch (error) {
      outcome = LnReaderDownloadFailed(error);
    }
    if (mounted) Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final int total = widget.chapters.length;
    final bool building = _done >= total;
    return PopScope(
      canPop: false,
      child: AlertDialog.adaptive(
        title: Text(widget.novel.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              building
                  ? t.novel_download_building
                  : t.novel_download_progress(done: _done + 1, total: total),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              key: const ValueKey<String>('novel_download_progress'),
              value: building ? null : _done / total,
            ),
          ],
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: context,
            onPressed: _cancelled || building
                ? null
                : () => setState(() => _cancelled = true),
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
  }
}
