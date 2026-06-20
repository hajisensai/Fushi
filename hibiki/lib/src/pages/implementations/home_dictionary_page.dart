import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:hibiki/utils.dart';

/// 测试可见的查词状态探针：让 widget 行为测试直接断言「查词后 _isSearching 已复位」
/// 与「_loadMore 不再被永久阻塞」，从而钉住 [TODO-555] 的回归不变量
/// （searchDictionary 抛异常时不得卡住转圈 / 加载更多）。
@visibleForTesting
abstract class HomeDictionarySearchDebug {
  /// 当前是否处于查词中（true 时 query body 显示转圈、_loadMore 被阻塞）。
  bool get debugIsSearching;

  /// 触发一次「加载更多」（等价于滚动到底），返回派发的 future（被卡死时为
  /// 已完成 future，调用本身被 _isSearching 守卫吞掉）。
  Future<void> debugLoadMore();

  /// 直接发起一次查词（等价于在搜索框提交 [term]），返回内部派发的 future
  /// 以便测试 await 失败路径，避免依赖 UI 文本输入的异步链。[writeHistory] 默认
  /// false 以隔离历史写入 / autoRead 等副作用，只验证查词状态机。
  Future<void> debugSearch(String term, {bool writeHistory});
}

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  const HomeDictionaryPage({super.key, this.focusSignal});

  final ValueNotifier<int>? focusSignal;

  @override
  BaseTabPageState<BaseTabPage> createState() => _HomeDictionaryPageState();
}

