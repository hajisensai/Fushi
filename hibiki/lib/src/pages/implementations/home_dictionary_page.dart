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
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:hibiki/utils.dart';

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  const HomeDictionaryPage({super.key, this.focusSignal});

  final ValueNotifier<int>? focusSignal;

  @override
  BaseTabPageState<BaseTabPage> createState() => _HomeDictionaryPageState();
}

class _HomeDictionaryPageState<T extends BaseTabPage> extends BaseTabPageState
    with DictionaryPageMixin {
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => theme;

  @override
  MediaType get mediaType => DictionaryMediaType.instance;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  DictionarySearchResult? _result;
  final DictionaryPopupController _popup =
      DictionaryPopupController(lowMemory: false);
  final GlobalKey _resultStackKey = GlobalKey();

  bool _isSearching = false;
  String _lastQuery = '';
  bool _allLoaded = false;
  Timer? _debounceTimer;
  String _sourceLookupText = '';
  int _searchGeneration = 0;

  bool _historyWritten = false;

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
    // TODO-058：弹窗 controller 现持有挂起层兜底 Timer，dispose 取消防泄漏。
    _popup.dispose();
    super.dispose();
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
      unawaited(_searchWithGeneration(
        trimmed: trimmed,
        overrideMaximumTerms: overrideMaximumTerms,
        writeHistory: writeHistory,
        autoRead: autoRead,
        searchGeneration: searchGeneration,
      ));
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
    final bool allLoaded = result.entries.length < overrideMaximumTerms;
    setState(() {
      _isSearching = false;
      _allLoaded = allLoaded;
    });

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

  // ── search results with nested popups ──────────────────────────────

  Widget _buildSearchResultBody() {
    return Column(
      children: [
        if (_sourceLookupText.trim().isNotEmpty)
          SourceLookupTextPanel(
            text: _sourceLookupText,
            coordinateSpaceKey: _resultStackKey,
            dictionaryHeadwordScale: appModel.dictionaryFontSize /
                appModel.defaultDictionaryFontSize,
            onLookup: (String query, Rect localRect) {
              _pushNestedPopup(query, localRect, replaceStack: true);
            },
          ),
        // 根因修复（BUG-054）：查词结果区是 DictionaryPopupWebView + 同坐标系嵌套弹窗的
        // Stack，必须整块在中和器下渲染（净缩放=1），否则被全局「界面大小」的 FittedBox
        // 拉糊。剪贴板文本条是普通 app UI，留在中和器外以继续吃界面大小设置。
        Expanded(
          child: HibikiAppUiScaleNeutralizer(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final Size screen =
                    Size(constraints.maxWidth, constraints.maxHeight);
                return Stack(
                  key: _resultStackKey,
                  children: [
                    const SizedBox.shrink(
                      key: ValueKey<String>('home_dictionary_result_evidence'),
                    ),
                    DictionaryPopupWebView(
                      result: _result!,
                      onTextSelected: (text, localRect) {
                        _pushNestedPopup(text, localRect, replaceStack: true);
                      },
                      onLinkClick: (query, localRect) {
                        _pushNestedPopup(query, localRect, replaceStack: true);
                      },
                      onMineEntry: onMineEntry,
                      onUpdateEntry: onUpdateEntry,
                      onDuplicateCheck: checkDuplicate,
                      onScrolledToBottom: _allLoaded ? null : _loadMore,
                      onTopPullReleased: _clearSearchFromResultPull,
                    ),
                    if (_popup.entries.isNotEmpty || _popup.isSearchingUi)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () => _popNestedPopupAt(0),
                          child: Container(
                            color: Colors.transparent,
                          ),
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
        ),
      ],
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
