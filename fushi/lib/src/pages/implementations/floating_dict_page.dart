import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/models.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/lookup/lookup_ime_binding.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_native.dart';
import 'package:fushi/utils.dart';

class FloatingDictPage extends ConsumerStatefulWidget {
  const FloatingDictPage({
    required this.channel,
    this.pendingSearch,
    this.onSearchConsumed,
    super.key,
  });

  final MethodChannel channel;
  final String? pendingSearch;
  final VoidCallback? onSearchConsumed;

  @override
  ConsumerState<FloatingDictPage> createState() => _FloatingDictPageState();
}

class _FloatingDictPageState extends ConsumerState<FloatingDictPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  late final LookupImeBinding _imeBinding = LookupImeBinding(
    languageOf: () => appModel.effectiveLookupImeLanguage,
  );
  DictionarySearchResult? _result;
  bool _isSearching = false;
  String _lastSearch = '';

  AppModel get appModel => ref.read(appProvider);

  Future<void> _invoke(String method, [dynamic args]) async {
    try {
      await widget.channel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('[floating-dict] $method failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      _invoke('setFocusable', _searchFocusNode.hasFocus);
    });
    _imeBinding.attach(focusNode: _searchFocusNode);
  }

  @override
  void didUpdateWidget(FloatingDictPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingSearch != null && widget.pendingSearch != _lastSearch) {
      _searchController.text = widget.pendingSearch!;
      _doSearch(widget.pendingSearch!);
      widget.onSearchConsumed?.call();
    }
  }

  Future<void> _doSearch(String term) async {
    if (term.trim().isEmpty) return;
    final query = term.trim();
    if (query == _lastSearch && _result != null) return;
    _lastSearch = query;
    setState(() => _isSearching = true);

    try {
      final result = await appModel.searchDictionary(
        searchTerm: query,
        searchWithWildcards: true,
        overrideMaximumTerms: appModel.maximumTerms,
      );
      if (mounted) {
        setState(() {
          _result = result;
          _isSearching = false;
        });
      }
    } catch (e) {
      debugPrint('[FloatingDict] search error: $e');
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _exportToAnki(Map<String, String> fields) async {
    final repo = ref.read(ankiRepositoryProvider);
    const miningContext = AnkiMiningContext(sentence: '');
    final outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    // 牌组名由后端随成功结果带回（outcome.deckName，BUG-1549）。
    final described = describeMineOutcome(outcome);
    FushiToast.show(
      msg: described.message,
      // 制卡结果的语义已由 describeMineOutcome 算出（added/duplicate/failed），
      // 这里只把它翻译成 toast 配色，不再另判一次。
      severity: mineToastSeverity(described.status),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiOverlayScaffold(
      safeArea: false,
      body: FushiPopupSurface(
        color: tokens.surfaces.search.withValues(alpha: 0.94),
        // 悬浮词典是独立窗口：Apple 下玻璃采不到窗口背后的其它 app，画不透明面板。
        standaloneWindow: true,
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: Column(
          children: [
            _buildTitleBar(),
            _buildSearchBar(),
            // 搜索中 / 无结果 / 结果三态之间淡入淡出（effects 弹簧，不过冲）。
            Expanded(
              child: AnimatedSwitcher(
                duration: context.fushiMotion.effectsDefault.duration,
                child: KeyedSubtree(
                  key: ValueKey<String>(_resultsStateKey),
                  child: _buildResults(),
                ),
              ),
            ),
            _buildResizeHandle(),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return GestureDetector(
      onPanUpdate: (details) {
        _invoke('drag', {
          'dx': details.delta.dx,
          'dy': details.delta.dy,
        });
      },
      onPanEnd: (_) {
        _invoke('dragEnd');
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        child: Row(
          children: [
            // M3E：标题前的语义图标（主色），标题 titleSmall emphasized；整条仍是
            // 拖动窗口的把手。
            FushiIcon(
              FushiIcons.dictionary,
              size: 18,
              color: tokens.surfaces.primary,
            ),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: Text(
                t.floating_dict_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.titleSmallEmphasized,
              ),
            ),
            SizedBox(
              width: 28,
              height: 28,
              child: FushiIconButtonControl(
                icon: FushiIcon(
                  FushiIcons.close,
                  size: 16,
                  color: tokens.surfaces.onVariant,
                ),
                padding: EdgeInsets.zero,
                tooltip: t.floating_dict_close,
                onPressed: () => _invoke('close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 4,
      ),
      child: FushiCompactSearchRow(
        controller: _searchController,
        focusNode: _searchFocusNode,
        hintText: t.search_ellipsis,
        onSubmit: _doSearch,
        hintLocales: appModel.lookupImeHintLocales,
      ),
    );
  }

  /// 结果区当前处于哪一态（给 [AnimatedSwitcher] 区分子树）。
  String get _resultsStateKey {
    if (_isSearching) return 'searching';
    if (_result == null || _result!.entries.isEmpty) {
      return _lastSearch.isEmpty ? 'idle' : 'empty';
    }
    return 'results';
  }

  Widget _buildResults() {
    if (_isSearching) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: adaptiveIndicator(context: context, strokeWidth: 2),
        ),
      );
    }
    if (_result == null || _result!.entries.isEmpty) {
      if (_lastSearch.isEmpty) return const SizedBox.shrink();
      // 无结果：M3E 空状态（色块图标 + 文案），而不是一行小灰字。
      return Center(
        child: SingleChildScrollView(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.searchOff,
            message: t.no_results_found,
            iconSize: 28,
          ),
        ),
      );
    }
    return DictionaryPopupNative(
      result: _result!,
      onMineEntry: _exportToAnki,
      // 词典改名（v95）：真名 -> 显示名，只含改过名的。悬浮窗走的是精简初始化
      // 路径，词典仓库可能还没建好（dictRepo 是 late 字段，直接读会抛），未就绪
      // 时给空表 = 全部显示真名。
      dictionaryDisplayNames: appModel.isDictionaryRepoReady
          ? appModel.dictionaryDisplayNameOverrides
          : const <String, String>{},
    );
  }

  Widget _buildResizeHandle() {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomRight,
      child: GestureDetector(
        onPanUpdate: (details) {
          _invoke('resize', {
            'dw': details.delta.dx,
            'dh': details.delta.dy,
          });
        },
        onPanEnd: (_) {
          _invoke('dragEnd');
        },
        child: Container(
          width: 20,
          height: 20,
          alignment: Alignment.bottomRight,
          child: FushiIcon(
            FushiIcons.dragHandle,
            size: 14,
            color: cs.outlineVariant,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _imeBinding.detach();
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }
}