class _HomeDictionaryPageState<T extends BaseTabPage> extends BaseTabPageState
    with DictionaryPageMixin
    implements HomeDictionarySearchDebug {
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => theme;

  @override
  MediaType get mediaType => DictionaryMediaType.instance;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  DictionarySearchResult? _result;
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );
  final GlobalKey _resultStackKey = GlobalKey();

  /// 结果区 [DictionaryPopupWebView] 的 key——顶层查词把 WebView 局部 localRect 经它的
  /// render box `localToGlobal` 映成屏幕坐标（[popupWordScreenRect]），与提到根 Overlay
  /// 后的弹窗坐标系（真实屏幕空间）统一（TODO-617）。
  final GlobalKey<DictionaryPopupWebViewState> _resultWebViewKey =
      GlobalKey<DictionaryPopupWebViewState>();

  /// TODO-617：查词弹窗栈渲染在**根 Overlay**（全窗，跳出结果子区域 / DesktopContentLayout
  /// 的限宽 + padding + 默认 hardEdge 裁剪），与 video 同范式。非空时 [_syncPopupOverlay]
  /// 据当前栈插入 / 刷新 / 摘除。
  OverlayEntry? _popupOverlayEntry;

  /// 切 tab 销毁本页时的根 Overlay 兜底（照搬 video BUG-121）：本 State deactivate 后根
  /// Overlay 仍可能同帧重建 [_buildPopupOverlay] → 读已失效 State 的 appModel/Theme 红屏；
  /// 置位后 builder 一律空渲染。
  bool _overlayInert = false;

  bool _isSearching = false;
  String _lastQuery = '';
  bool _allLoaded = false;
  Timer? _debounceTimer;
  String _sourceLookupText = '';
  int _searchGeneration = 0;

  bool _historyWritten = false;

  /// 仅测试可见：最近一次派发的查词 future（[debugSearch] 返回它以便
  /// await 失败路径）。生产路径仍 fire-and-forget，不改变行为。
  Future<void>? _lastDispatchedSearch;

  @override
  void initState() {
    super.initState();
    appModelNoUpdate.dictionarySearchAgainNotifier.addListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .addListener(_onDictionaryEntriesChanged);
    _searchFocusNode.addListener(_onFocusChanged);
    final HomeDictionaryPage w = widget as HomeDictionaryPage;
    w.focusSignal?.addListener(_onFocusSignal);
    DesktopLookupService.instance.addListener(_onDesktopLookupPending);
    // 仅在剪贴板监听开启时启动桌面剪贴板/热键监听（受用户设置控制）。
    unawaited(_startDesktopLookupIfEnabled());
    // TODO-376：无条件消费一次挂载前已排入的 pending（不被 desktopClipboardEnabled
    // 门控）。桌面悬浮字幕点词由 floatingLyricClickLookup 控制、与剪贴板监听无关：它
    // 在切到本 tab *之前* 就把待查词排进 pendingText 并 notify，那次 notify 发生在
    // 本页 addListener 之前收不到。若只在剪贴板开启分支里消费，「开了悬浮字幕点词但
    // 关了剪贴板监听」的默认用户会 pending 卡死、查词静默丢失。故挂载即排一次后帧
    // 消费已存在的 pending（有 pending 才消费，无 pending 则 no-op，不会乱消费）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onDesktopLookupPending();
    });
  }

  void _onFocusSignal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  Future<void> _startDesktopLookupIfEnabled() async {
    final AppModel model = appModelNoUpdate;
    if (!DesktopLookupService.isDesktop || !model.desktopClipboardEnabled) {
      return;
    }
    await DesktopLookupService.instance.start(
      windowMode: model.desktopClipboardWindowMode,
    );
    // 已存在的 pending 由 initState 的 post-frame 无条件消费一次（不依赖剪贴板
    // 是否开启），这里不再重复消费——start 之后的剪贴板/热键命中走 addListener。
  }

  void _onDesktopLookupPending() {
    final DesktopLookupRequest? request =
        DesktopLookupService.instance.pendingRequest;
    if (request == null) return;
    DesktopLookupService.instance.clearPending();
    _sourceLookupText = request.showSourcePanel ? request.text : '';
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      _runDesktopLookup(request);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runDesktopLookup(request);
      });
    }
  }

  void _runDesktopLookup(DesktopLookupRequest request) {
    if (!mounted) return;
    if (request.foregroundPolicy ==
        DesktopLookupForegroundPolicy.bringToFront) {
      unawaited(DesktopLookupService.instance.bringPendingLookupToFront());
    }
    if (mounted) _search(request.text, autoRead: false);
  }

  void _onFocusChanged() {
    if (!_searchFocusNode.hasFocus) {
      _commitHistory();
    }
  }

  void _commitHistory() {
    if (_historyWritten) return;
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty || _result == null || _result!.entries.isEmpty) return;
    _historyWritten = true;
    appModel.addToSearchHistory(
      historyKey: mediaType.uniqueKey,
      searchTerm: trimmed,
    );
    appModel.addToDictionaryHistory(result: _result!);
  }

  void _onDictionaryEntriesChanged() {
    if (!mounted) return;
    final model = appModelNoUpdate;
    if (!model.isMediaOpen &&
        DictionaryMediaType.instance ==
            model.mediaTypes.values.toList()[model.currentHomeTabIndex]) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    final HomeDictionaryPage w = widget as HomeDictionaryPage;
    w.focusSignal?.removeListener(_onFocusSignal);
    DesktopLookupService.instance.removeListener(_onDesktopLookupPending);
    if (DesktopLookupService.isDesktop &&
        appModelNoUpdate.desktopClipboardEnabled) {
      unawaited(DesktopLookupService.instance.stop());
    }
    _searchFocusNode.removeListener(_onFocusChanged);
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .removeListener(_onDictionaryEntriesChanged);
    _commitHistory();
    _debounceTimer?.cancel();
    _searchFocusNode.dispose();
    _controller.dispose();
    // TODO-617：先摘根 Overlay 浮层 entry 再 clear 栈——entry 一旦移除就不会再被根
    // Overlay 重建 [_buildPopupOverlay]，杜绝销毁期用失效 State 重建浮层（照搬 video）。
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      if (entry.mounted) entry.remove();
      entry.dispose();
      _popupOverlayEntry = null;
    }
    // TODO-058：弹窗 controller 现持有挂起层兜底 Timer，dispose 取消防泄漏。
    _popup.dispose();
    super.dispose();
  }

  /// TODO-617：切 tab 销毁本页的根 Overlay 兜底（BUG-121 同范式）。本 State deactivate
  /// 当帧根 Overlay 仍可能重建 entry → 读失效 State 红屏；置位让 builder 空渲染。
  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // GlobalKey 重挂等重新激活：恢复正常渲染，下次 build 的 _syncPopupOverlay 重建浮层。
    _overlayInert = false;
  }

  bool get _hasActiveQuery => _controller.text.isNotEmpty;

  void _clearSearch() {
    _searchGeneration++;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _controller.clear();
    _popup.clear();
    _result = null;
    _isSearching = false;
    _lastQuery = '';
    _allLoaded = false;
    _sourceLookupText = '';
    _historyWritten = false;
    setState(() {});
    if (_searchFocusNode.canRequestFocus) {
      _searchFocusNode.requestFocus();
    }
  }

  void _clearSearchFromResultPull() {
    if (_popup.entries.isNotEmpty || _popup.isSearchingUi) return;
    _clearSearch();
  }

  // ── build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasActiveQuery && _popup.entries.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_popup.entries.isNotEmpty) {
          _popNestedPopupAt(_popup.entries.length - 1);
        } else if (_hasActiveQuery) {
          _clearSearch();
        }
      },
      child: HibikiFileDropTarget(
        debugLabel: 'home-dictionary',
        onDrop: _handleDictionaryHomeDrop,
        child: DesktopContentLayout(
          kind: DesktopContentKind.dictionary,
          child: Column(
            children: [
              if (!isCupertinoPlatform(context)) _buildPageHeader(),
              _buildSearchHeader(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  void _handleDictionaryHomeDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final List<String> importPaths = classifyDroppedFilesForDictionary(paths);
    debugPrint(
      '[hibiki-drop] [home-dictionary] importPaths=${importPaths.length} '
      'paths=${paths.length} global=$globalPosition',
    );
    if (importPaths.isEmpty) {
      debugPrint('[hibiki-drop] [home-dictionary] intent=unsupportedSurface');
      HibikiToast.show(msg: t.drag_drop_unsupported_on_dictionary);
      return;
    }
    unawaited(appModel.showDictionaryMenu(initialImportPaths: importPaths));
  }

  Widget _buildPageHeader() {
    return HibikiPageHeader(
      title: t.nav_lookup,
      actions: <Widget>[
        HibikiIconButton(
          tooltip: t.clear_dictionary_title,
          icon: Icons.delete_sweep_outlined,
          onTap: _showDeleteDictionaryHistoryPrompt,
        ),
      ],
    );
  }

  Widget _buildSearchHeader() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double horizontalPadding =
        isCupertinoPlatform(context) ? tokens.spacing.gap : tokens.spacing.page;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        0,
        horizontalPadding,
        tokens.spacing.gap,
      ),
      // Let the MD3 SearchBar own its height instead of forcing kToolbarHeight.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: HibikiSearchField(
              fieldKey: const ValueKey<String>('home_dictionary_search_field'),
              clearButtonKey: const ValueKey<String>(
                'home_dictionary_search_clear_button',
              ),
              controller: _controller,
              focusNode: _searchFocusNode,
              hintText: t.search_ellipsis,
              onChanged: _onQueryChanged,
              onClear: _clearSearch,
              onSubmitted: _search,
            ),
          ),
          if (isCupertinoPlatform(context))
            HibikiIconButton(
              tooltip: t.clear_dictionary_title,
              icon: Icons.delete_sweep_outlined,
              onTap: _showDeleteDictionaryHistoryPrompt,
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_hasActiveQuery) {
      return _buildQueryBody();
    }
    if (appModel.dictionaryHistory.isEmpty) {
      return _buildPlaceholder();
    }
    return _buildDictionaryHistory();
  }

  Widget _buildQueryBody() {
    if (_result != null && _result!.entries.isNotEmpty) {
      return _buildSearchResultBody();
    }
    if (_isSearching) {
      return Center(child: adaptiveIndicator(context: context));
    }
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.search_off,
        message: t.no_search_results,
      ),
    );
  }

  Widget _buildPlaceholder() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final noDictionaries = appModel.dictionaries.isEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HibikiPlaceholderMessage(
            icon: mediaType.outlinedIcon,
            message: noDictionaries
                ? t.dictionaries_menu_empty
                : t.info_empty_home_tab,
          ),
          if (noDictionaries) ...[
            SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
            FilledButton.icon(
              icon: const Icon(Icons.auto_stories_outlined, size: 18),
              label: Text(t.dialog_import_dictionary),
              onPressed: appModel.showDictionaryMenu,
            ),
          ],
        ],
      ),
    );
  }

  // ── dictionary history list ────────────────────────────────────────

  Widget _buildDictionaryHistory() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final historyResults = appModel.dictionaryHistory.reversed.toList();
    if (historyResults.every((r) => r.entries.isEmpty)) {
      return _buildPlaceholder();
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        top: tokens.spacing.gap / 2,
        bottom: tokens.spacing.page,
      ),
      controller: DictionaryMediaType.instance.scrollController,
      itemCount: historyResults.length,
      itemBuilder: (context, index) {
        final result = historyResults[index];
        if (result.entries.isEmpty) {
          return const SizedBox.shrink();
        }
        final searchTerm = result.searchTerm.trim();
        final first = result.entries.first;
        final word = first.word;
        final reading = first.reading;
        final hasWordInfo = word.isNotEmpty && word != searchTerm;
        final hasReading =
            reading.isNotEmpty && reading != word && reading != searchTerm;
        final dictCount =
            result.entries.map((e) => e.dictionaryName).toSet().length;
        return HibikiCard(
          margin: EdgeInsets.symmetric(
            horizontal: tokens.spacing.page,
            vertical: tokens.spacing.gap / 4,
          ),
          onTap: () {
            _controller.text = searchTerm;
            _controller.selection =
                TextSelection.collapsed(offset: searchTerm.length);
            _showCachedResult(result);
          },
          padding: EdgeInsets.zero,
          child: HibikiListItem(
            title: Text(searchTerm.replaceAll('\n', ' ')),
            subtitle: hasWordInfo || hasReading
                ? Text([
                    if (hasWordInfo) word,
                    if (hasReading) reading,
                  ].join('  '))
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$dictCount'),
                SizedBox(width: tokens.spacing.gap / 2),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── search logic ───────────────────────────────────────────────────

  void _onQueryChanged(String query) {
    _debounceTimer?.cancel();
    _historyWritten = false;
    if (query.isEmpty) {
      _clearSearch();
      return;
    }
    if (!appModel.autoSearchEnabled) return;
    final int delay = appModel.searchDebounceDelay;
    if (delay <= 0) {
      if (mounted) _search(query, writeHistory: false);
    } else {
      _debounceTimer = Timer(Duration(milliseconds: delay), () {
        if (mounted) _search(query, writeHistory: false);
      });
    }
  }

  void _searchAgain() {
    _lastQuery = '';
    _search(_controller.text);
  }

  void _showCachedResult(DictionarySearchResult cached) {
    setState(() {
      _result = cached;
      _isSearching = false;
      // Non-empty cache always allows one scroll-to-bottom probe;
      // _loadMore will set _allLoaded if nothing new comes back.
      _allLoaded = cached.entries.isEmpty;
      _lastQuery = cached.searchTerm.trim();
      _popup.clear();
    });
  }

  void _search(
    String query, {
    int? overrideMaximumTerms,
    bool writeHistory = true,
    bool? autoRead,
  }) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final bool replaceSourceLookupText = overrideMaximumTerms == null;

    if (_lastQuery == trimmed && overrideMaximumTerms == null) {
      if (_sourceLookupText != trimmed && mounted) {
        setState(() => _sourceLookupText = trimmed);
      }
      if (writeHistory &&
          !_historyWritten &&
          _result != null &&
          _result!.entries.isNotEmpty) {
        _historyWritten = true;
        appModel.addToSearchHistory(
          historyKey: mediaType.uniqueKey,
          searchTerm: trimmed,
        );
        appModel.addToDictionaryHistory(result: _result!);
      }
      return;
    }
    _lastQuery = trimmed;
    overrideMaximumTerms ??= appModel.maximumTerms;

    if (_controller.text != trimmed) {
      _controller.text = trimmed;
      _controller.selection = TextSelection.collapsed(offset: trimmed.length);
    }

    if (mounted) {
      final int searchGeneration = ++_searchGeneration;
      setState(() {
        _isSearching = true;
        if (replaceSourceLookupText) _sourceLookupText = trimmed;
        _popup.clear();
      });
      final Future<void> dispatched = _searchWithGeneration(
        trimmed: trimmed,
        overrideMaximumTerms: overrideMaximumTerms,
        writeHistory: writeHistory,
        autoRead: autoRead,
        searchGeneration: searchGeneration,
      );
      _lastDispatchedSearch = dispatched;
      unawaited(dispatched);
    } else if (replaceSourceLookupText) {
      _sourceLookupText = trimmed;
    }
  }

  Future<void> _searchWithGeneration({
    required String trimmed,
    required int overrideMaximumTerms,
    required bool writeHistory,
    required bool? autoRead,
    required int searchGeneration,
  }) async {
    // 用 try/finally 守卫整条失败路径：searchDictionary 走远程网络查询 +
    // hoshidicts C++ FFI，任一环节抛异常都不能让 _isSearching 永久为 true
    // （否则 _buildQueryBody 永久转圈、_loadMore 永久阻塞）。finally 始终复位，
    // 但只对仍是当前 generation 的请求 setState，避免污染已被新请求覆盖的状态。
    try {
      final DictionarySearchResult result = await appModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: overrideMaximumTerms,
      );
      if (!mounted ||
          searchGeneration != _searchGeneration ||
          trimmed != _controller.text) {
        return;
      }

      _result = result;
      _allLoaded = result.entries.length < overrideMaximumTerms;

      if (writeHistory) {
        _historyWritten = true;
        appModel.addToSearchHistory(
          historyKey: mediaType.uniqueKey,
          searchTerm: trimmed,
        );
        if (result.entries.isNotEmpty) {
          appModel.addToDictionaryHistory(result: result);
          // autoRead 覆盖：null 沿用全局 autoReadOnLookup（正常输入查词不变），
          // 桌面剪贴板/热键路径显式传 false 抑制朗读。
          final bool shouldAutoRead =
              autoRead ?? ReaderHibikiSource.instance.autoReadOnLookup;
          if (shouldAutoRead) {
            final entry = result.entries.first;
            if (entry.word.isNotEmpty) {
              autoReadWord(entry.word, entry.reading);
            }
          }
        }
      }
    } finally {
      // 仅当本请求仍是最新 generation 时复位（保留过期守卫，避免对已被新请求
      // 覆盖的状态 setState）。异常 / 正常 / 命中 stale 守卫的 return 都会执行此处。
      if (mounted && searchGeneration == _searchGeneration) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _loadMore() {
    if (_isSearching || _allLoaded || _result == null) return;
    final current = _result!.entries.length;
    _lastQuery = '';
    _search(
      _controller.text,
      overrideMaximumTerms: current + appModel.maximumTerms,
      writeHistory: false,
    );
  }

  @override
  bool get debugIsSearching => _isSearching;

  @override
  Future<void> debugLoadMore() {
    _lastDispatchedSearch = null;
    _loadMore();
    return _lastDispatchedSearch ?? Future<void>.value();
  }

  @override
  Future<void> debugSearch(String term, {bool writeHistory = false}) {
    _lastDispatchedSearch = null;
    _search(term, writeHistory: writeHistory);
    return _lastDispatchedSearch ?? Future<void>.value();
  }

  // ── search results with nested popups ──────────────────────────────

  Widget _buildSearchResultBody() {
    // TODO-617：每次 build 后把查词弹窗栈同步到根 Overlay（栈非空插入 / 刷新，栈空摘除）。
    // 弹窗 push/pop 都走 setState → 重 build → 本同步，使根 Overlay 总反映当前栈。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    return Column(
      children: [
        if (_sourceLookupText.trim().isNotEmpty)
          SourceLookupTextPanel(
            text: _sourceLookupText,
            // TODO-617：弹窗已提到根 Overlay（全窗、净缩放=1），源文本条点字必须回报屏幕
            // （global）坐标与之同系；不再用结果子区域 [_resultStackKey] 局部坐标。
            globalCoordinates: true,
            dictionaryHeadwordScale: appModel.dictionaryFontSize /
                appModel.defaultDictionaryFontSize,
            onLookup: (String query, Rect screenRect) {
              _pushNestedPopup(query, screenRect, replaceStack: true);
            },
          ),
        // 根因修复（BUG-054）：结果区 WebView 仍整块在中和器下渲染（净缩放=1），否则被全局
        // 「界面大小」FittedBox 拉糊。剪贴板文本条是普通 app UI，留在中和器外继续吃界面大小。
        // TODO-617：嵌套弹窗栈不再挂在此页内 Stack（会被结果子区域 / DesktopContentLayout
        // 限宽 + padding + 默认 hardEdge 裁住），改由 [_buildPopupOverlay] 渲染在根 Overlay。
        Expanded(
          child: HibikiAppUiScaleNeutralizer(
            child: Stack(
              key: _resultStackKey,
              children: [
                const SizedBox.shrink(
                  key: ValueKey<String>('home_dictionary_result_evidence'),
                ),
                DictionaryPopupWebView(
                  key: _resultWebViewKey,
                  result: _result!,
                  // TODO-617：顶层查词把 WebView 局部 localRect 经结果 WebView 的 render box
                  // localToGlobal 映成屏幕坐标（popupWordScreenRect），与根 Overlay 弹窗同系。
                  // localRect==Zero 时直传 Zero，由 mixin fallbackSelectionRect 兜底。
                  onTextSelected: (text, localRect) {
                    _pushNestedPopup(
                      text,
                      _resultWordScreenRect(localRect),
                      replaceStack: true,
                    );
                  },
                  onLinkClick: (query, localRect) {
                    _pushNestedPopup(
                      query,
                      _resultWordScreenRect(localRect),
                      replaceStack: true,
                    );
                  },
                  onMineEntry: onMineEntry,
                  onUpdateEntry: onUpdateEntry,
                  onDuplicateCheck: checkDuplicate,
                  onOverwriteTargetNoteId: findOverwriteTargetNoteId,
                  onScrolledToBottom: _allLoaded ? null : _loadMore,
                  onTopPullReleased: _clearSearchFromResultPull,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// TODO-617：把结果区 WebView 报的局部 [localRect]（CSS px，原点=WebView 左上）映成屏幕
  /// 坐标，供提到根 Overlay 的弹窗按真实屏幕空间定位。Zero（无 rect 的 textSelected）直传
  /// Zero 让 mixin 兜底。
  Rect _resultWordScreenRect(Rect localRect) {
    if (localRect == Rect.zero) return Rect.zero;
    return popupWordScreenRect(
      webViewKey: _resultWebViewKey,
      localRect: localRect,
      fallback: localRect,
    );
  }

  /// TODO-617：把查词弹窗栈同步到根 Overlay（与 video [_syncPopupOverlay] 同范式）。栈非空
  /// 且未插入则插入、栈空则摘除、否则 markNeedsBuild 刷新。在 [_buildSearchResultBody] 的
  /// post-frame 调，使根 Overlay 总反映当前栈。
  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
        _popupOverlayEntry = null;
      }
      return;
    }
    if (_popupOverlayEntry != null) {
      _popupOverlayEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// TODO-617：根 Overlay 里的查词弹窗栈内容——透明 dismiss 遮罩 + 搜索期加载占位卡 + 各层
  /// [DictionaryPopupLayer]。根 Overlay 在 [HibikiAppUiScale] 的 FittedBox 之内（缩放后的
  /// 小画布），WebView 在此栅格化再拉大会字糊（BUG-051）；[HibikiAppUiScaleNeutralizer] 把
  /// 整棵子树中和回真实视口、净缩放=1（清晰），其坐标系即真实屏幕空间，与顶层 / 嵌套选区的
  /// localToGlobal 屏幕 rect 同系，定位自洽。`Clip.none` 让飘出窗的弹窗 / 屏外热槽不被裁
  /// （BUG-135）。`screen` = 中和后内层 LayoutBuilder 约束 = 整窗。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    // 切 tab 销毁本页当帧根 Overlay 仍会重建本 entry——彼时读失效 State 的 appModel/Theme
    // 会红屏（BUG-121）。State 失效 / 销毁期标志置位则空渲染兜底；Theme 用 entry 自己的
    // overlayContext（与本 entry 同寿命）而非更短命的 State context。
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return HibikiAppUiScaleNeutralizer(
      child: Theme(
        data: appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (!mounted || _overlayInert) return const SizedBox.shrink();
            final Size screen =
                Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              // BUG-135：隐藏热槽停到屏幕右外侧（buildNestedPopupLayer），Clip.none 让它在
              // 屏外照常预热又不被裁；飘出窗的弹窗同理不裁。
              clipBehavior: Clip.none,
              children: <Widget>[
                if (_popup.entries.isNotEmpty || _popup.isSearchingUi)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => _popNestedPopupAt(0),
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                // 搜索期加载占位卡（搜索→就绪才显示，与书内同观感）。
                if (_popup.isSearchingUi && _popup.pendingRect != null)
                  buildPopupLoadingPlaceholder(
                    rect: _popup.pendingRect!,
                    screen: screen,
                  ),
                for (int i = 0; i < _popup.entries.length; i++)
                  _buildNestedPopupLayer(i, screen),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _pushNestedPopup(
    String query,
    Rect selectionRect, {
    bool replaceStack = false,
  }) {
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      controller: _popup,
      replaceStack: replaceStack,
      autoRead: true,
    );
  }

  void _popNestedPopupAt(int index) {
    popNestedPopupAt(index, _popup);
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    return buildNestedPopupLayer(
      index: index,
      screen: screen,
      controller: _popup,
      onPush: (text, rect) => _pushNestedPopup(text, rect),
      onPop: _popNestedPopupAt,
    );
  }

  // ── dialogs ────────────────────────────────────────────────────────

  void _showDeleteDictionaryHistoryPrompt() async {
    await showAppDialog(
      context: context,
      builder: (context) => HomeDictionaryClearHistoryDialog(
        onConfirm: () async {
          Navigator.pop(context);
          await appModel.clearDictionaryHistory();
          if (mounted) setState(() {});
        },
      ),
    );
  }
}

@visibleForTesting
class HomeDictionaryClearHistoryDialog extends StatelessWidget {
  const HomeDictionaryClearHistoryDialog({
    required this.onConfirm,
    super.key,
  });

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
        title: t.clear_dictionary_title,
        leadingIcon: Icons.delete_sweep_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.clear_dictionary_description,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              child: Text(t.dialog_cancel),
              onPressed: () => Navigator.pop(context),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              child: Text(t.dialog_clear),
              onPressed: onConfirm,
            ),
          ],
        ),
      ),
    );
  }
}
