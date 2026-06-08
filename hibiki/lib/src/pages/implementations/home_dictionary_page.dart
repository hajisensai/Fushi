import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';
import 'package:hibiki/utils.dart';

/// The body content for the Dictionary tab in the main menu.
class HomeDictionaryPage extends BaseTabPage {
  const HomeDictionaryPage({super.key, this.focusSignal, this.externalQuery});

  final ValueNotifier<int>? focusSignal;

  /// 桌面剪贴板/热键命中后的「外部查词请求」通道：home_page 切到本 tab 后把命中词
  /// 推到这里，本页预填搜索框并触发查询（不自动朗读）。带自增 [seq] 以便连续命中
  /// 同一个词也能触发（同 text 的 [ValueNotifier] 相等值不会 notify）。
  final ValueNotifier<({int seq, String text})?>? externalQuery;

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

  bool _isSearching = false;
  String _lastQuery = '';
  bool _allLoaded = false;
  Timer? _debounceTimer;
  String _externalLookupText = '';

  bool _historyWritten = false;

  /// 已消费的外部查词请求序号，避免同一请求被「监听回调 + initState 兜底」重复触发。
  int _lastConsumedQuerySeq = -1;

  @override
  void initState() {
    super.initState();
    appModelNoUpdate.dictionarySearchAgainNotifier.addListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .addListener(_onDictionaryEntriesChanged);
    _searchFocusNode.addListener(_onFocusChanged);
    final HomeDictionaryPage w = widget as HomeDictionaryPage;
    w.focusSignal?.addListener(_onFocusSignal);
    w.externalQuery?.addListener(_onExternalQuery);
    // 兜底：切到本 tab 后本页才挂载，此时 externalQuery 可能已被 home_page 置值，
    // 监听器不会回放历史值，故挂载时主动消费一次。
    _consumeExternalQuery();
  }

  void _onFocusSignal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _onExternalQuery() => _consumeExternalQuery();

  /// 消费外部查词请求：预填搜索框并触发查询，显式不自动朗读（与首页查词同一套
  /// 体验，但剪贴板/热键命中不读音）。消费后把通道置 null（镜像
  /// [DesktopLookupService.pendingText] 的「消费即清」语义）——否则用户切走再切回
  /// 查词 tab 时，新挂载的本页会把上一次的剪贴板词重放查询一次。
  void _consumeExternalQuery() {
    final ValueNotifier<({int seq, String text})?>? channel =
        (widget as HomeDictionaryPage).externalQuery;
    final ({int seq, String text})? req = channel?.value;
    if (req == null || req.seq == _lastConsumedQuerySeq) return;
    _lastConsumedQuerySeq = req.seq;
    _externalLookupText = req.text;
    channel!.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await DesktopLookupService.instance.bringPendingLookupToFront();
      if (mounted) _search(req.text, autoRead: false);
    });
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
    w.externalQuery?.removeListener(_onExternalQuery);
    _searchFocusNode.removeListener(_onFocusChanged);
    appModelNoUpdate.dictionarySearchAgainNotifier.removeListener(_searchAgain);
    appModelNoUpdate.dictionaryEntriesNotifier
        .removeListener(_onDictionaryEntriesChanged);
    _commitHistory();
    _debounceTimer?.cancel();
    _searchFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _hasActiveQuery => _controller.text.isNotEmpty;

  void _clearSearch() {
    _controller.clear();
    _popup.clear();
    _result = null;
    _isSearching = false;
    _lastQuery = '';
    _allLoaded = false;
    _externalLookupText = '';
    _searchFocusNode.unfocus();
    setState(() {});
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
    );
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
              controller: _controller,
              focusNode: _searchFocusNode,
              hintText: t.search_ellipsis,
              onChanged: _onQueryChanged,
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
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;

    if (_lastQuery == trimmed && overrideMaximumTerms == null) {
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
      setState(() {
        _isSearching = true;
        _popup.clear();
      });
    }

    try {
      _result = await appModel.searchDictionary(
        searchTerm: trimmed,
        searchWithWildcards: true,
        overrideMaximumTerms: overrideMaximumTerms,
      );
    } finally {
      if (_result != null && trimmed == _controller.text) {
        final bool allLoaded = _result!.entries.length < overrideMaximumTerms;
        if (mounted) {
          setState(() {
            _isSearching = false;
            _allLoaded = allLoaded;
          });
        }

        if (writeHistory) {
          _historyWritten = true;
          appModel.addToSearchHistory(
            historyKey: mediaType.uniqueKey,
            searchTerm: trimmed,
          );
          if (_result!.entries.isNotEmpty) {
            appModel.addToDictionaryHistory(result: _result!);
            // autoRead 覆盖：null 沿用全局 autoReadOnLookup（正常输入查词不变），
            // 桌面剪贴板/热键路径显式传 false 抑制朗读。
            final bool shouldAutoRead =
                autoRead ?? ReaderHibikiSource.instance.autoReadOnLookup;
            if (shouldAutoRead) {
              final entry = _result!.entries.first;
              if (entry.word.isNotEmpty) {
                autoReadWord(entry.word, entry.reading);
              }
            }
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
    // 根因修复（BUG-054）：查词结果区是 DictionaryPopupWebView + 同坐标系嵌套弹窗的
    // Stack，必须整块在中和器下渲染（净缩放=1），否则被全局「界面大小」的 FittedBox
    // 拉糊。中和器包在 LayoutBuilder 外层 → 内层 constraints/screen 都是真实视口几何，
    // WebView 与弹窗共用同一坐标系，selectionRect 定位不错位。
    return HibikiAppUiScaleNeutralizer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
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
                onDuplicateCheck: checkDuplicate,
                onScrolledToBottom: _allLoaded ? null : _loadMore,
              ),
              if (_externalLookupText.trim().isNotEmpty)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ClipboardLookupTextPanel(
                    text: _externalLookupText,
                    onLookup: (String query, Rect localRect) {
                      _pushNestedPopup(query, localRect, replaceStack: true);
                    },
                  ),
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
