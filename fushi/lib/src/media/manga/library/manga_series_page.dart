import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/utils.dart';

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
  const MangaSeriesPage({required this.target, super.key});

  final MangaSeriesTarget target;

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
  bool _busy = false;
  Object? _fatalError;
  OnlineMangaUnavailable? _refreshError;

  bool _newestFirst = true;
  bool _unreadOnly = false;

  AppModel get _appModel => ref.read(appProvider);

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
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.add', error, stack);
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「继续阅读」落到哪一章。
  int get _resumeIndex {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return -1;
    return OnlineMangaLibraryService.resumeChapterIndex(entry, _states);
  }

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
    return FushiPageScaffold(
      title: title,
      subtitle: _subtitle(),
      actions: <Widget>[
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (_refreshError != null) ...<Widget>[
          _buildRefreshBanner(context, _refreshError!),
          const SizedBox(height: 12),
        ],
        _buildHeader(context),
        const SizedBox(height: 16),
        _buildActions(context),
        const SizedBox(height: 24),
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
        return Image.file(File(resolved), fit: BoxFit.cover);
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
        OutlinedButton.icon(
          key: const ValueKey<String>('manga_series_add_to_bookshelf'),
          onPressed: inLibrary || _busy
              ? null
              : () => unawaited(_addToLibrary()),
          icon: Icon(inLibrary ? Icons.check : Icons.library_add_outlined),
          label: Text(
            inLibrary ? t.mihon_in_bookshelf : t.mihon_add_to_bookshelf,
          ),
        ),
      ],
    );
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
