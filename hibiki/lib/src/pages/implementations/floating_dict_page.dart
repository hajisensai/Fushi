import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
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

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      widget.channel.invokeMethod('setFocusable', _searchFocusNode.hasFocus);
    });
  }

  @override
  void didUpdateWidget(FloatingDictPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingSearch != null &&
        widget.pendingSearch != _lastSearch) {
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
    final result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    switch (result) {
      case MineResult.success:
        final settings = await repo.loadSettings();
        Fluttertoast.showToast(
          msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
          toastLength: Toast.LENGTH_SHORT,
        );
      case MineResult.duplicate:
        Fluttertoast.showToast(msg: t.card_duplicate);
      case MineResult.notConfigured:
        Fluttertoast.showToast(msg: t.card_export_not_configured);
      case MineResult.error:
        Fluttertoast.showToast(msg: t.card_export_failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xF01E1E2E) : const Color(0xF0F5F5F5);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? Colors.white24 : Colors.black12,
          ),
        ),
        child: Column(
          children: [
            _buildTitleBar(isDark),
            _buildSearchBar(isDark),
            Expanded(child: _buildResults()),
            _buildResizeHandle(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar(bool isDark) {
    return GestureDetector(
      onPanUpdate: (details) {
        widget.channel.invokeMethod('drag', {
          'dx': details.delta.dx,
          'dy': details.delta.dy,
        });
      },
      onPanEnd: (_) {
        widget.channel.invokeMethod('dragEnd');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Dictionary',
                style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 14,
                ),
              ),
            ),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                icon: Icon(Icons.close,
                    size: 16,
                    color: isDark ? Colors.white : Colors.black54),
                padding: EdgeInsets.zero,
                onPressed: () => widget.channel.invokeMethod('close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    final textColor = isDark ? Colors.white : Colors.black;
    final hintColor = isDark ? Colors.white54 : Colors.black45;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              style: TextStyle(color: textColor, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search...',
                hintStyle: TextStyle(color: hintColor, fontSize: 14),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                filled: true,
                fillColor: isDark
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: _doSearch,
            ),
          ),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              icon: Icon(Icons.search, color: hintColor, size: 20),
              padding: EdgeInsets.zero,
              onPressed: () => _doSearch(_searchController.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_isSearching) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_result == null || _result!.entries.isEmpty) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Center(
        child: Text(
          _lastSearch.isEmpty ? '' : 'No results found.',
          style: TextStyle(
            color: isDark ? Colors.white54 : Colors.black45,
            fontSize: 13,
          ),
        ),
      );
    }
    return DictionaryPopupNative(
      result: _result!,
      onMineEntry: _exportToAnki,
    );
  }

  Widget _buildResizeHandle(bool isDark) {
    return Align(
      alignment: Alignment.bottomRight,
      child: GestureDetector(
        onPanUpdate: (details) {
          widget.channel.invokeMethod('resize', {
            'dw': details.delta.dx,
            'dh': details.delta.dy,
          });
        },
        onPanEnd: (_) {
          widget.channel.invokeMethod('dragEnd');
        },
        child: Container(
          width: 20,
          height: 20,
          alignment: Alignment.bottomRight,
          child: Icon(
            Icons.drag_handle,
            size: 14,
            color: isDark ? Colors.white38 : Colors.black26,
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
