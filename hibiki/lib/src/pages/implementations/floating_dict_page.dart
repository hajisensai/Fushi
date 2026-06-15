import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_native.dart';
import 'package:hibiki/utils.dart';

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
    // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    HibikiToast.show(
      msg: describeMineOutcome(outcome, deckName: deckName).message,
    );
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiOverlayScaffold(
      safeArea: false,
      body: HibikiPopupSurface(
        color: tokens.surfaces.search.withValues(alpha: 0.94),
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: Column(
          children: [
            _buildTitleBar(),
            _buildSearchBar(),
            Expanded(child: _buildResults()),
            _buildResizeHandle(),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
            Expanded(
              child: Text(
                t.floating_dict_title,
                style: tokens.type.listTitle,
              ),
            ),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                icon: Icon(
                  Icons.close,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: tokens.spacing.gap / 4,
      ),
      child: HibikiCompactSearchRow(
        controller: _searchController,
        focusNode: _searchFocusNode,
        hintText: t.search_ellipsis,
        onSubmit: _doSearch,
      ),
    );
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
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
      return Center(
        child: Text(
          _lastSearch.isEmpty ? '' : t.no_results_found,
          style: tokens.type.metadata,
        ),
      );
    }
    return DictionaryPopupNative(
      result: _result!,
      onMineEntry: _exportToAnki,
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
          child: Icon(
            Icons.drag_handle,
            size: 14,
            color: cs.outlineVariant,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }
}
